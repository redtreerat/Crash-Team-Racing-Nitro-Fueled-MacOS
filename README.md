# Crash Team Racing Nitro-Fueled — macOS (Apple Silicon)

![Status: Playable on Apple Silicon](https://img.shields.io/badge/Status-Playable%20on%20Apple%20Silicon-brightgreen)
![Platform: macOS 26+ (Apple Silicon)](https://img.shields.io/badge/Platform-macOS%2026%2B%20(Apple%20Silicon)-blue)
![Graphics: Mesa KosmicKrisp Vulkan 1.4](https://img.shields.io/badge/Graphics-Mesa%20KosmicKrisp%20Vulkan%201.4-orange)

A native macOS port and SwiftUI launcher for **Crash Team Racing Nitro-Fueled** (`CUSA13795` / `CUSA14876`, v01.21) on Apple Silicon Macs (`x86_64` under Rosetta 2 + Mesa KosmicKrisp Vulkan 1.4-on-Metal).

Based on [CTR-NitroFueled-PC](https://github.com/GetLostIn/CTR-NitroFueled-PC) (SacredFire / bbport).

## Current Status: Playable

**Crash Team Racing Nitro-Fueled is booting and playable on Apple Silicon Macs!**

- **Verified On**: Apple M5 Pro, macOS 27.0.1, Rosetta 2 (`x86_64`), Mesa KosmicKrisp Vulkan 1.4.363 (`VK_EXT_robustness2` over Metal 4)
- **Working**:
  - Live Vulkan 1.4 rendering (1080p+ / 60 FPS unlock patch) via Mesa KosmicKrisp
  - CoreAudio / FMOD audio & ATRAC9 decoding
  - Bink video playback (intros / cutscenes)
  - Keyboard and SDL3 gamepad input (with native macOS Cocoa/IOKit hotplug)
  - One-click dependency bootstrap (including automatic `x86_64` KosmicKrisp download), build, and launch from the SwiftUI macOS Launcher
- **Note on MoltenVK**: MoltenVK does not implement `VK_EXT_robustness2` (`robustBufferAccess2` / `nullDescriptor`), which `shadPS4`'s Vulkan 1.4 renderer requires. **Mesa KosmicKrisp** (macOS 26+ on Apple Silicon with Metal 4) is automatically installed into `CTR-NitroFueled-PC/out/icd/` by `tools/setup_mac_deps.sh` and selected by default.

## Requirements

- **Apple Silicon Mac** (M1–M5) running **macOS 26 (Tahoe) or later** (required for Metal 4 / Mesa KosmicKrisp)
- **Rosetta 2** (installed automatically by the bootstrapper if missing)
- **Xcode** (to build and run the SwiftUI launcher) and **`x86_64` Homebrew** in `/usr/local`
- A legitimate decrypted PS4 dump of **Crash Team Racing Nitro-Fueled** (`CUSA13795` or `CUSA14876`, update `01.21`)

## Quick Start

1. Open `Crash Team Racing Nitro Fueled MacOS.xcodeproj` in Xcode and run the app (⌘R).
2. Go to the **Mac Port & Build** tab and click:
   1. **Bootstrap macOS Dependencies** (installs required `x86_64` Homebrew packages, third-party headers/submodules, and the `x86_64` Mesa KosmicKrisp Vulkan 1.4 driver).
   2. **Build sacredfire (x86_64)** (compiles `libbbgpu.dylib`, `bb-gpu-capabilities`, and `sacredfire`).
3. Go to the **Play** tab, select your decrypted CTR Nitro-Fueled game folder, and click **Play**.

## Architecture & Highlights

- **Native SwiftUI macOS Launcher (`Crash Team Racing Nitro Fueled MacOS`)**:
  - One-click **KosmicKrisp & Homebrew Setup**, **Engine Build**, and **Launch** workflow.
  - Complete GUI for **Display & Graphics** (Resolution, Aspect Ratio 16:9 / 21:9 / 32:9, Upscaling / FSR3, Frame Generation, 60 FPS / 120 FPS patches), **Controls & Gamepads**, **Mods & Patches**, **DLC & Save Management**, and **Private Online Server** configuration.
- **Darwin `x86_64` Runtime (`CTR-NitroFueled-PC/src/`)**:
  - Dedicated guest TLS via Darwin `%gs` TSD slot rewriting (`scripts/link_libc.py`, `src/runtime_thread.c`).
  - Dual `SIGSEGV` + `SIGBUS` hardware fault and ISA emulation handlers for Rosetta 2 (`src/probe.c`, `src/compat_mac.h`, `src/compat_mac.c`).
  - Main-thread Cocoa/AppKit SDL3 event pump (`Thread 0`) paired with a 16 MiB background pthread running the PS4 `eboot.bin`.
  - macOS-safe SDL3 gamepad polling (`src/runtime_pad.c`) preserving main-thread `IOHIDManager` / `GCController` run-loop ownership.
- **Vulkan / KosmicKrisp GPU Layer (`CTR-NitroFueled-PC/gpu/`)**:
  - `CAMetalLayer`-backed SDL3 window creation (`gpu/shim/window.cpp`, `gpu/shim/bbgpu.cpp`).
  - Persistent `dlopen` Vulkan loader & automatic KosmicKrisp ICD discovery (`vk_platform.cpp`, `run.py`).
  - `VK_KHR_portability_enumeration` and `VK_KHR_portability_subset` support with dynamic buffer arena sizing for Metal buffer limits (`gpu/shadps4/video_core/buffer_cache/buffer_cache.cpp`).

## Contributors

- **Ace The Squirrel** ([@redtreerat](https://github.com/redtreerat))
- **Google Antigravity** — AI Pair Programmer & macOS Porting Engineer (Google DeepMind)
- **GetLostIn & SacredFire Contributors** — Upstream [CTR-NitroFueled-PC](https://github.com/GetLostIn/CTR-NitroFueled-PC) & [shadPS4](https://github.com/shadps4-emu/shadPS4)
