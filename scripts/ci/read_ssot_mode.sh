#!/usr/bin/env bash
set -euo pipefail

SSOT_MODE_FILE="${SSOT_MODE_FILE:-docs/constitution/SSOT_MODE.json}"

if [ ! -f "$SSOT_MODE_FILE" ]; then
    echo "ERROR: SSOT mode file not found: $SSOT_MODE_FILE" >&2
    exit 1
fi

MODE=$(python3 <<'PYTHON_EOF'
import json
import os
import sys

mode_file = os.environ.get("SSOT_MODE_FILE", "docs/constitution/SSOT_MODE.json")

try:
    with open(mode_file, "r", encoding="utf-8") as f:
        data = json.load(f)
except Exception as exc:
    print(f"ERROR: failed to read {mode_file}: {exc}", file=sys.stderr)
    sys.exit(1)

mode = data.get("mode", "WHITEBOX")
if mode not in ("WHITEBOX", "PRODUCTION"):
    print(f"ERROR: invalid mode '{mode}' (expected WHITEBOX or PRODUCTION)", file=sys.stderr)
    sys.exit(1)

print(mode)
PYTHON_EOF
)

if [ -n "${SSOT_MERGE_CONTRACT_MODE:-}" ] && [ "${SSOT_MERGE_CONTRACT_MODE}" != "$MODE" ]; then
    if [ "${SSOT_MERGE_CONTRACT_MODE}" != "WHITEBOX" ] && [ "${SSOT_MERGE_CONTRACT_MODE}" != "PRODUCTION" ]; then
        echo "ERROR: invalid SSOT_MERGE_CONTRACT_MODE '${SSOT_MERGE_CONTRACT_MODE}' (expected WHITEBOX or PRODUCTION)" >&2
        exit 1
    fi
    echo "WARN: SSOT_MERGE_CONTRACT_MODE override applied (${MODE} -> ${SSOT_MERGE_CONTRACT_MODE})" >&2
    MODE="${SSOT_MERGE_CONTRACT_MODE}"
fi

echo "$MODE"
