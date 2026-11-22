// SPDX-License-Identifier: GPL-2.0-or-later
#include "bbport_guest_hooks.h"

#if defined(_WIN32) || defined(__APPLE__)
// SacredFire (Windows/macOS): Linux-only SIGTRAP hooks for the dma-buf PC memory model.
namespace BbGuestHooks {
void Install(RangeCallback) {}
} // namespace BbGuestHooks
#else

#include <array>
#include <atomic>
#include <csignal>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <sys/mman.h>
#include <sys/uio.h>
#include <ucontext.h>
#include <unistd.h>
#include "bbport_clobber.h"
#include "bbport_heap_sites.h"
#include "bbport_stats.h"

namespace BbGuestHooks {
namespace {
using u64 = std::uint64_t;
constexpr u64 ImageBase = 0x800000000ull;

struct Site {
    u64 offset;
    unsigned char code[5];
};

// The resource loader's two `call memcpy` sites into newly allocated GPU memory.
constexpr std::array<Site, 2> MemcpySites{{
    {0x2b6e35c, {0xe8, 0xcf, 0xd8, 0xda, 0xfd}},
    {0x2b6e39b, {0xe8, 0x90, 0xd8, 0xda, 0xfd}},
}};

// The GPU direct memory allocator's return (`add rsp, 0x18; ret`): rax is the node whose
// +0x08 is the allocated range's start and +0x18 is the next node (+0x08 its start, the end).
constexpr u64 AllocReturn = 0x26af819;
constexpr unsigned char AllocReturnCode[5] = {0x48, 0x83, 0xc4, 0x18, 0xc3};
RangeCallback on_range_allocated = nullptr;

// The GPU heap's allocation sites (`call [rcx+0x28]` followed by `mov rbx, rax` = 48 89 c3):
// rax is the allocated GPU address, [rbp-0x50] the size requested from the vtable allocator.
constexpr std::array<u64, 4> HeapAllocReturns{{0x26a82d9, 0x26a9bf6, 0x26a9fd6, 0x26aa446}};
constexpr unsigned char HeapAllocReturnCode[3] = {0x48, 0x89, 0xc3};

// The entry of the GPU range collector (0x26aa860, `push rbp` = 55), called once per frame for
// each of the two GPU allocators: rdi is the allocator, [rdi+0xd0] its allocated byte total.
constexpr u64 CollectorEntry = 0x26aa860;
constexpr unsigned char CollectorEntryCode[1] = {0x55};
std::array<std::atomic<u64>, 2> range_allocators{};

// The GPU heap's release check (0x26aa8e2, `cmp dword [rax], 4` = 83 38 04): [r14] is a
// released range node's label (or bit 0: a batch label pointer); when [rax] == 4, the GPU has
// written the release fence and the range is recycled (+0x8 start, +0x10 size).
constexpr u64 ReleaseCheck = 0x26aa8e2;
constexpr unsigned char ReleaseCheckCode[3] = {0x83, 0x38, 0x04};

struct sigaction previous_action {};
std::array<std::atomic<u64>, MemcpySites.size()> hits{};

void* LoaderCopy(void* dst, const void* src, std::size_t n) {
    std::memcpy(dst, src, n);
    if (n != 0) {
        BbClobber::TouchCpuWriteRange(reinterpret_cast<u64>(dst), n);
        if (on_range_allocated) {
            on_range_allocated(reinterpret_cast<u64>(dst), n);
        }
    }
    return dst;
}

void OnTrap(int sig, siginfo_t* info, void* context) {
    auto* uc = static_cast<ucontext_t*>(context);
    auto& g = uc->uc_mcontext.gregs;
    const u64 rip = u64(g[REG_RIP]) - 1; // int3 leaves RIP one byte past the 0xcc
    if (rip == ImageBase + ReleaseCheck) {
        const u32 value = *reinterpret_cast<const u32*>(u64(g[REG_RAX]));
        if (value == 4) {
            const u64 node = u64(g[REG_R14]);
            BbHeapSites::NoteRelease(node, *reinterpret_cast<const u64*>(node + 0x8),
                                     *reinterpret_cast<const u64*>(node + 0x10));
        }
        // cmp dword [rax], 4: EFLAGS from value - 4 (the next instruction is jnz).
        u64 flags = 0;
        asm volatile("cmpl $4, %1; pushfq; popq %0" : "=r"(flags) : "r"(value) : "cc");
        constexpr u64 ArithMask = 0x8d5; // CF, PF, AF, ZF, SF, OF
        g[REG_EFL] = greg_t((u64(g[REG_EFL]) & ~ArithMask) | (flags & ArithMask));
        g[REG_RIP] = greg_t(ImageBase + ReleaseCheck + sizeof(ReleaseCheckCode));
        return;
    }
    if (rip == ImageBase + CollectorEntry) {
        const u64 allocator = u64(g[REG_RDI]);
        for (std::size_t i = 0; i < range_allocators.size(); ++i) {
            u64 expected = 0;
            if (range_allocators[i].load(std::memory_order_relaxed) == allocator ||
                range_allocators[i].compare_exchange_strong(expected, allocator)) {
                BbStats::range_bytes[i].store(*reinterpret_cast<const u64*>(allocator + 0xd0),
                                              std::memory_order_relaxed);
                break;
            }
        }
        g[REG_RSP] -= 8; // push rbp
        *reinterpret_cast<u64*>(g[REG_RSP]) = u64(g[REG_RBP]);
        g[REG_RIP] = greg_t(ImageBase + CollectorEntry + 1);
        return;
    }
    for (const u64 site : HeapAllocReturns) {
        if (rip != ImageBase + site) {
            continue;
        }
        const u64 address = u64(g[REG_RAX]);
        const u64 size = *reinterpret_cast<const u64*>(u64(g[REG_RBP]) - 0x50);
        if (address != 0 && size != 0 && size < (u64(1) << 32)) {
            on_range_allocated(address, size);
        }
        g[REG_RBX] = g[REG_RAX];
        g[REG_RIP] = greg_t(ImageBase + site + sizeof(HeapAllocReturnCode));
        return;
    }
    if (rip == ImageBase + AllocReturn) {
        if (const u64 node = u64(g[REG_RAX])) {
            const u64 start = *reinterpret_cast<const u64*>(node + 8);
            const u64 next = *reinterpret_cast<const u64*>(node + 0x18);
            const u64 end = next ? *reinterpret_cast<const u64*>(next + 8) : start;
            if (end > start && end - start < (u64(1) << 32)) {
                on_range_allocated(start, end - start);
            }
        }
        g[REG_RSP] += 0x18;
        g[REG_RIP] = greg_t(ImageBase + AllocReturn + sizeof(AllocReturnCode));
        return;
    }
    for (std::size_t i = 0; i < MemcpySites.size(); ++i) {
        const auto& site = MemcpySites[i];
        if (rip != ImageBase + site.offset) {
            continue;
        }
        hits[i].fetch_add(1, std::memory_order_relaxed);
        // The call, to LoaderCopy instead of the game's memcpy: push the return address, jump.
        const u64 ret = ImageBase + site.offset + 5;
        g[REG_RSP] -= 8;
        *reinterpret_cast<u64*>(g[REG_RSP]) = ret;
        g[REG_RIP] = greg_t(reinterpret_cast<u64>(&LoaderCopy));
        return;
    }
    if (previous_action.sa_flags & SA_SIGINFO) {
        if (previous_action.sa_sigaction) {
            previous_action.sa_sigaction(sig, info, context);
            return;
        }
    } else if (previous_action.sa_handler != SIG_DFL && previous_action.sa_handler != SIG_IGN &&
               previous_action.sa_handler) {
        previous_action.sa_handler(sig);
        return;
    }
    signal(SIGTRAP, SIG_DFL);
    raise(SIGTRAP);
}

bool Patch(u64 address, const unsigned char* expected, std::size_t size) {
    unsigned char bytes[16]{};
    iovec local{bytes, size}, remote{reinterpret_cast<void*>(address), size};
    if (process_vm_readv(getpid(), &local, 1, &remote, 1, 0) != ssize_t(size) ||
        std::memcmp(bytes, expected, size) != 0) {
        return false;
    }
    const long page_size = sysconf(_SC_PAGESIZE);
    void* page = reinterpret_cast<void*>(address & ~u64(page_size - 1));
    const std::size_t span = (address + size) - reinterpret_cast<u64>(page);
    if (mprotect(page, span, PROT_READ | PROT_WRITE | PROT_EXEC) != 0) {
        return false;
    }
    __atomic_store_n(reinterpret_cast<unsigned char*>(address), static_cast<unsigned char>(0xcc),
                     __ATOMIC_SEQ_CST);
    mprotect(page, span, PROT_READ | PROT_EXEC);
    return true;
}
} // namespace

void Install(RangeCallback on_gpu_range_allocated) {
    static std::atomic<bool> installed{false};
    if (installed.exchange(true)) {
        return;
    }
    struct sigaction action {};
    action.sa_sigaction = OnTrap;
    action.sa_flags = SA_SIGINFO | SA_NODEFER;
    sigemptyset(&action.sa_mask);
    sigaction(SIGTRAP, &action, &previous_action);
    int patched = 0;
    for (const auto& site : MemcpySites) {
        patched += Patch(ImageBase + site.offset, site.code, sizeof(site.code));
    }
    std::printf("Guest hooks: %d of %zu resource copy sites tell the GPU side of their writes\n",
                patched, MemcpySites.size());
    on_range_allocated = on_gpu_range_allocated;
    const bool allocator = Patch(ImageBase + AllocReturn, AllocReturnCode, sizeof(AllocReturnCode));
    // BB_HEAP_HOOKS=0 (bisecting): the heap's ranges are not reported.
    const char* heap_env = std::getenv("BB_HEAP_HOOKS");
    const bool heap_hooks = !heap_env || heap_env[0] != '0';
    if (BbStats::enabled) {
        Patch(ImageBase + CollectorEntry, CollectorEntryCode, sizeof(CollectorEntryCode));
    }
    int heap_sites = 0;
    for (const u64 site : HeapAllocReturns) {
        if (!heap_hooks) {
            break;
        }
        heap_sites += Patch(ImageBase + site, HeapAllocReturnCode, sizeof(HeapAllocReturnCode));
    }
    std::printf("Guest hooks: GPU heap allocations seen at %d of %zu call sites\n", heap_sites,
                HeapAllocReturns.size());
    std::printf("Guest hooks: GPU memory allocator %s\n", allocator ? "tells the GPU side of new ranges" : "not found");
    BbHeapSites::Install();
    if (const char* env = std::getenv("BB_HEAP_SITES"); env && env[0] == '1') {
        Patch(ImageBase + ReleaseCheck, ReleaseCheckCode, sizeof(ReleaseCheckCode));
    }
}
} // namespace BbGuestHooks
#endif // defined(_WIN32) || defined(__APPLE__)
