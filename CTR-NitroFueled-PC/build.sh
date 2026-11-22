#!/usr/bin/env bash
set -euo pipefail
cd -- "$(dirname -- "$0")"
mkdir -p out
# Windows: MSYS2 CLANG64 (packages in packaging/windows/README.md). The GPU library is static
# there and CMake links sacredfire.exe as well; no PGO (GCC-only flags), LTO off by default.
case $(uname -s) in
MINGW*|MSYS*)
    # shellcheck source=msys2-env.sh
    source ./msys2-env.sh
    for tool in clang cmake ninja pkg-config; do
        command -v "$tool" >/dev/null || { echo "Need $tool from MSYS2 CLANG64 (packaging/windows/README.md)." >&2; exit 1; }
    done
    if [[ ! -f gpu/third_party/fsr-vulkan/CMakeLists.txt || ! -f gpu/third_party/imgui/imgui.h ||
          ! -f gpu/third_party/xbyak/xbyak/xbyak.h ]]; then
        git submodule update --init --recursive
    fi
    for patch in gpu/patches/fsr-vulkan/*.patch; do
        if ! git -C gpu/third_party/fsr-vulkan apply --reverse --check "$PWD/$patch" 2>/dev/null; then
            git -C gpu/third_party/fsr-vulkan apply "$PWD/$patch"
        fi
    done
    cmake -S gpu -B out/gpu -G Ninja -DCMAKE_BUILD_TYPE=RelWithDebInfo -DBB_PGO=off \
        -DBB_LTO="${BB_LTO:-OFF}" -DCMAKE_C_COMPILER=clang -DCMAKE_CXX_COMPILER=clang++ >/dev/null
    echo "GPU library and loader: LTO ${BB_LTO:-OFF}"
    if ! ninja -C out/gpu sacredfire bb-gpu-capabilities ctr-launcher > out/gpu-build.log 2>&1; then
        grep -v '^\[' out/gpu-build.log | tail -40 >&2
        echo 'Build failed (full log: out/gpu-build.log)' >&2; exit 1
    fi
    cp out/gpu/sacredfire.exe out/gpu/bb-gpu-capabilities.exe out/gpu/CTR-NitroFueled-PC.exe out/
    version=$(git describe --tags --match 'v*' --always 2>/dev/null || echo unknown)
    printf '%s-windows\n' "$version" > out/VERSION
    echo "Built $PWD/out/sacredfire.exe ($(cat out/VERSION))"
    exit 0
    ;;
esac
export PATH="$PWD/out/deps/prefix/bin:/usr/local/bin:/opt/homebrew/bin:$PATH"
# SacredFire: header-only and local libraries in out/deps/prefix; use a space-free symlink on
# macOS so pkg-config and CMake's FindPkgConfig never split paths containing spaces.
if [[ $(uname -s) == Darwin ]]; then
    DEPS_NO_SPACE="/tmp/ctr-nf-mac-deps"
    ln -sfn "$PWD/out/deps/prefix" "$DEPS_NO_SPACE"
    export DEPS_PREFIX="$DEPS_NO_SPACE"
else
    DEPS_NO_SPACE="$PWD/out/deps/prefix"
fi
if [[ ! -f out/deps/prefix/include/vk_mem_alloc.h ]]; then bash tools/deps.sh; fi
if [[ $(uname -s) == Darwin && -d out/deps/prefix ]]; then
    # If header-only boost is installed in /opt/homebrew/opt/boost, symlink its boost/ headers and
    # cmake config into out/deps/prefix so we never need /opt/homebrew/include on the compiler path
    # (which would otherwise shadow out/deps/prefix/include/fmt with arm64 Homebrew's fmt).
    if [[ ! -e out/deps/prefix/include/boost && -d /opt/homebrew/opt/boost/include/boost ]]; then
        ln -sfn /opt/homebrew/opt/boost/include/boost out/deps/prefix/include/boost
    fi
    # Provide a dedicated -I directory containing only the bundled fmt headers so Apple Clang's
    # default /usr/local/include (which may have a newer Homebrew fmt v12) never shadows the
    # bundled fmt v11 static library, while newer /usr/local/include/vulkan headers still win.
    if [[ -d out/deps/prefix/include/fmt ]]; then
        mkdir -p out/deps/prefix/fmt-include
        ln -sfn "$DEPS_NO_SPACE/include/fmt" out/deps/prefix/fmt-include/fmt
    fi
    for pc in out/deps/prefix/lib/pkgconfig/*.pc out/deps/prefix/share/pkgconfig/*.pc; do
        [[ -f "$pc" ]] || continue
        sed -i '' -E "s|^prefix=.*|prefix=$DEPS_NO_SPACE|g; s|^exec_prefix=/.*|exec_prefix=\${prefix}|g; s|^includedir=/.*|includedir=$DEPS_NO_SPACE/include|g" "$pc"
    done
    # Only include x86_64 prefixes ($DEPS_NO_SPACE and /usr/local); exclude /opt/homebrew (arm64)
    # so headers like fmt from /opt/homebrew/include never shadow out/deps/prefix/include/fmt (v11).
    export PKG_CONFIG_PATH="$DEPS_NO_SPACE/lib/pkgconfig:$DEPS_NO_SPACE/share/pkgconfig:/usr/local/lib/pkgconfig:/usr/local/share/pkgconfig"
    export CMAKE_PREFIX_PATH="$DEPS_NO_SPACE:/usr/local"
else
    export CMAKE_PREFIX_PATH="$DEPS_NO_SPACE:/usr/local:/opt/homebrew${CMAKE_PREFIX_PATH:+:$CMAKE_PREFIX_PATH}"
fi
if [[ -z ${CC:-} ]]; then
    CC=$(command -v cc || command -v gcc || true)
    if [[ -z $CC ]]; then
        for candidate in /nix/store/*-gcc-wrapper-*/bin/gcc; do
            if [[ -x $candidate ]]; then CC=$candidate; break; fi
        done
    fi
