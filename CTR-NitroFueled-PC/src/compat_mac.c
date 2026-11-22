/* macOS (Darwin x86_64 under Rosetta 2) compatibility helpers. */
#ifndef _DARWIN_C_SOURCE
#define _DARWIN_C_SOURCE
#endif
#include "compat_mac.h"

#ifdef __APPLE__
#include <errno.h>
#include <mach/mach.h>
#include <mach/mach_vm.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>
#include <unistd.h>

/* ---- Low-40-bit (< 63 GiB) guest-visible heap allocator ----
 * Uses [0x0c00000000, 0x0fc0000000) (48 GiB .. 63 GiB), disjoint from runtime_low_map's
 * [0x0800000000, 0x0c00000000) and below XNU's [0x0fc0000000, 0x7000000000) carveout. */
#define MAC_HEAP_MIN UINT64_C(0x0c00000000)
#define MAC_HEAP_MAX UINT64_C(0x0fc0000000)
#define MAC_CHUNK_SIZE (UINT64_C(16) << 20)
#define MAC_HEADER_MAGIC UINT64_C(0x5ac7ed40b170c0de)
#define MAC_SIZE_CLASSES 9

typedef struct MacLowBlock {
    uint64_t magic;
    size_t capacity;
    int class_idx;
    struct MacLowBlock *next_free;
    uint64_t pad[4]; /* total header = 64 bytes, preserving 64-byte payload alignment */
} MacLowBlock;
_Static_assert(sizeof(MacLowBlock) == 64, "MacLowBlock must be 64 bytes");

static const size_t class_sizes[MAC_SIZE_CLASSES] = {
    64, 128, 256, 512, 1024, 4096, 16384, 65536, 262144,
};

static pthread_mutex_t low_heap_lock = PTHREAD_MUTEX_INITIALIZER;
static MacLowBlock *free_lists[MAC_SIZE_CLASSES];
static unsigned char *cur_chunk;
static size_t cur_offset;
static size_t cur_size;
static uint64_t heap_cursor = MAC_HEAP_MIN;

static size_t align_up_sz(size_t v, size_t a) {
    return (v + a - 1) & ~(a - 1);
}

static void *alloc_low_region(size_t bytes) {
    bytes = align_up_sz(bytes, 16384);
    while (heap_cursor + bytes <= MAC_HEAP_MAX) {
        mach_vm_address_t addr = heap_cursor;
        heap_cursor += bytes + 16384; /* 16 KiB unmapped guard between chunks */
        if (mach_vm_allocate(mach_task_self(), &addr, bytes, VM_FLAGS_FIXED) == KERN_SUCCESS) {
            if (mprotect((void *)(uintptr_t)addr, bytes, PROT_READ | PROT_WRITE) == 0) {
                return (void *)(uintptr_t)addr;
            }
            mach_vm_deallocate(mach_task_self(), addr, bytes);
        }
    }
    return NULL;
}

void *compat_low_aligned_alloc(size_t align, size_t size) {
    if (align < 64) align = 64;
    if ((align & (align - 1)) != 0) return NULL;
    if (size == 0) size = 64;

    int cls = -1;
    if (align == 64) {
        for (int i = 0; i < MAC_SIZE_CLASSES; ++i) {
            if (size <= class_sizes[i]) {
                cls = i;
                size = class_sizes[i];
                break;
            }
        }
    } else {
        size = align_up_sz(size, 64);
    }

    pthread_mutex_lock(&low_heap_lock);
    if (cls >= 0 && free_lists[cls]) {
        MacLowBlock *blk = free_lists[cls];
        free_lists[cls] = blk->next_free;
        blk->next_free = NULL;
        pthread_mutex_unlock(&low_heap_lock);
        return (void *)(blk + 1);
    }

    if (align == 64 && sizeof(MacLowBlock) + size <= MAC_CHUNK_SIZE / 2) {
        size_t need = sizeof(MacLowBlock) + size;
        if (!cur_chunk || cur_offset + need > cur_size) {
            unsigned char *nc = (unsigned char *)alloc_low_region(MAC_CHUNK_SIZE);
            if (!nc) {
                pthread_mutex_unlock(&low_heap_lock);
                return NULL;
            }
            cur_chunk = nc;
            cur_offset = 0;
            cur_size = MAC_CHUNK_SIZE;
        }
        MacLowBlock *blk = (MacLowBlock *)(void *)(cur_chunk + cur_offset);
        cur_offset += align_up_sz(need, 64);
        blk->magic = MAC_HEADER_MAGIC;
        blk->capacity = size;
        blk->class_idx = cls;
        blk->next_free = NULL;
        pthread_mutex_unlock(&low_heap_lock);
        return (void *)(blk + 1);
    }

    /* Large or over-aligned allocation: dedicated low region, payload aligned to `align`. */
    size_t prefix = align_up_sz(sizeof(MacLowBlock), align);
    size_t total = align_up_sz(prefix + size, 16384);
    unsigned char *raw = (unsigned char *)alloc_low_region(total);
    pthread_mutex_unlock(&low_heap_lock);
    if (!raw) return NULL;
    unsigned char *payload = raw + prefix;
    MacLowBlock *blk = ((MacLowBlock *)(void *)payload) - 1;
    blk->magic = MAC_HEADER_MAGIC;
    blk->capacity = total - prefix;
    blk->class_idx = -2; /* standalone mach_vm region starting at payload - prefix */
    blk->pad[0] = (uint64_t)(uintptr_t)raw;
    blk->pad[1] = (uint64_t)total;
    blk->next_free = NULL;
    return payload;
}

