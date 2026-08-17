#!/bin/sh
set -eu

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
IMPLEMENTATION="$SCRIPT_DIR/../../official_pipeline/src/official_preclamp_instr_v1.cc"

retry_count=$(/usr/bin/grep -F -c \
  'if (count < 0 && errno == EINTR) continue;' "$IMPLEMENTATION")
[ "$retry_count" -eq 3 ] || {
  echo "FAIL R12: artifact and Stage-B read/write loops must retry EINTR" >&2
  exit 1
}

/usr/bin/awk '
  /ArtifactStatus HashRegularFile\(/ { in_hash = 1 }
  in_hash && /if \(info.st_size == 0\)/ { zero_guard = NR }
  in_hash && /::mmap\(/ { mmap_call = NR; exit }
  END { exit !(zero_guard > 0 && mmap_call > zero_guard) }
' "$IMPLEMENTATION" || {
  echo "FAIL R12: zero-size guard must precede mmap" >&2
  exit 1
}

/usr/bin/awk '
  /bool WriteAll\(/ { in_write = 1 }
  in_write && /if \(count <= 0\) return false;/ { zero_write = 1; exit }
  END { exit !zero_write }
' "$IMPLEMENTATION" || {
  echo "FAIL R12: zero-byte write must fail closed" >&2
  exit 1
}

echo "PASS R12 EINTR retry and nonzero mmap/write source contract"
