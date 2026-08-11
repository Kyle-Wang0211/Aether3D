#!/bin/sh
set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)
VENDOR="$ROOT/aether_cpp/third_party/glomap_vendor"
BUILD="$ROOT/aether_cpp/official_pipeline/build-ios-device"

cmake -S "$VENDOR" -B "$BUILD" \
  -DCMAKE_TOOLCHAIN_FILE="$ROOT/aether_cpp/third_party/ceres/cmake/iOS.cmake" \
  -DIOS_PLATFORM=OS \
  -DCMAKE_OSX_ARCHITECTURES=arm64 \
  -DCMAKE_BUILD_TYPE=Release \
  -DCMAKE_EXPORT_COMPILE_COMMANDS=ON \
  -DBUILD_BENCH=OFF
cmake --build "$BUILD" --target pwofficial_core -j8
shasum -a 256 "$BUILD/libpwofficial_core.a"