fi
if [[ -z ${CC:-} ]]; then echo 'Install GCC/Clang or set CC.' >&2; exit 1; fi
# Dependencies come from pkg-config (Vulkan loader/headers, SDL3). On NixOS the
# environment is provided by shell.nix; re-enter it automatically if needed.
if ! { command -v pkg-config >/dev/null && pkg-config --exists vulkan sdl3 && command -v cmake >/dev/null && command -v ninja >/dev/null; }; then
    if [[ -z ${BB_IN_NIX_SHELL:-} ]] && command -v nix-shell >/dev/null; then
        exec env BB_IN_NIX_SHELL=1 nix-shell shell.nix --run "bash build.sh $*"
    fi
    echo 'Need pkg-config with vulkan and sdl3, cmake and ninja (see shell.nix).' >&2; exit 1
fi
read -r -a includes <<< "$(pkg-config --cflags vulkan sdl3)"
read -r -a libraries <<< "$(pkg-config --libs vulkan sdl3)"
# GPU library (shadPS4 video core + drivers), built by CMake into out/gpu/libbbgpu.so (or .dylib on macOS).\n# BB_PGO: generate (instrumented build that writes pgo/ while the game runs), use, off.
# Default: use the profile in pgo/ when there is one. BB_LTO=OFF disables link-time optimization.
pgo=${BB_PGO:-}
if [[ -z $pgo ]]; then
    if [[ -n $(find pgo -name '*.gcda' -print -quit 2>/dev/null) ]]; then pgo=use; else pgo=off; fi
fi
mkdir -p pgo
# Submodules (git clone --recursive, or: git submodule update --init) and this port's changes
# to FSR-Vulkan (gpu/patches/fsr-vulkan), applied to its working tree once.
if [[ ! -f gpu/third_party/fsr-vulkan/CMakeLists.txt || ! -f gpu/third_party/imgui/imgui.h ]]; then
    git submodule update --init --recursive 2>/dev/null || bash tools/setup_mac_deps.sh
