#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd -P)"
cpp_root="${repo_root}/aether_cpp"
tmp_root="/private/tmp/aether-pair-selection-v2"
mkdir -p "${tmp_root}"
compiler="${CXX:-/usr/bin/clang++}"
"${compiler}" --version | sed -n '1p'

compile_flags=(-std=c++20 -Wall -Wextra -Wpedantic -Werror)
if [[ "${AETHER_TEST_SANITIZERS:-0}" == "1" ]]; then
  compile_flags+=(-O1 -g -fsanitize=address,undefined -fno-omit-frame-pointer)
else
  compile_flags+=(-O2)
fi

for test_source in \
  "${cpp_root}/tests/sfm/test_pair_selection_v2.cpp" \
  "${cpp_root}/tests/sfm/test_spatial_temporal_pair_selection_v2.cpp" \
  "${cpp_root}/tests/sfm/test_pair_selection_v2_trajectories.cpp" \
  "${cpp_root}/tests/sfm/test_pair_policy_v2_c.cpp" \
  "${cpp_root}/tests/sfm/test_visual_loop_index_v1.cpp"; do
  test_name="$(basename "${test_source}" .cpp)"
  binary="${tmp_root}/${test_name}.$$"
  sources=("${test_source}")
  if [[ -f "${cpp_root}/official_pipeline/src/pair_selection_v2.cc" ]]; then
    sources+=("${cpp_root}/official_pipeline/src/pair_selection_v2.cc")
  fi
  if [[ -f "${cpp_root}/official_pipeline/src/pair_policy_v2_c.cc" ]]; then
    sources+=("${cpp_root}/official_pipeline/src/pair_policy_v2_c.cc")
  fi
  if [[ -f "${cpp_root}/official_pipeline/src/visual_loop_index_v1.cc" ]]; then
    sources+=("${cpp_root}/official_pipeline/src/visual_loop_index_v1.cc")
  fi
  "${compiler}" \
    "${compile_flags[@]}" \
    "${sources[@]}" \
    -I"${cpp_root}/official_pipeline/src" \
    -I"${cpp_root}/official_pipeline/include" \
    -o "${binary}"

  "${binary}"
done
