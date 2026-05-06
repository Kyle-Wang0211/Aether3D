#!/usr/bin/env bash
#
# Build aether3d_c (with the Phase 4 GLB normalizer C ABI) for OpenHarmony
# (HarmonyOS native ABI). HarmonyOS NEXT and HarmonyOS 4.x both consume the
# same OpenHarmony NDK toolchain and the same `ohos.toolchain.cmake`.
#
# Output: dist/libs/ohos-arm64/libaether3d_c.a
#         dist/libs/ohos-x86_64/libaether3d_c.a    (emulator slice)
#
# Dependencies:
#   OHOS_NDK_HOME    Path to the installed OpenHarmony NDK. Available from:
#                    - DevEco Studio (Tools → SDK Manager → OpenHarmony SDK / Native)
#                    - Direct download: https://developer.harmonyos.com/en/develop/deveco-studio
#                    Toolchain file lives at $OHOS_NDK_HOME/native/build/cmake/ohos.toolchain.cmake.
#                    The arm64-v8a ABI is the Mate 60 / P70 / Pura class target.
#
# Verification: walks each produced archive with the system nm and fails
# loudly if any of the four aether_glb_norm_* C ABI symbols is missing.
# (OHOS NDK doesn't ship llvm-nm at a stable path; system nm parses arm64
# Mach-O AND ELF, so it covers both host environments. If nm chokes on
# the OHOS ELF, the bundled $OHOS_NDK_HOME/native/llvm/bin/llvm-nm is
# the fallback — uncomment the LLVM_NM detection block below.)

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

if [[ -z "${OHOS_NDK_HOME:-}" ]]; then
    echo "ERROR: OHOS_NDK_HOME is not set." >&2
    echo "  Install OpenHarmony NDK via DevEco Studio or download from" >&2
    echo "  https://developer.harmonyos.com/en/develop/deveco-studio." >&2
    echo "  Then export OHOS_NDK_HOME=<path>/<sdk-version>/native" >&2
    exit 1
fi

TOOLCHAIN="${OHOS_NDK_HOME}/build/cmake/ohos.toolchain.cmake"
if [[ ! -f "$TOOLCHAIN" ]]; then
    # Some SDK packagings nest under /native; try that fallback.
    TOOLCHAIN="${OHOS_NDK_HOME}/native/build/cmake/ohos.toolchain.cmake"
fi
if [[ ! -f "$TOOLCHAIN" ]]; then
    echo "ERROR: OHOS toolchain file not found under $OHOS_NDK_HOME." >&2
    echo "  Looked for build/cmake/ohos.toolchain.cmake and native/build/cmake/ohos.toolchain.cmake." >&2
    exit 1
fi

# OHOS NDK ships a bundled llvm-nm — prefer it over system nm so we
# don't depend on darwin nm being able to parse OHOS-flavored ELF.
LLVM_NM=""
for cand in \
    "${OHOS_NDK_HOME}/llvm/bin/llvm-nm" \
    "${OHOS_NDK_HOME}/native/llvm/bin/llvm-nm" ; do
    if [[ -x "$cand" ]]; then
        LLVM_NM="$cand"
        break
    fi
done
if [[ -z "$LLVM_NM" ]]; then
    echo "WARN: bundled llvm-nm not found in OHOS_NDK_HOME; using system nm" >&2
    LLVM_NM="nm"
fi

REQUIRED_SYMBOLS=(
    aether_glb_norm_run
    aether_glb_norm_options_default
    aether_glb_norm_buffer_free
    aether_glb_norm_result_str
)

DIST_DIR="dist/libs"
mkdir -p "$DIST_DIR"

# Phone (arm64-v8a) is the only ABI we ship today. x86_64 is added as a
# commented entry — uncomment if/when DevEco emulator support lands and
# the Flutter UI needs to debug-run on the local emulator.
declare -a ABI_LIST=(arm64-v8a)
# declare -a ABI_LIST=(arm64-v8a x86_64)

for ABI in "${ABI_LIST[@]}"; do
    BUILD_DIR="aether_cpp/build-ohos-${ABI}"
    OUT_DIR="${DIST_DIR}/ohos-${ABI}"

    echo "==> [${ABI}] Configuring (NDK=${OHOS_NDK_HOME}, Dawn=OFF)..."
    rm -rf "$BUILD_DIR"
    # AETHER_FFI_BUILD_STATIC=ON triggers the Phase 4 CMakeLists branch
    # that pulls glb_norm impls (atlas_merger / glb_io / mesh_simplify) +
    # meshoptimizer directly into the FFI archive. See build_android.sh
    # for the full rationale — same approach.
    cmake -S aether_cpp -B "$BUILD_DIR" \
        -DCMAKE_TOOLCHAIN_FILE="$TOOLCHAIN" \
        -DOHOS_ARCH="${ABI}" \
        -DOHOS_PLATFORM=OHOS \
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
    # Ship under historical libaether3d_c.a name — consumer cares about
    # the C ABI surface, not the originating CMake target.
    cp "$SRC_LIB" "${OUT_DIR}/libaether3d_c.a"

    echo "==> [${ABI}] Verifying GLB normalizer symbols via ${LLVM_NM}..."
    # Capture nm output once — see build_android.sh for the SIGPIPE/pipefail
    # rationale (`grep -q` early-terminates → nm SIGPIPEs → pipeline returns
    # non-zero even when the symbol is present).
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
echo "==> OpenHarmony build complete. Artifacts:"
ls -la "${DIST_DIR}"/ohos-*/libaether3d_c.a
