#!/bin/bash
#
# build_cpp_and_swift.sh
# CMake + Swift Package 集成构建脚本
# Orchestrates: 1) CMake build aether_cpp, 2) Swift build (with optional libaether3d_c link)
#
# Usage:
#   ./scripts/build_cpp_and_swift.sh [--cpp-only|--swift-only|--all]
# Default: --all (build C++ then Swift)
#

set -euo pipefail

MODE="${1:---all}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
AETHER_CPP="${REPO_ROOT}/aether_cpp"
AETHER_CPP_BUILD="${AETHER_CPP}/build"

cd "$REPO_ROOT"

build_cpp() {
    if [ ! -d "$AETHER_CPP" ]; then
        echo "⚠️  aether_cpp/ not found. Run CURSOR_MEGA_PROMPT STEP 1 first to create scaffold."
        echo "   mkdir -p aether_cpp/{include/aether,src/{math,...},tests,golden,cmake}"
        return 1
    fi
    if [ ! -f "$AETHER_CPP/CMakeLists.txt" ]; then
        echo "⚠️  aether_cpp/CMakeLists.txt not found. Create CMake scaffold first."
        return 1
    fi
    echo "=== Building aether_cpp ==="
    cd "$AETHER_CPP"
    cmake -B build -S . -DCMAKE_BUILD_TYPE=Release
    cmake --build build
    cd "$REPO_ROOT"
    echo "✅ aether_cpp built to $AETHER_CPP_BUILD"
}

build_swift() {
    echo "=== Building Swift Package ==="
    swift build
    echo "✅ Swift build succeeded"
}

case "$MODE" in
    --cpp-only)
        build_cpp
        ;;
    --swift-only)
        build_swift
        ;;
    --all)
        build_cpp
        build_swift
        ;;
    *)
        echo "Usage: $0 [--cpp-only|--swift-only|--all]"
        exit 1
        ;;
esac
