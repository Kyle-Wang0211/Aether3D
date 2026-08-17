#!/bin/sh
set -eu

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
AETHER_CPP=$(CDPATH= cd -- "$SCRIPT_DIR/../.." && pwd)
EXTRACTOR="$AETHER_CPP/tools/sift_extract_dawn.cc"

line_of() {
  /usr/bin/grep -n -F "$1" "$EXTRACTOR" | /usr/bin/head -n 1 | /usr/bin/cut -d: -f1
}

detect_guard=$(line_of 'if (n_detect == 0)')
detect_buffer=$(line_of 'std::vector<uint32_t> keep_init(n_detect, 1u)')
kept_guard=$(line_of 'if (n_kept == 0)')
kept_buffer=$(line_of 'wgpu::Buffer aff_in_buf =')
oriented_guard=$(line_of 'if (n_oriented == 0)')
oriented_read=$(line_of 'std::vector<uint32_t> ori_all = read_u32(')

[ "$detect_guard" -lt "$detect_buffer" ] || {
  echo "FAIL R2: detect-zero guard follows candidate buffer creation" >&2
  exit 1
}
[ "$kept_guard" -lt "$kept_buffer" ] || {
  echo "FAIL R2: kept-zero guard follows affine buffer creation" >&2
  exit 1
}
[ "$oriented_guard" -lt "$oriented_read" ] || {
  echo "FAIL R2: oriented-zero guard follows clamp readback" >&2
  exit 1
}

zero_blocks=$(
  /usr/bin/awk '
    /if \(n_(detect|kept|oriented) == 0\)/ { in_guard = 1; saw_discard = 0 }
    in_guard && /PendingDiscardReason::kZeroCandidate/ { saw_discard = 1 }
    in_guard && /return true;/ {
      if (!saw_discard) exit 2
      ++count
      in_guard = 0
    }
    END { if (count != 3) exit 3; print count }
  ' "$EXTRACTOR"
)
[ "$zero_blocks" = 3 ]

echo "PASS R2 three existing zero-feature guards precede all candidate-sized Dawn buffers"
