#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "$0")/../../.." && pwd)"
src="$repo_root/aether_cpp/tests/sfm/test_gravity_ba_prior_v1.cpp"
out="${TMPDIR:-/private/tmp}/test_gravity_ba_prior_v1"
flags=(-std=c++17 -Wall -Wextra -Werror)
if [[ "${AETHER_TEST_SANITIZERS:-0}" == "1" ]]; then
  flags+=(-O1 -g -fsanitize=address,undefined -fno-omit-frame-pointer)
else
  flags+=(-O2)
fi

c++ "${flags[@]}" \
  -I"$repo_root/aether_cpp/official_pipeline/src" \
  -I/opt/homebrew/include/eigen3 \
  "$src" -o "$out"
"$out"

echo "PASS gravity_ba_prior_v1"
