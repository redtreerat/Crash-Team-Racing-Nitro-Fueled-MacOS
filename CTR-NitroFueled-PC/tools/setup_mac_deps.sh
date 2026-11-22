#!/usr/bin/env bash
# Bootstraps all macOS x86_64 (Rosetta 2) dependencies and header libraries required to compile
# and run CTR-NitroFueled-PC (sacredfire + libbbgpu.dylib) with Mesa KosmicKrisp / MoltenVK.
set -euo pipefail
cd -- "$(dirname -- "$0")/.."

echo "=== CTR Nitro-Fueled macOS x86_64 Dependency Bootstrapper ==="

# 1. Verify Rosetta 2 on Apple Silicon
if [[ $(uname -m) == arm64 ]] || [[ $(sysctl -n hw.optional.arm64 2>/dev/null || echo 0) == 1 ]]; then
    if ! /usr/bin/arch -x86_64 /usr/bin/true 2>/dev/null; then
        echo "Installing Rosetta 2..."
        softwareupdate --install-rosetta --agree-to-license
    else
        echo "[OK] Rosetta 2 is installed."
    fi
fi

# 2. Locate x86_64 Homebrew (/usr/local/bin/brew) or fallback to /opt/homebrew/bin/brew
X86_BREW="/usr/local/bin/brew"
ARM_BREW="/opt/homebrew/bin/brew"

if [[ -x "$X86_BREW" ]]; then
    echo "[OK] Found x86_64 Homebrew at $X86_BREW"
    BREW_CMD=(/usr/bin/arch -x86_64 "$X86_BREW")
    BREW_PREFIX="/usr/local"
elif [[ -x "$ARM_BREW" ]]; then
    echo "[WARN] x86_64 Homebrew (/usr/local/bin/brew) not found."
    echo "       For linking x86_64 libraries (SDL3, FFmpeg, fmt, zydis, xxhash, boost, vulkan-loader),"
    echo "       an x86_64 Homebrew installation in /usr/local is recommended."
    echo "       To install x86_64 Homebrew in Terminal, run:"
    echo '         arch -x86_64 /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"'
    BREW_CMD=("$ARM_BREW")
    BREW_PREFIX="/opt/homebrew"
else
    echo "[WARN] Homebrew not found in /usr/local or /opt/homebrew."
    echo "       To install x86_64 Homebrew in Terminal, run:"
    echo '         arch -x86_64 /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"'
    BREW_CMD=()
    BREW_PREFIX=""
fi

# 3. Install required Homebrew formulae if Homebrew is available
if (( ${#BREW_CMD[@]} )); then
    FORMULAE=(
        cmake
        ninja
        pkg-config
        python@3.12
        vulkan-headers
        vulkan-loader
        molten-vk
        glslang
        sdl3
        ffmpeg
        fmt
        boost
        xxhash
        zydis
        robin-map
    )
    echo "Checking/installing Homebrew packages via ${BREW_CMD[*]}..."
    "${BREW_CMD[@]}" install "${FORMULAE[@]}" || echo "[WARN] Some Homebrew formulae reported warnings; continuing..."
fi

# 4. Initialize git submodules (fsr-vulkan, imgui, LibAtrac9, magic_enum, miniz, xbyak)
if [[ -f .gitmodules ]]; then
    echo "Checking third-party sources..."
    fetch_subrepo() {
        local path=$1 url=$2 branch=${3:-}
        if [[ ! -d "$path" ]] || [[ -z $(ls -A "$path" 2>/dev/null) ]]; then
            echo "Cloning $path from $url..."
            rm -rf "$path"
            if [[ -n "$branch" ]]; then
                git clone --depth 1 --branch "$branch" "$url" "$path"
            else
                git clone --depth 1 "$url" "$path"
            fi
        else
            echo "[OK] $path present."
        fi
    }
    fetch_subrepo gpu/third_party/fsr-vulkan https://github.com/FireBurn/FSR-Vulkan.git
    fetch_subrepo gpu/third_party/imgui https://github.com/ocornut/imgui.git
    fetch_subrepo third_party/LibAtrac9 https://github.com/Thealexbarney/LibAtrac9.git
    fetch_subrepo gpu/third_party/magic_enum https://github.com/Neargye/magic_enum.git
    fetch_subrepo gpu/third_party/miniz https://github.com/richgel999/miniz.git
    fetch_subrepo gpu/third_party/xbyak https://github.com/herumi/xbyak.git
fi

# 5. Fetch & install header-only CMake dependencies (magic_enum, VulkanMemoryAllocator, xbyak)
echo "Running tools/deps.sh..."
export PATH="/usr/local/bin:/opt/homebrew/bin:$PATH"
bash tools/deps.sh

# 6. Check for Vulkan ICDs (KosmicKrisp / MoltenVK)
echo "Checking Vulkan ICD manifests..."
ICD_FOUND=0
for dir in "$PWD/bin" "$PWD/out/icd" /usr/local/share/vulkan/icd.d /opt/homebrew/share/vulkan/icd.d /Library/Vulkan/icd.d "$HOME/.local/share/vulkan/icd.d"; do
    if [[ -d "$dir" ]]; then
        for icd in "$dir"/*.json; do
            if [[ -f "$icd" ]]; then
                echo "[OK] Found Vulkan ICD: $icd"
                ICD_FOUND=1
            fi
        done
    fi
done

if (( ! ICD_FOUND )); then
    echo "[INFO] No Vulkan ICD manifest detected yet. Install molten-vk via Homebrew or place your KosmicKrisp ICD JSON in /usr/local/share/vulkan/icd.d/."
fi

echo "=== Bootstrap Complete! You can now click 'Build sacredfire (x86_64)' ==="
