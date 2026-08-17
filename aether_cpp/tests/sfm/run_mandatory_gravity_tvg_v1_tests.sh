#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd -P)"
cpp_root="${repo_root}/aether_cpp"
vendor_root="${cpp_root}/third_party/glomap_vendor"
tmp_root="/private/tmp/aether-mandatory-gravity-tvg-v1"
mkdir -p "${tmp_root}"
compiler="${CXX:-/usr/bin/clang++}"
"${compiler}" --version | sed -n '1p'

sources=(
  "${cpp_root}/tests/sfm/test_mandatory_gravity_tvg_v1.cpp"
  "${cpp_root}/official_pipeline/src/upright_relative_pose_v1.cc"
)
if [[ -f "${cpp_root}/official_pipeline/src/mandatory_gravity_tvg_v1.cc" ]]; then
  sources+=("${cpp_root}/official_pipeline/src/mandatory_gravity_tvg_v1.cc")
fi

binary="${tmp_root}/test_mandatory_gravity_tvg_v1.$$"
flags=(-std=c++20 -Wall -Wextra -Wpedantic -Werror)
if [[ "${AETHER_TEST_SANITIZERS:-0}" == "1" ]]; then
  flags+=(-O1 -g -fsanitize=address,undefined -fno-omit-frame-pointer)
else
  flags+=(-O2)
fi
"${compiler}" "${flags[@]}" \
  -DGLOG_USE_GLOG_EXPORT -DGLOG_VERSION_MAJOR=0 -DGLOG_VERSION_MINOR=7 \
  -DGLOG_NO_ABBREVIATED_SEVERITIES -Wno-sign-compare \
  "${sources[@]}" \
  -I"${cpp_root}/official_pipeline/src" \
  -I"${cpp_root}/third_party/eigen" \
  -I"/opt/homebrew/opt/boost/include" \
  -I"/opt/homebrew/opt/glog/include" \
  -I"${cpp_root}/third_party/ceres/include" \
  -I"${cpp_root}/third_party/ceres-build-ios/include" \
  -I"${cpp_root}/third_party/ceres/config" \
  -I"${vendor_root}/poselib-src" \
  -I"${vendor_root}/colmap-src" \
  "${vendor_root}/build-host/libpwofficial_core.a" \
  -L"/opt/homebrew/lib" -lceres -lglog -lsqlite3 \
  -o "${binary}"
"${binary}"
