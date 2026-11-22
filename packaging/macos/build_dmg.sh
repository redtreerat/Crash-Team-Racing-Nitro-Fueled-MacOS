#!/usr/bin/env bash
# Builds a self-contained macOS Release .app (bundling the prebuilt x86_64 sacredfire engine,
# libbbgpu.dylib, Mesa KosmicKrisp Vulkan 1.4 driver, and all transitive x86_64 dylibs) and
# packages it into a compressed drag-and-drop macOS .dmg installer.
set -euo pipefail

ROOT_DIR="$(cd -- "$(dirname -- "$0")/../.." && pwd)"
ENGINE_DIR="$ROOT_DIR/CTR-NitroFueled-PC"
DIST_DIR="$ROOT_DIR/dist"
BUILD_DIR="$DIST_DIR/xcodebuild"
STAGE_DIR="$DIST_DIR/dmg-stage"
APP_NAME="Crash Team Racing Nitro-Fueled.app"
DMG_NAME="Crash-Team-Racing-Nitro-Fueled-macOS.dmg"
VOLUME_NAME="Crash Team Racing Nitro-Fueled"
ICON_ICNS="$ROOT_DIR/Crash Team Racing Nitro Fueled MacOS/AppIcon.icns"

echo "=== 1. Verifying prebuilt engine binaries & KosmicKrisp ==="
for req in \
    "$ENGINE_DIR/out/sacredfire" \
    "$ENGINE_DIR/out/bb-gpu-capabilities" \
    "$ENGINE_DIR/out/gpu/libbbgpu.dylib" \
    "$ENGINE_DIR/out/icd/libvulkan_kosmickrisp.dylib" \
    "$ENGINE_DIR/out/icd/kosmickrisp_mesa_icd.json" \
    "$ICON_ICNS"; do
    if [[ ! -f "$req" ]]; then
        echo "Missing required file: $req" >&2
        echo "Build the engine first with CTR-NitroFueled-PC/build.sh and tools/setup_mac_deps.sh." >&2
        exit 1
    fi
done

echo "=== 2. Building Release SwiftUI Launcher (.app) ==="
rm -rf "$STAGE_DIR" "$DIST_DIR/$DMG_NAME" "$DIST_DIR/temp.dmg"
mkdir -p "$DIST_DIR" "$STAGE_DIR"

xcodebuild \
    -project "$ROOT_DIR/Crash Team Racing Nitro Fueled MacOS.xcodeproj" \
    -scheme "Crash Team Racing Nitro Fueled MacOS" \
    -configuration Release \
    -derivedDataPath "$BUILD_DIR" \
    -arch arm64 \
    CODE_SIGN_IDENTITY="-" \
    CODE_SIGNING_REQUIRED=NO \
    CODE_SIGNING_ALLOWED=YES \
    build | tail -n 25

BUILT_APP="$BUILD_DIR/Build/Products/Release/Crash Team Racing Nitro Fueled MacOS.app"
if [[ ! -d "$BUILT_APP" ]]; then
    echo "Release .app not found at $BUILT_APP" >&2
    exit 1
fi

TARGET_APP="$STAGE_DIR/$APP_NAME"
cp -R "$BUILT_APP" "$TARGET_APP"

# Ensure AppIcon.icns is in Resources and CFBundleIconFile is set
cp -f "$ICON_ICNS" "$TARGET_APP/Contents/Resources/AppIcon.icns"
/usr/libexec/PlistBuddy -c "Delete :CFBundleIconFile" "$TARGET_APP/Contents/Info.plist" 2>/dev/null || true
/usr/libexec/PlistBuddy -c "Add :CFBundleIconFile string AppIcon" "$TARGET_APP/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Delete :CFBundleDisplayName" "$TARGET_APP/Contents/Info.plist" 2>/dev/null || true
/usr/libexec/PlistBuddy -c "Add :CFBundleDisplayName string CTR Nitro-Fueled" "$TARGET_APP/Contents/Info.plist"

