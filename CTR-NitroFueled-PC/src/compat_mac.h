/* macOS (Darwin x86_64 under Rosetta 2) POSIX compatibility and low-40-bit heap helpers.
 * PS4 guest code packs pointers (pthread_mutex_t, pthread_cond_t, pthread_rwlock_t,
 * pthread_t, TLS blocks, __error) into 40-bit fields (< 1 TiB). Darwin's system malloc
 * places MALLOC_NANO at 0x6000... (96 TiB) and MALLOC_TINY at 0x7f... (127 TiB), so host
 * structs referenced by guest handles are allocated below 63 GiB via compat_low_*. */
#ifndef BB_COMPAT_MAC_H
#define BB_COMPAT_MAC_H
#ifdef __APPLE__

#include <pthread.h>
#include <stddef.h>
#include <stdint.h>
#include <sys/types.h>
#include <time.h>

#ifdef __cplusplus
extern "C" {
#endif

void *compat_low_malloc(size_t size);
void *compat_low_calloc(size_t count, size_t size);
void *compat_low_aligned_alloc(size_t align, size_t size);
void compat_low_free(void *ptr);

/* Darwin lacks POSIX pthread_mutex_timedlock and pthread_rwlock_timed{rd,wr}lock.
 * Deadlines are CLOCK_REALTIME (matching runtime_mutex.c / runtime_rwlock.c). */
int compat_pthread_mutex_timedlock(pthread_mutex_t *mutex, const struct timespec *abstime);
int compat_pthread_rwlock_timedrdlock(pthread_rwlock_t *rwlock, const struct timespec *abstime);
int compat_pthread_rwlock_timedwrlock(pthread_rwlock_t *rwlock, const struct timespec *abstime);

/* Darwin lacks pthread_condattr_setclock(CLOCK_MONOTONIC); converts a CLOCK_MONOTONIC
 * deadline into a relative wait via pthread_cond_timedwait_relative_np. */
int compat_cond_timedwait_monotonic(pthread_cond_t *cond, pthread_mutex_t *mutex,
                                    const struct timespec *mono_deadline);

/* Non-faulting read of own process memory (replaces Linux process_vm_readv). */
ssize_t compat_read_own_memory(void *out, const void *source, size_t size);

/* POSIX pthread_barrier_t shim (used by tests/test_runtime.c). */
#ifndef PTHREAD_BARRIER_SERIAL_THREAD
#define PTHREAD_BARRIER_SERIAL_THREAD (-1)
typedef struct {
    pthread_mutex_t mutex;
    pthread_cond_t cond;
    unsigned count;
    unsigned waiting;
    unsigned phase;
} compat_pthread_barrier_t;
typedef int compat_pthread_barrierattr_t;
#define pthread_barrier_t compat_pthread_barrier_t
#define pthread_barrierattr_t compat_pthread_barrierattr_t
int compat_pthread_barrier_init(compat_pthread_barrier_t *b, const void *attr, unsigned count);
int compat_pthread_barrier_wait(compat_pthread_barrier_t *b);
int compat_pthread_barrier_destroy(compat_pthread_barrier_t *b);
#define pthread_barrier_init compat_pthread_barrier_init
#define pthread_barrier_wait compat_pthread_barrier_wait
#define pthread_barrier_destroy compat_pthread_barrier_destroy
#endif

#ifdef __cplusplus
}
#endif

#endif /* __APPLE__ */
#endif /* BB_COMPAT_MAC_H */
