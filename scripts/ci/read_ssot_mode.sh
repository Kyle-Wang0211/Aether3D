#!/bin/bash
# read_ssot_mode.sh
# Reads merge contract mode from SSOT_MODE.json
# Supports environment override with audit banner

set -euo pipefail

SSOT_MODE_FILE="${SSOT_MODE_FILE:-docs/constitution/SSOT_MODE.json}"

if [ ! -f "$SSOT_MODE_FILE" ]; then
    echo "ERROR|SSOT mode file not found: $SSOT_MODE_FILE" >&2
    exit 1
fi

# Extract mode from JSON
MODE=$(python3 <<'PYTHON_EOF'
import json
import sys
import os

try:
    mode_file = os.environ.get('SSOT_MODE_FILE', 'docs/constitution/SSOT_MODE.json')
    with open(mode_file, 'r') as f:
        data = json.load(f)
    
    mode = data.get('mode', 'WHITEBOX')
    
    # Closed-world validation
    if mode not in ['WHITEBOX', 'PRODUCTION']:
        print(f"ERROR|Invalid mode in SSOT_MODE.json: '{mode}'", file=sys.stderr)
        sys.exit(1)
    
    print(mode)
    sys.exit(0)
except Exception as e:
    print(f"ERROR|Failed to read SSOT_MODE.json: {e}", file=sys.stderr)
    sys.exit(1)
PYTHON_EOF
)

if [ $? -ne 0 ]; then
    echo "ERROR|Failed to read SSOT mode" >&2
    exit 1
fi

# Check for environment override (requires explicit opt-in with audit banner)
if [ -n "${SSOT_MERGE_CONTRACT_MODE:-}" ]; then
    if [ "$SSOT_MERGE_CONTRACT_MODE" != "$MODE" ]; then
        echo "WARNING|SSOT_MERGE_CONTRACT_MODE override detected" >&2
        echo "⚠️  AUDIT: SSOT_MERGE_CONTRACT_MODE environment variable overrides SSOT_MODE.json" >&2
        echo "⚠️  SSOT_MODE.json: $MODE" >&2
        echo "⚠️  Override value: $SSOT_MERGE_CONTRACT_MODE" >&2
        echo "⚠️  This override must be explicitly documented and audited" >&2
        MODE="$SSOT_MERGE_CONTRACT_MODE"
    fi
fi

# Final validation
if [ "$MODE" != "WHITEBOX" ] && [ "$MODE" != "PRODUCTION" ]; then
    echo "ERROR|Invalid mode: '$MODE' (must be WHITEBOX or PRODUCTION)" >&2
    exit 1
fi

echo "$MODE"