echo "=== 3. Bundling CTR-NitroFueled-PC engine & KosmicKrisp into .app ==="
BUNDLE_ENGINE="$TARGET_APP/Contents/Resources/CTR-NitroFueled-PC"
mkdir -p "$BUNDLE_ENGINE/out/gpu" "$BUNDLE_ENGINE/out/icd" "$BUNDLE_ENGINE/out/lib"

cp -f "$ENGINE_DIR/run.py" "$BUNDLE_ENGINE/"
cp -f "$ENGINE_DIR/LICENSE" "$BUNDLE_ENGINE/"
[[ -f "$ENGINE_DIR/out/VERSION" ]] && cp -f "$ENGINE_DIR/out/VERSION" "$BUNDLE_ENGINE/out/"
[[ -f "$ENGINE_DIR/bbport.default.ini" ]] && cp -f "$ENGINE_DIR/bbport.default.ini" "$BUNDLE_ENGINE/"

cp -R "$ENGINE_DIR/patches" "$BUNDLE_ENGINE/"
rsync -a --exclude '__pycache__' --exclude '*.pyc' "$ENGINE_DIR/scripts/" "$BUNDLE_ENGINE/scripts/"
mkdir -p "$BUNDLE_ENGINE/tools"
for t in gen_import_names.py merge_update.py igz_merge.py setup_mac_deps.sh; do
    [[ -f "$ENGINE_DIR/tools/$t" ]] && cp -f "$ENGINE_DIR/tools/$t" "$BUNDLE_ENGINE/tools/"
done

cp -f "$ENGINE_DIR/out/sacredfire" "$BUNDLE_ENGINE/out/sacredfire"
cp -f "$ENGINE_DIR/out/bb-gpu-capabilities" "$BUNDLE_ENGINE/out/bb-gpu-capabilities"
cp -f "$ENGINE_DIR/out/gpu/libbbgpu.dylib" "$BUNDLE_ENGINE/out/gpu/libbbgpu.dylib"
cp -f "$ENGINE_DIR/out/icd/libvulkan_kosmickrisp.dylib" "$BUNDLE_ENGINE/out/icd/libvulkan_kosmickrisp.dylib"
cp -f "$ENGINE_DIR/out/icd/kosmickrisp_mesa_icd.json" "$BUNDLE_ENGINE/out/icd/kosmickrisp_mesa_icd.json"

chmod 755 \
    "$BUNDLE_ENGINE/out/sacredfire" \
    "$BUNDLE_ENGINE/out/bb-gpu-capabilities" \
    "$BUNDLE_ENGINE/out/gpu/libbbgpu.dylib" \
    "$BUNDLE_ENGINE/out/icd/libvulkan_kosmickrisp.dylib"

echo "=== 4. Collecting & relocating all non-system x86_64 dylibs ==="
python3 - "$ENGINE_DIR" "$BUNDLE_ENGINE" <<'PYEOF'
import os
import shutil
import subprocess
import sys

engine_dir = sys.argv[1]
bundle_engine = sys.argv[2]
lib_dir = os.path.join(bundle_engine, "out", "lib")

roots = [
    os.path.join(bundle_engine, "out", "sacredfire"),
    os.path.join(bundle_engine, "out", "bb-gpu-capabilities"),
    os.path.join(bundle_engine, "out", "gpu", "libbbgpu.dylib"),
]

search_dirs = [
    os.path.join(engine_dir, "out", "deps", "prefix", "lib"),
    "/tmp/ctr-nf-mac-deps/lib",
    "/usr/local/lib",
]

def otool_deps(path):
    out = subprocess.check_output(["otool", "-L", path], text=True)
    deps = []
    for line in out.splitlines()[1:]:
        dep = line.strip().split(" (")[0]
        if dep:
            deps.append(dep)
    return deps

