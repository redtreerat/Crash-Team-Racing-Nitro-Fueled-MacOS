// SPDX-License-Identifier: GPL-2.0-or-later
// bbport: CPU affinity and priority of the GPU library's background worker threads
// (copy pool, shader compile pool, draw recorder).
//
// Under wine/ntsync (or a busy desktop) the process may be pinned to a subset of CPUs, and
// threads spawned from a guest thread inherit its priority and mask. The game's worker
// threads spin in the kernel when a frame runs long; background GPU threads at the same
// priority then wait for a core while the GPU command thread waits for them.
#pragma once
#include <algorithm>
#include <thread>
#ifdef _WIN32
#include <windows.h>
#elif defined(__APPLE__)
#include <pthread.h>
#include <pthread/qos.h>
#else
#include <pthread.h>
#include <sched.h>
#include <sys/resource.h>
#include <unistd.h>
#endif

namespace BbThreads {

inline unsigned Available() {
#ifdef _WIN32
    DWORD_PTR proc = 0, sys = 0;
    if (GetProcessAffinityMask(GetCurrentProcess(), &proc, &sys) && proc) {
        unsigned n = 0;
        for (DWORD_PTR m = proc; m; m &= m - 1) ++n;
        return n;
    }
    return std::max(1u, std::thread::hardware_concurrency());
#elif defined(__APPLE__)
    return std::max(1u, std::thread::hardware_concurrency());
#else
    cpu_set_t set;
    CPU_ZERO(&set);
    if (sched_getaffinity(0, sizeof(set), &set) == 0) {
        const int n = CPU_COUNT(&set);
        if (n > 0) {
            return unsigned(n);
        }
    }
    return std::max(1u, std::thread::hardware_concurrency());
#endif
}

// Lower priority than guest threads; normal scheduling class on all allowed CPUs in case the
// spawner was pinned.
inline void MakeBackground() {
#ifdef _WIN32
    SetThreadPriority(GetCurrentThread(), THREAD_PRIORITY_BELOW_NORMAL);
#elif defined(__APPLE__)
    pthread_set_qos_class_self_np(QOS_CLASS_UTILITY, 0);
#else
    sched_param sp{};
    pthread_setschedparam(pthread_self(), SCHED_OTHER, &sp);
    setpriority(PRIO_PROCESS, 0, 5);
#endif
}

} // namespace BbThreads
