#!/usr/bin/env bash
set -euo pipefail

BASE_REF="${BASE_REF:-origin/main}"
CHANGED="$(git diff --name-only "$BASE_REF"...HEAD 2>/dev/null || git diff --name-only HEAD~1 2>/dev/null || echo "")"

# Check if SSOT surface touched
if echo "$CHANGED" | grep -Eq '^Core/Constants/|^docs/constitution/'; then
  echo "SSOT surface touched, checking declaration..."
  
  LAST_MSG="$(git log -1 --pretty=%B 2>/dev/null || echo "")"
  if ! echo "$LAST_MSG" | grep -q "SSOT-Change:"; then
    echo "ERROR: SSOT touched but no SSOT-Change declaration in commit"
    exit 1
  fi
fi

echo "OK: SSOT declaration check passed"