def otool_rpaths(path):
    out = subprocess.check_output(["otool", "-l", path], text=True)
    rpaths = []
    lines = out.splitlines()
    for i, line in enumerate(lines):
        if "cmd LC_RPATH" in line:
            for j in range(i + 1, min(i + 6, len(lines))):
                s = lines[j].strip()
                if s.startswith("path "):
                    rpaths.append(s[5:].split(" (offset")[0])
                    break
    return rpaths

def is_system(dep):
    return dep.startswith("/System/") or dep.startswith("/usr/lib/")

def resolve_dep(dep, parent_real_path):
    if dep.startswith("@"):
        base = os.path.basename(dep)
        if base == "libbbgpu.dylib":
            return None
        candidates = [os.path.dirname(parent_real_path)] + search_dirs
        for d in candidates:
            cand = os.path.join(d, base)
            if os.path.exists(cand):
                return os.path.realpath(cand)
        raise RuntimeError(f"Could not resolve {dep} needed by {parent_real_path}")
    if os.path.exists(dep):
        return os.path.realpath(dep)
    raise RuntimeError(f"Missing dylib {dep} needed by {parent_real_path}")

# Recursively copy all non-system dylibs into out/lib/
copied = {}  # basename -> source realpath
queue = [(r, r) for r in roots]

while queue:
    macho_path, orig_real_path = queue.pop(0)
    for dep in otool_deps(macho_path):
        if is_system(dep):
            continue
        base = os.path.basename(dep)
        if base == os.path.basename(macho_path) or base == "libbbgpu.dylib":
            continue
        resolved = resolve_dep(dep, orig_real_path)
        if not resolved:
            continue
        if base not in copied:
            dst = os.path.join(lib_dir, base)
            shutil.copy2(resolved, dst)
            os.chmod(dst, 0o755)
            copied[base] = resolved
            queue.append((dst, resolved))

print(f"Bundled {len(copied)} x86_64 dylibs into out/lib/")

def rewrite_rpaths(path, new_rpaths):
    for rp in otool_rpaths(path):
        subprocess.run(["install_name_tool", "-delete_rpath", rp, path], check=False)
    for rp in new_rpaths:
        subprocess.check_call(["install_name_tool", "-add_rpath", rp, path])

# Rewrite each bundled dylib in out/lib/
for base in sorted(copied):
    dst = os.path.join(lib_dir, base)
    subprocess.check_call(["install_name_tool", "-id", f"@rpath/{base}", dst])
    rewrite_rpaths(dst, ["@loader_path"])
    for dep in otool_deps(dst):
        if is_system(dep):
            continue
        dep_base = os.path.basename(dep)
        if dep_base == base:
            continue
        if dep_base in copied:
            subprocess.check_call(["install_name_tool", "-change", dep, f"@loader_path/{dep_base}", dst])

# Rewrite libbbgpu.dylib
bbgpu = os.path.join(bundle_engine, "out", "gpu", "libbbgpu.dylib")
subprocess.check_call(["install_name_tool", "-id", "@rpath/libbbgpu.dylib", bbgpu])
rewrite_rpaths(bbgpu, ["@loader_path/../lib", "@loader_path"])
for dep in otool_deps(bbgpu):
    if is_system(dep):
        continue
    dep_base = os.path.basename(dep)
    if dep_base == "libbbgpu.dylib":
        continue
    if dep_base in copied:
        subprocess.check_call(["install_name_tool", "-change", dep, f"@rpath/{dep_base}", bbgpu])

# Rewrite sacredfire and bb-gpu-capabilities
for exe in (
    os.path.join(bundle_engine, "out", "sacredfire"),
    os.path.join(bundle_engine, "out", "bb-gpu-capabilities"),
):
    rewrite_rpaths(exe, ["@executable_path/gpu", "@executable_path/lib"])
    for dep in otool_deps(exe):
        if is_system(dep):
            continue
        dep_base = os.path.basename(dep)
        if dep_base == "libbbgpu.dylib":
            subprocess.check_call(["install_name_tool", "-change", dep, "@rpath/libbbgpu.dylib", exe])
        elif dep_base in copied:
            subprocess.check_call(["install_name_tool", "-change", dep, f"@rpath/{dep_base}", exe])