fi
# Apply FSR-Vulkan patches only if not already applied (patch 0006 adds colorHudless to bridge.h).
find gpu/third_party/fsr-vulkan -name '*.rej' -o -name '*.orig' -delete 2>/dev/null || true
if ! grep -q "colorHudless" gpu/third_party/fsr-vulkan/include/ffx_vk_fsr3_3_1_5_bridge.h 2>/dev/null; then
    for patch_file in gpu/patches/fsr-vulkan/*.patch; do
        patch -d gpu/third_party/fsr-vulkan -p1 --batch --forward -s < "$PWD/$patch_file" || true
    done
fi
is_darwin=0
if [[ $(uname -s) == Darwin ]]; then
    is_darwin=1
    lto_default=OFF
    cmake_extra=(-DCMAKE_OSX_ARCHITECTURES=x86_64 -DCMAKE_IGNORE_PREFIX_PATH=/opt/homebrew -DCMAKE_FIND_NO_INSTALL_PREFIX=ON -DBoost_NO_BOOST_CMAKE=ON -DBoost_INCLUDE_DIR="$DEPS_NO_SPACE/include")
    # Remove stale CMakeCache.txt if the project folder was moved, still has split paths, or pulled /opt/homebrew
    if [[ -f out/gpu/CMakeCache.txt ]] && { ! grep -Fq "$PWD/gpu" out/gpu/CMakeCache.txt || grep -Fq "/Documents/Crash;" out/gpu/CMakeCache.txt || grep -Fq "/opt/homebrew/include" out/gpu/CMakeCache.txt; }; then
        rm -rf out/gpu
    fi
else
    lto_default=ON
    cmake_extra=()
fi
cmake -S gpu -B out/gpu -G Ninja -DCMAKE_BUILD_TYPE=RelWithDebInfo -DBB_PGO="$pgo" \
    -DBB_LTO="${BB_LTO:-$lto_default}" -DBB_PGO_DIR="$PWD/pgo" ${cmake_extra[@]+"${cmake_extra[@]}"} >/dev/null
echo "GPU library: PGO $pgo, LTO ${BB_LTO:-$lto_default}"
# A failed GPU build must stop here: an older libbbgpu.so would otherwise be used silently.
if ! ninja -C out/gpu bbgpu > out/gpu-build.log 2>&1; then
    grep -v '^\[' out/gpu-build.log | tail -40 >&2
    echo 'GPU library build failed (full log: out/gpu-build.log)' >&2; exit 1
fi
if (( is_darwin )); then
    cflags=(-arch x86_64 -D_XOPEN_SOURCE=700 -D_DARWIN_C_SOURCE=1 -Wno-unknown-warning-option -Wno-unused-but-set-global -Wno-format -Wno-unused-function)
    pie_flags=()
    gpu=(-Lout/gpu -lbbgpu -Wl,-rpath,@executable_path/gpu -Wl,-rpath,"$PWD/out/gpu" -Wl,-rpath,"$PWD/out/deps/prefix/lib" -Wl,-export_dynamic)
    runtime=(src/runtime*.c src/compat_mac.c)
else
    # $ORIGIN/gpu: packaged copies keep the library next to the binary without patching it.
    cflags=()
    pie_flags=(-no-pie)
    gpu=(-Lout/gpu -lbbgpu -Wl,-rpath,'$ORIGIN/gpu' -Wl,-rpath,"$PWD/out/gpu" -rdynamic)
    runtime=(src/runtime*.c)
fi
# isa_emulate runs inside guest code: no XMM/YMM.
"$CC" -std=c11 -O2 -g -Wall -Wextra -Werror ${cflags[@]+"${cflags[@]}"} -mgeneral-regs-only -c src/isa_emulate.c -o out/isa_emulate.o
# Third-party decoders: compiled once, without this project's -Werror policy.
atrac9=(third_party/LibAtrac9/C/src/*.c)
if [[ ! -f out/libatrac9.a || -n $(find third_party/LibAtrac9/C/src -newer out/libatrac9.a -name '*.c') ]]; then
    rm -rf out/atrac9 && mkdir -p out/atrac9
    for source in "${atrac9[@]}"; do "$CC" -std=c99 -O2 -g -w ${cflags[@]+"${cflags[@]}"} -c "$source" -o "out/atrac9/$(basename "${source%.c}").o"; done
    ar rcs out/libatrac9.a out/atrac9/*.o
fi
"$CC" -std=c11 -O2 -g -Wall -Wextra -Werror ${cflags[@]+"${cflags[@]}"} -pthread ${pie_flags[@]+"${pie_flags[@]}"} "${includes[@]}" -I. -Isrc src/probe.c "${runtime[@]}" src/cpu_check.c src/vulkan_smoke.c out/isa_emulate.o src/isa_rewrite.c out/libatrac9.a -lm "${gpu[@]}" "${libraries[@]}" -o out/sacredfire
echo "Built $PWD/out/sacredfire"
# out/VERSION: the source revision this build came from (the nearest v* tag, else the commit;
# "-dirty" when tracked files differ from it). run.sh prints it, the launcher shows it and the
# package carries it, so a published binary can be matched to its source. The FSR-Vulkan patch
# build.sh applies inside its submodule does not count as a change.
version=$(git describe --tags --match 'v*' --always 2>/dev/null || echo unknown)
git update-index -q --refresh 2>/dev/null || true
if ! git diff-index --quiet --ignore-submodules=dirty HEAD -- 2>/dev/null; then version="$version-dirty"; fi
if (( is_darwin )); then version="$version-macos"; fi
printf '%s\n' "$version" > out/VERSION
echo "Version: $version (out/VERSION)"
# GPU check for run.sh (live_resolution=auto) and the launcher's gamepad list (--gamepads).
"$CC" -std=c11 -O2 -Wall -Wextra -Werror ${cflags[@]+"${cflags[@]}"} "${includes[@]}" tools/gpu_capabilities.c "${libraries[@]}" -o out/bb-gpu-capabilities
if [[ ${1:-} == --test ]]; then
    "$CC" -std=c11 -O2 -g -Wall -Wextra -Werror ${cflags[@]+"${cflags[@]}"} -pthread "${includes[@]}" -I. -Isrc tests/test_pad.c "${libraries[@]}" -o out/pad-test
    out/pad-test
    "$CC" -std=c11 -O2 -g -Wall -Wextra -Werror ${cflags[@]+"${cflags[@]}"} -pthread -I. -Isrc tests/test_runtime.c "${runtime[@]}" out/libatrac9.a -lm "${gpu[@]}" "${libraries[@]}" -o out/runtime-test
    out/runtime-test
    "$CC" -std=c11 -O2 -g -Wall -Wextra -Werror ${cflags[@]+"${cflags[@]}"} -pthread -Isrc tests/test_file_mods.c -o out/file-mods-test
    out/file-mods-test
    "$CC" -std=c11 -O2 -g -Wall -Wextra -Werror ${cflags[@]+"${cflags[@]}"} -pthread -I. -Isrc tests/test_sema.c "${runtime[@]}" out/libatrac9.a -lm "${gpu[@]}" "${libraries[@]}" -o out/sema-test
    out/sema-test
    "$CC" -std=c11 -D_GNU_SOURCE -O2 -g -Wall -Wextra -Werror ${cflags[@]+"${cflags[@]}"} -I. -Isrc tests/test_content.c src/runtime_content.c -o out/content-test
    out/content-test
    "$CC" -std=c11 -O2 -g -Wall -Wextra -Werror ${cflags[@]+"${cflags[@]}"} -I. -Isrc tests/test_patches.c src/runtime_patches.c -o out/patches-test
    out/patches-test
    "$CC" -std=c11 -O2 -g -Wall -Wextra -Werror ${cflags[@]+"${cflags[@]}"} -I. -Isrc tests/test_isa_rewrite.c out/isa_emulate.o src/isa_rewrite.c -o out/isa-rewrite-test
    out/isa-rewrite-test
    python3 tests/test_isa_rewrite.py
    python3 tests/test_ultrawide.py
    ninja -C out/gpu motion-history-test motion-shader-test ui-composition-test scene-resolution-test taa-shader-test camera-motion-test settings-test
    out/gpu/motion-history-test
    out/gpu/motion-shader-test
    out/gpu/ui-composition-test
    out/gpu/scene-resolution-test
    out/gpu/taa-shader-test
    out/gpu/camera-motion-test
    out/gpu/settings-test
fi
