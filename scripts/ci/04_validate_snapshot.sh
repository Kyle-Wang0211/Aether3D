#!/usr/bin/env bash
set -euo pipefail

SNAPSHOT="docs/constitution/errorcodes_snapshot.json"

if [[ ! -f "$SNAPSHOT" ]]; then
  echo "ERROR: Snapshot file missing: $SNAPSHOT"
  exit 1
fi

# Validate JSON syntax
if ! python3 -m json.tool "$SNAPSHOT" > /dev/null 2>&1; then
  echo "ERROR: Invalid JSON in $SNAPSHOT"
  exit 1
fi

# Check required fields
if ! grep -q '"schemaVersion"' "$SNAPSHOT"; then
  echo "ERROR: Missing schemaVersion in snapshot"
  exit 1
fi

if ! grep -q '"errorCodes"' "$SNAPSHOT"; then
  echo "ERROR: Missing errorCodes in snapshot"
  exit 1
fi

echo "OK: Snapshot validation passed"

