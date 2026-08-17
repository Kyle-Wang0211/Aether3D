#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd -P)"
cpp_root="${repo_root}/aether_cpp"
tmp_root="/private/tmp/aether-mandatory-arkit-gravity-v1"
mkdir -p "${tmp_root}"
compiler="${CXX:-/usr/bin/clang++}"
"${compiler}" --version | sed -n '1p'

flags=(-std=c++20 -Wall -Wextra -Wpedantic -Werror)
if [[ "${AETHER_TEST_SANITIZERS:-0}" == "1" ]]; then
  flags+=(-O1 -g -fsanitize=address,undefined -fno-omit-frame-pointer)
else
  flags+=(-O2)
fi

sources=(
  "${cpp_root}/tests/sfm/test_mandatory_arkit_gravity_v1.cpp"
)
if [[ -f "${cpp_root}/official_pipeline/src/mandatory_arkit_gravity_v1.cc" ]]; then
  sources+=("${cpp_root}/official_pipeline/src/mandatory_arkit_gravity_v1.cc")
fi

binary="${tmp_root}/test_mandatory_arkit_gravity_v1.$$"
"${compiler}" "${flags[@]}" "${sources[@]}" \
  -I"${cpp_root}/official_pipeline/src" \
  -o "${binary}"
"${binary}"
