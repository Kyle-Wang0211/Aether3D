#!/bin/sh
set -eu

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
AETHER_CPP=$(CDPATH= cd -- "$SCRIPT_DIR/../.." && pwd)
CXX=${CXX:-c++}
TMP=$(mktemp -d /private/tmp/preclamp-symbol.XXXXXX)
trap 'rm -rf "$TMP"' EXIT HUP INT TERM

"$CXX" -std=c++17 -Wall -Wextra -Werror \
  -DAETHER_PRECLAMP_INSTR_ENV_SELFTEST=1 \
  -fvisibility=hidden \
  -I"$AETHER_CPP/include" \
  "$SCRIPT_DIR/test_preclamp_instr_v1_p1_symbol_link.cc" \
  "$AETHER_CPP/official_pipeline/src/official_preclamp_instr_v1.cc" \
  "$AETHER_CPP/src/crypto/sha256.cpp" \
  -o "$TMP/preclamp_link"

if /usr/bin/nm -gU "$TMP/preclamp_link" | /usr/bin/c++filt | \
    /usr/bin/grep -F -q 'aether_preclamp_instr_v1'; then
  echo "FAIL P1 symbols: public instrumentation symbol found" >&2
  /usr/bin/nm -gU "$TMP/preclamp_link" | /usr/bin/c++filt >&2
  exit 1
fi
echo "PASS linked artifact exposes no public preclamp instrumentation ABI"
