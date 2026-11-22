// SPDX-License-Identifier: GPL-2.0-or-later
#include "bbport_clobber.h"

#include <algorithm>
#include <array>
#include <atomic>
#include <cinttypes>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <x86intrin.h>
#ifndef _WIN32
#include <pthread.h>
#include <sys/mman.h>
#include <sys/ucontext.h>
#include <unistd.h>
#endif

namespace BbClobber {
namespace {
constexpr std::uint64_t PageSize = 4096;
constexpr std::uint64_t TableSlots = 1 << 16; // 65 536 4K pages = 256 MiB active window

struct Slot {
    std::atomic<std::uint64_t> page{0};
    std::atomic<std::uint64_t> submit{0};
    std::atomic<std::uint64_t> submission_id{0};
    std::atomic<std::uint64_t> first_write{0};
    std::atomic<std::uint64_t> last_write{0};
    std::atomic<std::uint32_t> write_count{0};
    std::atomic<std::uint32_t> source{0}; // 1 = fault, 2 = submission scan
    std::atomic<std::uint64_t> first_address{0};
    std::atomic<std::uint64_t> first_rip{0};
    char first_thread[16]{};
};

std::array<Slot, TableSlots> slots{};

std::atomic<std::uint64_t> current_submission_id{0};
std::atomic<std::uint64_t> submissions{0};
std::atomic<std::uint64_t> command_pages{0};
std::atomic<std::uint64_t> vertex_pages{0};
std::atomic<std::uint64_t> writes_to_watched_pages{0};
std::atomic<std::uint64_t> clobbered_pages{0};
std::atomic<std::uint64_t> clobbered_under_1ms{0};
std::atomic<std::uint64_t> clobbered_under_5ms{0};
std::atomic<std::uint64_t> clobbered_under_20ms{0};
std::atomic<std::uint64_t> report_due{0};

std::uint64_t Rdtsc() {
    return __rdtsc();
}

double TscToMs(std::uint64_t ticks) {
    // A rough 3 GHz scale for bucketing and logs; the ratios are what matter.
    return static_cast<double>(ticks) / 3.0e6;
}

Slot* FindOrClaim(std::uint64_t page) {
    const std::uint64_t start = ((page >> 12) * 0x9e3779b97f4a7c15ull) & (TableSlots - 1);
    for (std::uint64_t probe = 0; probe < 16; ++probe) {
        Slot& s = slots[(start + probe) & (TableSlots - 1)];
        std::uint64_t cur = s.page.load(std::memory_order_relaxed);
        if (cur == page) {
            return &s;
        }
        if (cur == 0) {
            if (s.page.compare_exchange_strong(cur, page, std::memory_order_relaxed) ||
                cur == page) {
                return &s;
            }
        }
    }
    // Evict the oldest slot in the probe window.
    Slot& victim = slots[start];
    victim.page.store(page, std::memory_order_relaxed);
    victim.submit.store(0, std::memory_order_relaxed);
    victim.first_write.store(0, std::memory_order_relaxed);
    victim.last_write.store(0, std::memory_order_relaxed);
    victim.write_count.store(0, std::memory_order_relaxed);
    victim.source.store(0, std::memory_order_relaxed);
    return &victim;
}

Slot* Find(std::uint64_t page) {
    const std::uint64_t start = ((page >> 12) * 0x9e3779b97f4a7c15ull) & (TableSlots - 1);
    for (std::uint64_t probe = 0; probe < 16; ++probe) {
        Slot& s = slots[(start + probe) & (TableSlots - 1)];
        const std::uint64_t cur = s.page.load(std::memory_order_relaxed);
        if (cur == page) {
            return &s;
        }
        if (cur == 0) {
            return nullptr;
        }
    }
    return nullptr;
}

void TouchRange(std::uint64_t address, std::uint64_t bytes, std::uint32_t kind) {
    if (address == 0 || bytes == 0) {
        return;
    }
    const std::uint64_t now = Rdtsc();
    const std::uint64_t id = current_submission_id.load(std::memory_order_relaxed);
    const std::uint64_t first_page = address & ~(PageSize - 1);
    const std::uint64_t last_page = (address + bytes - 1) & ~(PageSize - 1);
    // Cap at 64 pages per range so a large buffer does not flood the table.
    std::uint64_t count = 0;
    for (std::uint64_t page = first_page; page <= last_page && count < 64;
         page += PageSize, ++count) {
        Slot* s = FindOrClaim(page);
        s->submit.store(now, std::memory_order_relaxed);
        s->submission_id.store(id, std::memory_order_relaxed);
        s->first_write.store(0, std::memory_order_relaxed);
        s->last_write.store(0, std::memory_order_relaxed);
        s->write_count.store(0, std::memory_order_relaxed);
        s->source.store(kind, std::memory_order_relaxed);
    }
    if (kind == 1) {
        command_pages.fetch_add(count, std::memory_order_relaxed);
    } else {
        vertex_pages.fetch_add(count, std::memory_order_relaxed);
    }
}

void RecordWrite(Slot* s, std::uint64_t address, std::uint64_t rip, std::uint64_t now) {
    const std::uint64_t sub = s->submit.load(std::memory_order_relaxed);
    if (sub == 0 || now < sub) {
        return;
    }
    writes_to_watched_pages.fetch_add(1, std::memory_order_relaxed);
    s->last_write.store(now, std::memory_order_relaxed);
    if (s->write_count.fetch_add(1, std::memory_order_relaxed) == 0) {
        s->first_write.store(now, std::memory_order_relaxed);
        s->first_address.store(address, std::memory_order_relaxed);
        s->first_rip.store(rip, std::memory_order_relaxed);
#ifndef _WIN32
        pthread_getname_np(pthread_self(), s->first_thread, sizeof(s->first_thread));
#else
        std::strncpy(s->first_thread, "win", sizeof(s->first_thread) - 1);
#endif
        clobbered_pages.fetch_add(1, std::memory_order_relaxed);
        const double ms = TscToMs(now - sub);
        if (ms < 1.0) {
            clobbered_under_1ms.fetch_add(1, std::memory_order_relaxed);
        } else if (ms < 5.0) {
            clobbered_under_5ms.fetch_add(1, std::memory_order_relaxed);
        } else if (ms < 20.0) {
            clobbered_under_20ms.fetch_add(1, std::memory_order_relaxed);
        }
    }
}
} // namespace

bool Enabled() {
    static const bool enabled = [] {
        const char* env = std::getenv("BB_CLOBBER_STATS");
        return env && env[0] == '1';
    }();
    return enabled;
}

void BeginSubmission() {
    if (!Enabled()) {
        return;
    }
    current_submission_id.fetch_add(1, std::memory_order_relaxed);
    if ((submissions.fetch_add(1, std::memory_order_relaxed) + 1) % 300 == 0) {
        report_due.store(1, std::memory_order_relaxed);
    }
    if (report_due.exchange(0, std::memory_order_relaxed) != 0) {
        ReportNow();
    }
}

void AskForReport() {
    report_due.store(1, std::memory_order_relaxed);
}

void ReportNow() {
    std::printf(
        "Clobber stats: %" PRIu64 " submissions, %" PRIu64 " cmd pages, %" PRIu64
        " vertex/index pages watched; %" PRIu64 " CPU writes hit a watched page (%" PRIu64
        " distinct pages: %" PRIu64 " <1ms, %" PRIu64 " 1-5ms, %" PRIu64 " 5-20ms after submit)\n",
        submissions.load(std::memory_order_relaxed), command_pages.load(std::memory_order_relaxed),
        vertex_pages.load(std::memory_order_relaxed),
        writes_to_watched_pages.load(std::memory_order_relaxed),
        clobbered_pages.load(std::memory_order_relaxed),
        clobbered_under_1ms.load(std::memory_order_relaxed),
        clobbered_under_5ms.load(std::memory_order_relaxed),
        clobbered_under_20ms.load(std::memory_order_relaxed));
    // Print up to 8 recently clobbered pages with the earliest write delta.
    int printed = 0;
    for (const Slot& s : slots) {
        const std::uint32_t wc = s.write_count.load(std::memory_order_relaxed);
        const std::uint64_t sub = s.submit.load(std::memory_order_relaxed);
        const std::uint64_t fw = s.first_write.load(std::memory_order_relaxed);
        if (wc > 0 && sub > 0 && fw >= sub && TscToMs(fw - sub) < 20.0) {
            std::printf("  clobbered %s page %#llx (submit #%" PRIu64
                        "): first write %.2f ms after submit at %#llx from RIP %#llx "
                        "(thread %s, %u writes)\n",
                        s.source.load(std::memory_order_relaxed) == 1 ? "cmd" : "vtx",
                        (unsigned long long)s.page.load(std::memory_order_relaxed),
                        s.submission_id.load(std::memory_order_relaxed), TscToMs(fw - sub),
                        (unsigned long long)s.first_address.load(std::memory_order_relaxed),
                        (unsigned long long)s.first_rip.load(std::memory_order_relaxed),
                        s.first_thread, wc);
            if (++printed >= 8) {
                break;
            }
        }
    }
    std::fflush(stdout);
}

void TouchCommandRange(std::uint64_t address, std::uint64_t bytes) {
    if (Enabled()) {
        TouchRange(address, bytes, 1);
    }
}

void TouchSubmittedRange(std::uint64_t address, std::uint64_t bytes) {
    if (Enabled()) {
        TouchRange(address, bytes, 2);
    }
}

void TouchCpuWrite(std::uint64_t address, std::uint64_t rip) {
    if (!Enabled()) {
        return;
    }
    if (Slot* s = Find(address & ~(PageSize - 1))) {
        RecordWrite(s, address, rip, Rdtsc());
    }
}

void TouchCpuWriteRange(std::uint64_t address, std::uint64_t bytes) {
    if (!Enabled() || address == 0 || bytes == 0) {
        return;
    }
    const std::uint64_t now = Rdtsc();
    const std::uint64_t first = address & ~(PageSize - 1);
    const std::uint64_t last = (address + bytes - 1) & ~(PageSize - 1);
    for (std::uint64_t page = first; page <= last; page += PageSize) {
        if (Slot* s = Find(page)) {
            RecordWrite(s, page == first ? address : page, 0, now);
        }
    }
}

namespace {
bool ProtectCopies() {
    static const bool enabled = [] {
        const char* env = std::getenv("BB_PROTECT_CMD_COPIES");
        return env && env[0] == '1';
    }();
    return enabled;
}

struct Protected {
    std::atomic<std::uint64_t> base{0};
    std::atomic<std::uint64_t> bytes{0};
    std::atomic<std::uint64_t> seq{0};
};
constexpr std::size_t MaxProtected = 32;
std::array<Protected, MaxProtected> protected_copies{};
std::atomic<std::uint64_t> protected_seq{0};
} // namespace

const std::uint32_t* MakeProtectedCopy(const std::uint32_t* src, std::uint64_t num_dw) {
#ifdef _WIN32
    (void)src;
    (void)num_dw;
    return nullptr;
#else
    if (!ProtectCopies() || src == nullptr || num_dw == 0) {
        return nullptr;
    }
    const std::uint64_t bytes = num_dw * sizeof(std::uint32_t);
    const std::uint64_t map_bytes = (bytes + PageSize - 1) & ~(PageSize - 1);
    const std::uint64_t seq = protected_seq.fetch_add(1, std::memory_order_relaxed) + 1;
    Protected& slot = protected_copies[seq % MaxProtected];
    const std::uint64_t old_base = slot.base.exchange(0, std::memory_order_acq_rel);
    const std::uint64_t old_bytes = slot.bytes.exchange(0, std::memory_order_acq_rel);
    if (old_base != 0 && old_bytes != 0) {
        munmap(reinterpret_cast<void*>(old_base), (old_bytes + PageSize - 1) & ~(PageSize - 1));
    }
    void* mem = mmap(nullptr, map_bytes, PROT_READ | PROT_WRITE, MAP_PRIVATE | MAP_ANONYMOUS, -1, 0);
    if (mem == MAP_FAILED) {
        return nullptr;
    }
    std::memcpy(mem, src, bytes);
    mprotect(mem, map_bytes, PROT_READ);
    slot.bytes.store(bytes, std::memory_order_release);
    slot.seq.store(seq, std::memory_order_release);
    slot.base.store(reinterpret_cast<std::uint64_t>(mem), std::memory_order_release);
    return static_cast<const std::uint32_t*>(mem);
#endif
}

bool OnFault(void* ucontext, std::uint64_t address) {
#ifdef _WIN32
    (void)ucontext;
    (void)address;
    return false;
#else
    if (!ProtectCopies()) {
        return false;
    }
    for (const Protected& p : protected_copies) {
        const std::uint64_t base = p.base.load(std::memory_order_relaxed);
        const std::uint64_t bytes = p.bytes.load(std::memory_order_relaxed);
        if (base != 0 && address >= base && address < base + bytes) {
            const auto* uc = static_cast<const ucontext_t*>(ucontext);
            char thread[32] = "?";
            pthread_getname_np(pthread_self(), thread, sizeof(thread));
            char line[256];
#ifdef __APPLE__
            const unsigned long long rip = (unsigned long long)uc->uc_mcontext->__ss.__rip;
#else
            const unsigned long long rip = (unsigned long long)uc->uc_mcontext.gregs[REG_RIP];
#endif
            const int n = std::snprintf(
                line, sizeof(line),
                "Clobber trap: a write to the read-only copy of submission %llu at +%#llx (host "
                "%#llx; copy of %llu bytes at %#llx) from RIP %#llx, thread %s\n",
                (unsigned long long)p.seq.load(std::memory_order_relaxed),
                (unsigned long long)(address - base), (unsigned long long)address,
                (unsigned long long)bytes, (unsigned long long)base,
                rip, thread);
            if (n > 0) {
                const ssize_t written = write(2, line, std::min<std::size_t>(n, sizeof(line) - 1));
                (void)written;
            }
            AskForReport();
            return true;
        }
    }
    return false;
#endif
}
} // namespace BbClobber
