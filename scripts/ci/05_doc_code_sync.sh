#!/usr/bin/env bash
set -euo pipefail

DOC="docs/constitution/SSOT_CONSTANTS.md"

if [[ ! -f "$DOC" ]]; then
  echo "ERROR: Document missing: $DOC"
  exit 1
fi

# Check required blocks exist
BLOCKS=(
  "SSOT:VERSION:BEGIN"
  "SSOT:ERRORCODES:BEGIN"
  "SSOT:DOMAINS:BEGIN"
)

for block in "${BLOCKS[@]}"; do
  if ! grep -q "$block" "$DOC"; then
    echo "ERROR: Missing block $block in $DOC"
    exit 1
  fi
done

echo "OK: Document structure valid"

