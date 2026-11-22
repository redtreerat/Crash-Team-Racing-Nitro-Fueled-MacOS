// SPDX-License-Identifier: GPL-2.0-or-later
// bbport (macOS): small POSIX/Mach helpers the renderer uses for diagnostics and thread
// identity. Force-included into the GPU library on macOS (CMakeLists.txt).
#pragma once
#ifdef __APPLE__
#include <pthread.h>
#include <stddef.h>
#include <stdint.h>
#include <sys/types.h>
#include <sys/uio.h>
#ifdef __cplusplus
extern "C" {
#endif
static inline int gettid(void) {
    uint64_t tid = 0;
    pthread_threadid_np(NULL, &tid);
    return (int)tid;
}
/* SacredFire diagnostics read guest memory that may be unmapped with process_vm_readv on
 * Linux; on macOS mach_vm_read_overwrite on mach_task_self() does the same (src/compat_mac.c). */
ssize_t compat_read_own_memory(void* out, const void* source, size_t size);
static inline ssize_t process_vm_readv(int pid, const struct iovec* local, unsigned long local_count,
                                       const struct iovec* remote, unsigned long remote_count,
                                       unsigned long flags) {
    (void)pid;
    (void)flags;
    if (local_count != 1 || remote_count != 1) {
        return -1;
    }
    const size_t size = local->iov_len < remote->iov_len ? local->iov_len : remote->iov_len;
    return compat_read_own_memory(local->iov_base, remote->iov_base, size);
}
#ifdef __cplusplus
}
#endif
#endif
