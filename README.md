# Crash Team Racing Nitro-Fueled — macOS (Apple Silicon)

A native macOS port and SwiftUI launcher for **Crash Team Racing Nitro-Fueled** (`CUSA13795` / `CUSA14876`, v01.21) on Apple Silicon Macs (`x86_64` under Rosetta 2 + Mesa KosmicKrisp Vulkan 1.4-on-Metal).

Based on [CTR-NitroFueled-PC](https://github.com/GetLostIn/CTR-NitroFueled-PC) (SacredFire / bbport).

## Architecture & Highlights

- **Native SwiftUI macOS Launcher (`Crash Team Racing Nitro Fueled MacOS`)**:
  - One-click **KosmicKrisp & Homebrew Setup**, **Engine Build**, and **Launch** workflow.
  - Complete GUI for **Display & Graphics** (Resolution, Aspect Ratio 16:9 / 21:9 / 32:9, Upscaling / FSR3, Frame Generation, 60 FPS / 120 FPS patches), **Controls & Gamepads**, **Mods & Patches**, **DLC & Save Management**, and **Private Online Server** configuration.
- **Darwin `x86_64` Runtime (`CTR-NitroFueled-PC/src/`)**:
  - Dedicated guest TLS via Darwin `%gs` TSD slot rewriting (`scripts/link_libc.py`, `src/runtime_thread.c`).
  - Dual `SIGSEGV` + `SIGBUS` hardware fault and ISA emulation handlers for Rosetta 2 (`src/probe.c`, `src/compat_mac.h`, `src/compat_mac.c`).
  - Main-thread Cocoa/AppKit SDL3 event pump (`Thread 0`) paired with a 16 MiB background pthread running the PS4 `eboot.bin`.
- **Vulkan / KosmicKrisp GPU Layer (`CTR-NitroFueled-PC/gpu/`)**:
  - `CAMetalLayer`-backed SDL3 window creation (`gpu/shim/window.cpp`, `gpu/shim/bbgpu.cpp`).
  - `VK_KHR_portability_enumeration` and `VK_KHR_portability_subset` support with dynamic buffer arena sizing for Metal buffer limits (`gpu/shadps4/video_core/buffer_cache/buffer_cache.cpp`).

## Contributors

- **Ace The Squirrel** ([@redtreerat](https://github.com/redtreerat))
- **Google Antigravity** — AI Pair Programmer & macOS Porting Engineer (Google DeepMind)
- **GetLostIn & SacredFire Contributors** — Upstream [CTR-NitroFueled-PC](https://github.com/GetLostIn/CTR-NitroFueled-PC) & [shadPS4](https://github.com/shadps4-emu/shadPS4)
