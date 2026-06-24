#!/bin/bash
V=/Users/kaidongwang/Developer/aether_cpp/third_party/glomap_vendor
cmake -S "$V" -B "$V/build-ios" \
  -DCMAKE_TOOLCHAIN_FILE=/Users/kaidongwang/Developer/aether_cpp/third_party/ceres/cmake/iOS.cmake \
  -DIOS_PLATFORM=OS -DCMAKE_OSX_ARCHITECTURES=arm64 \
  -DCMAKE_BUILD_TYPE=Release > "$V/cfg.log" 2>&1
echo "configure exit=$? (tail:)"; tail -6 "$V/cfg.log"
echo "=== build (errors only) ==="
cmake --build "$V/build-ios" -j8 --target glomap_core > "$V/build.log" 2>&1
echo "build exit=$?"