# Strict audit: verify zero external /usr/local, /opt/homebrew, or /tmp paths remain
bad = []
all_machos = roots + [os.path.join(lib_dir, b) for b in copied] + [
    os.path.join(bundle_engine, "out", "icd", "libvulkan_kosmickrisp.dylib")
]
for m in all_machos:
    for dep in otool_deps(m):
        if dep.startswith(("/usr/local/", "/opt/homebrew/", "/tmp/")):
            bad.append((m, dep))
    for rp in otool_rpaths(m):
        if rp.startswith(("/usr/local/", "/opt/homebrew/", "/tmp/", "/Users/")):
            bad.append((m, f"RPATH:{rp}"))

if bad:
    for m, dep in bad:
        print(f"ERROR: External reference remains in {m}: {dep}", file=sys.stderr)
    sys.exit(1)

print("Relocation audit PASSED: 0 external dylib or rpath references remain.")
PYEOF

echo "=== 5. Ad-hoc signing bundled binaries and .app ==="
for dylib in "$BUNDLE_ENGINE"/out/lib/*.dylib "$BUNDLE_ENGINE/out/gpu/libbbgpu.dylib" "$BUNDLE_ENGINE/out/icd/libvulkan_kosmickrisp.dylib"; do
    codesign --force --sign - --timestamp=none "$dylib"
done
codesign --force --sign - --timestamp=none "$BUNDLE_ENGINE/out/bb-gpu-capabilities"
codesign --force --sign - --timestamp=none "$BUNDLE_ENGINE/out/sacredfire"
codesign --force --sign - --timestamp=none "$TARGET_APP"
codesign --verify --verbose=2 "$TARGET_APP"

echo "=== 6. Smoke-testing bundled self-contained binaries ==="
/usr/bin/arch -x86_64 "$BUNDLE_ENGINE/out/sacredfire" --vulkan-only
/usr/bin/arch -x86_64 "$BUNDLE_ENGINE/out/bb-gpu-capabilities"

echo "=== 7. Creating compressed macOS .dmg with custom CTR icon ==="
ln -sfn /Applications "$STAGE_DIR/Applications"
cp -f "$ICON_ICNS" "$STAGE_DIR/.VolumeIcon.icns"

# Create writable DMG first so we can flag custom volume icon and layout cleanly
hdiutil create \
    -srcfolder "$STAGE_DIR" \
    -volname "$VOLUME_NAME" \
    -fs HFS+ \
    -fsargs "-c c=64,a=16,e=16" \
    -format UDRW \
    -ov \
    "$DIST_DIR/temp.dmg" >/dev/null

MOUNT_POINT="/Volumes/$VOLUME_NAME"
# Detach if a stale mount exists
hdiutil detach "$MOUNT_POINT" -force >/dev/null 2>&1 || true

MOUNT_OUT="$(hdiutil attach -readwrite -noverify -noautoopen "$DIST_DIR/temp.dmg")"
MOUNT_DIR="$(echo "$MOUNT_OUT" | awk -F'\t' '/\/Volumes\// {print $NF; exit}')"

if [[ -n "$MOUNT_DIR" && -d "$MOUNT_DIR" ]]; then
    if command -v SetFile >/dev/null 2>&1; then
        SetFile -a C "$MOUNT_DIR" || true
        SetFile -a V "$MOUNT_DIR/.VolumeIcon.icns" || true
    fi
    sync
    hdiutil detach "$MOUNT_DIR" -force >/dev/null
fi

hdiutil convert "$DIST_DIR/temp.dmg" \
    -format UDZO \
    -imagekey zlib-level=9 \
    -ov \
    -o "$DIST_DIR/$DMG_NAME" >/dev/null

rm -f "$DIST_DIR/temp.dmg"

echo "=== Done! ==="
ls -lh "$DIST_DIR/$DMG_NAME"