void *compat_low_malloc(size_t size) {
    return compat_low_aligned_alloc(64, size);
}

void *compat_low_calloc(size_t count, size_t size) {
    if (count && size > SIZE_MAX / count) return NULL;
    size_t total = count * size;
    void *p = compat_low_aligned_alloc(64, total ? total : 1);
    if (p) memset(p, 0, total ? total : 1);
    return p;
}

void compat_low_free(void *ptr) {
    if (!ptr) return;
    uintptr_t u = (uintptr_t)ptr;
    if (u < MAC_HEAP_MIN + sizeof(MacLowBlock) || u >= MAC_HEAP_MAX) {
        free(ptr);
        return;
    }
    MacLowBlock *blk = ((MacLowBlock *)ptr) - 1;
    if (blk->magic != MAC_HEADER_MAGIC) {
        return;
    }
    if (blk->class_idx == -2) {
        mach_vm_deallocate(mach_task_self(), (mach_vm_address_t)blk->pad[0], (mach_vm_size_t)blk->pad[1]);
        return;
    }
    if (blk->class_idx >= 0 && blk->class_idx < MAC_SIZE_CLASSES) {
        pthread_mutex_lock(&low_heap_lock);
        blk->next_free = free_lists[blk->class_idx];
        free_lists[blk->class_idx] = blk;
        pthread_mutex_unlock(&low_heap_lock);
    }
}

/* ---- Timed lock helpers (CLOCK_REALTIME deadlines) ---- */
static int64_t diff_ns(const struct timespec *end, const struct timespec *now) {
    int64_t s = (int64_t)end->tv_sec - (int64_t)now->tv_sec;
    int64_t ns = (int64_t)end->tv_nsec - (int64_t)now->tv_nsec;
    if (s > INT64_MAX / 1000000000LL) return INT64_MAX;
    if (s < INT64_MIN / 1000000000LL) return -1;
    return s * 1000000000LL + ns;
}

static void sleep_step_ns(int64_t rem_ns, int64_t cap_ns) {
    int64_t wait = rem_ns < cap_ns ? rem_ns : cap_ns;
    if (wait <= 0) return;
    struct timespec req = {
        .tv_sec = (time_t)(wait / 1000000000LL),
        .tv_nsec = (long)(wait % 1000000000LL),
    };
    nanosleep(&req, NULL);
}

int compat_pthread_mutex_timedlock(pthread_mutex_t *mutex, const struct timespec *abstime) {
    if (!abstime || abstime->tv_nsec < 0 || abstime->tv_nsec >= 1000000000L) return EINVAL;
    int64_t step = 10000; /* 10 us -> 200 us adaptive backoff */
    for (;;) {
        int rc = pthread_mutex_trylock(mutex);
        if (rc != EBUSY) return rc;
        struct timespec now;
        clock_gettime(CLOCK_REALTIME, &now);
        int64_t rem = diff_ns(abstime, &now);
        if (rem <= 0) return ETIMEDOUT;
        sleep_step_ns(rem, step);
        if (step < 200000) step *= 2;
    }
}

