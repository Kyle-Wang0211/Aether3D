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

echo "==> Done. Output: $DIST_DIR/aether3d_ffi.xcframework"
ls -la "$DIST_DIR/aether3d_ffi.xcframework/"
