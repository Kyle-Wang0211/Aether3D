#!/usr/bin/env bash
#
# Build aether3d_c (with the Phase 4 GLB normalizer C ABI) for Android.
#
# Output: dist/libs/android-${ABI}/libaether3d_c.a — one per ABI.
# ABIs:   arm64-v8a (modern devices), armeabi-v7a (legacy), x86_64 (emulators).
#
# Dependencies:
#   ANDROID_NDK    Path to the installed Android NDK (e.g. ~/Library/Android/sdk/ndk/27.0.x).
#                  The toolchain file lives at ${ANDROID_NDK}/build/cmake/android.toolchain.cmake.
#                  android-21 is the minimum API targeted (matches Polycam/KIRI).
#
# Verification: the script walks the produced archives with the NDK's bundled
# llvm-nm and fails loudly if any of the four aether_glb_norm_* C ABI symbols
# is missing. dart:ffi calls these by name at runtime, so a silently-stripped
# archive would dlsym-fail at startup with no link-time signal.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

if [[ -z "${ANDROID_NDK:-}" ]]; then
    echo "ERROR: ANDROID_NDK is not set." >&2
    echo "  Install via Android Studio (Tools → SDK Manager → NDK) or 'sdkmanager \"ndk;27.0.x\"'." >&2
    echo "  Then export ANDROID_NDK=~/Library/Android/sdk/ndk/<version>" >&2
    exit 1
fi

if [[ ! -f "${ANDROID_NDK}/build/cmake/android.toolchain.cmake" ]]; then
    echo "ERROR: NDK toolchain file not found: ${ANDROID_NDK}/build/cmake/android.toolchain.cmake" >&2
    exit 1
fi

# Detect host platform for the bundled llvm-nm path. The NDK ships
# linux-x86_64 / darwin-x86_64 / windows-x86_64 prebuilts; pick whichever
# subdir actually exists rather than hard-coding darwin-x86_64.
LLVM_NM=""
for host in darwin-x86_64 linux-x86_64 darwin-arm64 linux-arm64; do
    if [[ -x "${ANDROID_NDK}/toolchains/llvm/prebuilt/${host}/bin/llvm-nm" ]]; then
        LLVM_NM="${ANDROID_NDK}/toolchains/llvm/prebuilt/${host}/bin/llvm-nm"
        break
    fi
done
if [[ -z "$LLVM_NM" ]]; then
    echo "WARN: NDK llvm-nm not found; falling back to system nm (may not parse arm64 archives)" >&2
    LLVM_NM="nm"
fi

# Phase 4 surface — must be in every shipped archive. dart:ffi resolves
# these via dlsym at runtime; an archive missing one of them will fail
# AetherGlbNorm.run() with a "symbol not found" runtime error rather
# than a static-link error, so verify here.
REQUIRED_SYMBOLS=(
    aether_glb_norm_run
    aether_glb_norm_options_default
    aether_glb_norm_buffer_free
    aether_glb_norm_result_str
)

DIST_DIR="dist/libs"
mkdir -p "$DIST_DIR"

declare -a ABI_LIST=(arm64-v8a armeabi-v7a x86_64)

for ABI in "${ABI_LIST[@]}"; do
    BUILD_DIR="aether_cpp/build-android-${ABI}"
    OUT_DIR="${DIST_DIR}/android-${ABI}"

    echo "==> [${ABI}] Configuring (NDK=${ANDROID_NDK}, API=21, Dawn=OFF)..."
    rm -rf "$BUILD_DIR"
    # AETHER_FFI_BUILD_STATIC=ON triggers the Phase 4 conditional in
    # aether_cpp/CMakeLists.txt that pulls atlas_merger.cpp / glb_io.cpp /
    # mesh_simplify.cpp directly into libaether3d_ffi.a + links
    # meshoptimizer in. The result is a self-contained ~600 KB-1 MB
    # archive with the four C ABI symbols, instead of the 18 MB
    # everything-in-core merge we'd get from `--target aether3d_c`.
    cmake -S aether_cpp -B "$BUILD_DIR" \
        -DCMAKE_TOOLCHAIN_FILE="${ANDROID_NDK}/build/cmake/android.toolchain.cmake" \
        -DANDROID_ABI="${ABI}" \
        -DANDROID_PLATFORM=android-21 \
        -DAETHER_ENABLE_DAWN=OFF \
        -DAETHER_FFI_BUILD_STATIC=ON \
        -DCMAKE_BUILD_TYPE=Release

    echo "==> [${ABI}] Building aether3d_ffi (Phase 4 ship target)..."
    cmake --build "$BUILD_DIR" --target aether3d_ffi -j 8

    SRC_LIB="${BUILD_DIR}/libaether3d_ffi.a"
    if [[ ! -f "$SRC_LIB" ]]; then
        echo "ERROR: [${ABI}] expected ${SRC_LIB} not produced." >&2
        exit 1
    fi

    mkdir -p "$OUT_DIR"

    # The FFI static archive is already self-contained for the glb_norm
    # symbols (CMakeLists' AETHER_FFI_BUILD_STATIC branch pulls in the
    # implementation TUs + meshoptimizer). We ship it under the
    # historical name `libaether3d_c.a` for consistency with the prompt's
    # expected dist layout — Gradle/CMake consumers care about the C ABI,
    # not which CMake target produced the archive.
    cp "$SRC_LIB" "${OUT_DIR}/libaether3d_c.a"

    echo "==> [${ABI}] Verifying GLB normalizer symbols via ${LLVM_NM}..."
    # ELF naming convention: no leading underscore (unlike Mach-O).
    # Capture nm output once and grep against it. We can't pipe nm directly
    # into `grep -q` here because grep -q early-terminates → nm gets SIGPIPE
    # → pipefail returns 141 → the `! pipeline` flips to "missing" even
    # when the symbol is present.
    NM_OUT="$("$LLVM_NM" "${OUT_DIR}/libaether3d_c.a" 2>/dev/null)"
    for sym in "${REQUIRED_SYMBOLS[@]}"; do
        if ! grep -q "T ${sym}\b" <<<"$NM_OUT"; then
            echo "ERROR: [${ABI}] ${sym} missing from libaether3d_c.a" >&2
            exit 1
        fi
    done
    SIZE_BYTES=$(stat -f%z "${OUT_DIR}/libaether3d_c.a" 2>/dev/null \
                  || stat -c%s "${OUT_DIR}/libaether3d_c.a")
    echo "==> [${ABI}] OK — ${OUT_DIR}/libaether3d_c.a (${SIZE_BYTES} bytes)"
done

echo
echo "==> Android build complete. Per-ABI artifacts:"
ls -la "${DIST_DIR}"/android-*/libaether3d_c.a