int compat_pthread_rwlock_timedrdlock(pthread_rwlock_t *rwlock, const struct timespec *abstime) {
    if (!abstime || abstime->tv_nsec < 0 || abstime->tv_nsec >= 1000000000L) return EINVAL;
    int64_t step = 10000;
    for (;;) {
        int rc = pthread_rwlock_tryrdlock(rwlock);
        if (rc != EBUSY) return rc;
        struct timespec now;
        clock_gettime(CLOCK_REALTIME, &now);
        int64_t rem = diff_ns(abstime, &now);
        if (rem <= 0) return ETIMEDOUT;
        sleep_step_ns(rem, step);
        if (step < 200000) step *= 2;
    }
}

int compat_pthread_rwlock_timedwrlock(pthread_rwlock_t *rwlock, const struct timespec *abstime) {
    if (!abstime || abstime->tv_nsec < 0 || abstime->tv_nsec >= 1000000000L) return EINVAL;
    int64_t step = 10000;
    for (;;) {
        int rc = pthread_rwlock_trywrlock(rwlock);
        if (rc != EBUSY) return rc;
        struct timespec now;
        clock_gettime(CLOCK_REALTIME, &now);
        int64_t rem = diff_ns(abstime, &now);
        if (rem <= 0) return ETIMEDOUT;
        sleep_step_ns(rem, step);
        if (step < 200000) step *= 2;
    }
}

int compat_cond_timedwait_monotonic(pthread_cond_t *cond, pthread_mutex_t *mutex,
                                    const struct timespec *mono_deadline) {
    if (!mono_deadline || mono_deadline->tv_nsec < 0 || mono_deadline->tv_nsec >= 1000000000L)
        return EINVAL;
    struct timespec now;
    clock_gettime(CLOCK_MONOTONIC, &now);
    int64_t rem = diff_ns(mono_deadline, &now);
    if (rem <= 0) return ETIMEDOUT;
    struct timespec rel = {
        .tv_sec = (time_t)(rem / 1000000000LL),
        .tv_nsec = (long)(rem % 1000000000LL),
    };
    return pthread_cond_timedwait_relative_np(cond, mutex, &rel);
}

/* ---- Safe non-faulting memory read ---- */
ssize_t compat_read_own_memory(void *out, const void *source, size_t size) {
    if (size == 0) return 0;
    mach_vm_size_t out_size = 0;
    kern_return_t kr = mach_vm_read_overwrite(
        mach_task_self(), (mach_vm_address_t)(uintptr_t)source, (mach_vm_size_t)size,
        (mach_vm_address_t)(uintptr_t)out, &out_size);
    return kr == KERN_SUCCESS ? (ssize_t)out_size : -1;
}

/* ---- pthread_barrier_t ---- */
int compat_pthread_barrier_init(compat_pthread_barrier_t *b, const void *attr, unsigned count) {
    (void)attr;
    if (!b || count == 0) return EINVAL;
    if (pthread_mutex_init(&b->mutex, NULL) != 0) return ENOMEM;
    if (pthread_cond_init(&b->cond, NULL) != 0) {
        pthread_mutex_destroy(&b->mutex);
        return ENOMEM;
    }
    b->count = count;
    b->waiting = 0;
    b->phase = 0;
    return 0;
}

int compat_pthread_barrier_wait(compat_pthread_barrier_t *b) {
    pthread_mutex_lock(&b->mutex);
    unsigned phase = b->phase;
    if (++b->waiting == b->count) {
        b->waiting = 0;
        ++b->phase;
        pthread_cond_broadcast(&b->cond);
        pthread_mutex_unlock(&b->mutex);
        return PTHREAD_BARRIER_SERIAL_THREAD;
    }
    while (phase == b->phase) {
        pthread_cond_wait(&b->cond, &b->mutex);
    }
    pthread_mutex_unlock(&b->mutex);
    return 0;
}

int compat_pthread_barrier_destroy(compat_pthread_barrier_t *b) {
    if (!b) return EINVAL;
    pthread_cond_destroy(&b->cond);
    pthread_mutex_destroy(&b->mutex);
    return 0;
}

#endif /* __APPLE__ */
