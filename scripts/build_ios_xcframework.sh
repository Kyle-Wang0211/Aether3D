#!/usr/bin/env bash
#
# Build the aether3d_ffi xcframework for iOS (arm64 device + arm64 simulator).
#
# Output: dist/aether3d_ffi.xcframework
#
# Phase 3 scope: deliberately ships only aether3d_ffi (version.cpp only). The
# heavier aether3d_core target is NOT included on iOS yet — it pulls in
# metal_gpu_device.mm + depth_inference_coreml.mm which fail on iOS toolchain
# (CoreML / Metal API differences). Re-enabling those for iOS is a Phase 4
# task, see PHASE_BACKLOG.md "iOS aether3d_core" entry.
#
# Dawn is also disabled (AETHER_ENABLE_DAWN=OFF). Dawn-on-iOS is its own
# can of worms, deferred per PHASE_BACKLOG.md.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

DEVICE_BUILD="aether_cpp/build-ios-device"
SIM_BUILD="aether_cpp/build-ios-sim"
DIST_DIR="dist"

# ─── Common CMake args ─────────────────────────────────────────────────
COMMON_ARGS=(
    -G Xcode
    -DCMAKE_SYSTEM_NAME=iOS
    -DCMAKE_OSX_ARCHITECTURES=arm64
    -DCMAKE_OSX_DEPLOYMENT_TARGET=14.0
    -DAETHER_ENABLE_DAWN=OFF
    -DAETHER_FFI_BUILD_STATIC=ON
)

echo "==> Configuring iOS device build..."
rm -rf "$DEVICE_BUILD"
cmake -S aether_cpp -B "$DEVICE_BUILD" "${COMMON_ARGS[@]}"

echo "==> Configuring iOS simulator build..."
rm -rf "$SIM_BUILD"
cmake -S aether_cpp -B "$SIM_BUILD" "${COMMON_ARGS[@]}" \
    -DCMAKE_OSX_SYSROOT=iphonesimulator

echo "==> Building aether3d_ffi for iOS device (arm64)..."
cmake --build "$DEVICE_BUILD" --config Debug --target aether3d_ffi

echo "==> Building aether3d_ffi for iOS simulator (arm64)..."
cmake --build "$SIM_BUILD" --config Debug --target aether3d_ffi

DEVICE_LIB="$DEVICE_BUILD/Debug-iphoneos/libaether3d_ffi.a"
SIM_LIB="$SIM_BUILD/Debug-iphonesimulator/libaether3d_ffi.a"

[ -f "$DEVICE_LIB" ] || { echo "ERROR: device lib missing: $DEVICE_LIB" >&2; exit 1; }
[ -f "$SIM_LIB" ] || { echo "ERROR: sim lib missing: $SIM_LIB" >&2; exit 1; }

# Verify each was built for the right arch + platform
echo "==> Device lib:"
lipo -info "$DEVICE_LIB"
echo "==> Sim lib:"
lipo -info "$SIM_LIB"

# ─── Combine into xcframework ──────────────────────────────────────────
echo "==> Creating xcframework..."
mkdir -p "$DIST_DIR"
rm -rf "$DIST_DIR/aether3d_ffi.xcframework"
xcodebuild -create-xcframework \
    -library "$DEVICE_LIB" -headers aether_cpp/include \
    -library "$SIM_LIB" -headers aether_cpp/include \
    -output "$DIST_DIR/aether3d_ffi.xcframework"

echo "==> xcframework done. Output: $DIST_DIR/aether3d_ffi.xcframework"
ls -la "$DIST_DIR/aether3d_ffi.xcframework/"

# ─── Phase 5.0 (D2): per-arch .a extraction for vendored_libraries ──────
# Phase 3.5 deferred: CocoaPods 1.16 + use_frameworks! + vendored static
# xcframework didn't generate the slice-extraction script_phase, so the
# .a never made it into the Runner link line. Phase 5.0 sidesteps the
# xcframework wrapper entirely — podspec consumes per-arch .a files
# directly via s.preserve_paths + LIBRARY_SEARCH_PATHS[sdk=…] xcconfig.
echo "==> Extracting per-arch .a for podspec vendored_libraries (Phase 5.0)..."
LIBS_DIR="$DIST_DIR/libs"
rm -rf "$LIBS_DIR"
mkdir -p "$LIBS_DIR/ios-arm64"
mkdir -p "$LIBS_DIR/ios-arm64-simulator"
cp "$DIST_DIR/aether3d_ffi.xcframework/ios-arm64/libaether3d_ffi.a" \
   "$LIBS_DIR/ios-arm64/libaether3d_ffi.a"
cp "$DIST_DIR/aether3d_ffi.xcframework/ios-arm64-simulator/libaether3d_ffi.a" \
   "$LIBS_DIR/ios-arm64-simulator/libaether3d_ffi.a"

# Sanity: verify both libs carry the FFI symbol — without this, 5.4's
# AetherFfi.versionString() will dlsym-fail at runtime with no link error.
echo "==> Verifying _aether_version_string symbol in extracted slices..."
for slice in ios-arm64 ios-arm64-simulator; do
    if ! nm "$LIBS_DIR/$slice/libaether3d_ffi.a" 2>/dev/null \
        | grep -q "T _aether_version_string"; then
        echo "ERROR: _aether_version_string missing from $slice slice" >&2
        exit 1
    fi
done

echo "==> Per-arch libs ready:"
ls -la "$LIBS_DIR/ios-arm64/"
ls -la "$LIBS_DIR/ios-arm64-simulator/"
