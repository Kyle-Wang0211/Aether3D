#!/usr/bin/env bash
#
# Build aether3d_c (with the Phase 4 GLB normalizer C ABI) for the Web
# via Emscripten, plus the EMSCRIPTEN_KEEPALIVE wrapper that drags the
# four C ABI symbols into the .wasm.
#
# Output: dist/libs/web/glb_norm.{wasm,js}
#
# Dependencies:
#   emcc / emcmake / emmake on $PATH (e.g. `brew install emscripten` or
#   the official emsdk activation: `source ~/emsdk/emsdk_env.sh`).
#
# Verification: walks the produced .wasm with wasm-objdump (or wasm-nm
# fallback) and fails loudly if any of the four aether_glb_norm_*
# exports are missing. JS callers ccall these by name, so a silent
# strip would surface as "function does not exist" at runtime.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

if ! command -v emcmake >/dev/null; then
    echo "ERROR: emcmake not on PATH." >&2
    echo "  brew install emscripten   (macOS)" >&2
    echo "  or git clone https://github.com/emscripten-core/emsdk.git && cd emsdk && ./emsdk install latest && ./emsdk activate latest && source ./emsdk_env.sh" >&2
    exit 1
fi

REQUIRED_SYMBOLS=(
    aether_glb_norm_run
    aether_glb_norm_options_default
    aether_glb_norm_buffer_free
    aether_glb_norm_result_str
)

BUILD_DIR="aether_cpp/build-web"
OUT_DIR="dist/libs/web"

mkdir -p "$OUT_DIR"

echo "==> Configuring Emscripten build (Dawn=OFF, Release)..."
rm -rf "$BUILD_DIR"
emcmake cmake -S aether_cpp -B "$BUILD_DIR" \
    -DCMAKE_BUILD_TYPE=Release \
    -DAETHER_ENABLE_DAWN=OFF

echo "==> Building aether3d_c.a (transitively builds aether3d_core)..."
cmake --build "$BUILD_DIR" --target aether3d_c -j 8

CORE_LIB="${BUILD_DIR}/libaether3d_core.a"
C_LIB="${BUILD_DIR}/libaether3d_c.a"
MESHOPT_LIB="${BUILD_DIR}/libmeshoptimizer.a"
for lib in "$C_LIB" "$CORE_LIB" "$MESHOPT_LIB"; do
    if [[ ! -f "$lib" ]]; then
        echo "ERROR: expected ${lib} not produced." >&2
        exit 1
    fi
done

echo "==> Linking glb_norm.wasm + glb_norm.js via emcc..."
# -sUSE_ZLIB=1 must be on the link line because we're bypassing CMake's
# ZLIB::ZLIB INTERFACE propagation (we go directly to em++ instead of
# letting CMake's emcc wrapper handle the consumer link). glb_io.cpp
# calls compressBound / compress2 from zlib for the binary-chunk packer.
em++ -O3 \
    -I aether_cpp/include \
    -sUSE_ZLIB=1 \
    -s EXPORTED_FUNCTIONS='["_aether_glb_norm_run","_aether_glb_norm_options_default","_aether_glb_norm_buffer_free","_aether_glb_norm_result_str","_aether_glb_norm_keepalive","_malloc","_free"]' \
    -s EXPORTED_RUNTIME_METHODS='["ccall","cwrap","HEAPU8"]' \
    -s ALLOW_MEMORY_GROWTH=1 \
    -s WASM=1 \
    -s MODULARIZE=1 \
    -s EXPORT_NAME=AetherGlbNorm \
    -o "${OUT_DIR}/glb_norm.js" \
    emscripten/glb_norm_wasm.cpp \
    "$C_LIB" "$CORE_LIB" "$MESHOPT_LIB"

[[ -f "${OUT_DIR}/glb_norm.wasm" ]] || { echo "ERROR: glb_norm.wasm not produced" >&2; exit 1; }
[[ -f "${OUT_DIR}/glb_norm.js"   ]] || { echo "ERROR: glb_norm.js   not produced" >&2; exit 1; }

echo "==> Verifying wasm exports..."
# Prefer wasm-objdump (bundled with the emsdk WABT pkg + brew formula).
# Fallback to grepping the JS glue, which lists exports as `_<name>:`.
WASM_OBJDUMP="$(command -v wasm-objdump || true)"
# Capture wasm-objdump output once to avoid `grep -q` early-terminate +
# pipefail interaction (see build_android.sh for the rationale).
OBJDUMP_OUT=""
if [[ -n "$WASM_OBJDUMP" ]]; then
    OBJDUMP_OUT="$("$WASM_OBJDUMP" -x "${OUT_DIR}/glb_norm.wasm" 2>/dev/null || true)"
fi
for sym in "${REQUIRED_SYMBOLS[@]}"; do
    found=0
    if [[ -n "$OBJDUMP_OUT" ]] && grep -q "${sym}" <<<"$OBJDUMP_OUT"; then
        found=1
    fi
    # Even with wasm-objdump available, also check JS glue — Closure may
    # rename internal names but exports listed in JS are authoritative.
    if grep -q "_${sym}" "${OUT_DIR}/glb_norm.js"; then
        found=1
    fi
    if [[ $found -eq 0 ]]; then
        echo "ERROR: ${sym} not found in glb_norm.wasm/.js exports" >&2
        exit 1
    fi
done

WASM_BYTES=$(stat -f%z "${OUT_DIR}/glb_norm.wasm" 2>/dev/null \
              || stat -c%s "${OUT_DIR}/glb_norm.wasm")
JS_BYTES=$(stat -f%z "${OUT_DIR}/glb_norm.js" 2>/dev/null \
            || stat -c%s "${OUT_DIR}/glb_norm.js")

echo
echo "==> Web build complete."
echo "    glb_norm.wasm  ${WASM_BYTES} bytes"
echo "    glb_norm.js    ${JS_BYTES} bytes"
ls -la "${OUT_DIR}/"
