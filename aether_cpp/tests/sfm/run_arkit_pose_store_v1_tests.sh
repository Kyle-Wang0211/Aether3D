#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "$0")/../../.." && pwd)"
out="${TMPDIR:-/private/tmp}/test_arkit_pose_store_v1"
flags=(-std=c++17 -Wall -Wextra -Werror)
if [[ "${AETHER_TEST_SANITIZERS:-0}" == "1" ]]; then
  flags+=(-O1 -g -fsanitize=address,undefined -fno-omit-frame-pointer)
else
  flags+=(-O2)
fi

c++ "${flags[@]}" \
  -I"$repo_root/aether_cpp/official_pipeline/src" \
  "$repo_root/aether_cpp/tests/sfm/test_arkit_pose_store_v1.cpp" \
  "$repo_root/aether_cpp/official_pipeline/src/arkit_pose_store_v1.cc" \
  -o "$out"
"$out"

echo "PASS arkit_pose_store_v1"
