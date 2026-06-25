#!/bin/bash
V="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"   # glomap_vendor dir, any checkout/worktree
cmake -S "$V" -B "$V/build-ios" \
  -DCMAKE_TOOLCHAIN_FILE="$V/../ceres/cmake/iOS.cmake" \
  -DIOS_PLATFORM=OS -DCMAKE_OSX_ARCHITECTURES=arm64 \
  -DCMAKE_BUILD_TYPE=Release > "$V/cfg.log" 2>&1
echo "configure exit=$? (tail:)"; tail -6 "$V/cfg.log"
echo "=== build (errors only) ==="
cmake --build "$V/build-ios" -j8 --target glomap_core > "$V/build.log" 2>&1
echo "build exit=$?"
