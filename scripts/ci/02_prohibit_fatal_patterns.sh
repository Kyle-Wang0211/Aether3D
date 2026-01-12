#!/usr/bin/env bash
set -euo pipefail

PATTERNS=(
  "fatalError("
  "preconditionFailure("
  "assertionFailure("
)

VIOLATIONS=0
for p in "${PATTERNS[@]}"; do
  # Check only Constants directory (exclude existing code)
  # Exclude comments and exemptions
  if grep -rn "$p" Core/Constants/ --include="*.swift" 2>/dev/null | grep -v "// LINT:ALLOW\|// SSOT_EXEMPTION\|// CRITICAL:"; then
    echo "ERROR: Found '$p' in Core/Constants/"
    VIOLATIONS=1
  fi
done

if [[ $VIOLATIONS -ne 0 ]]; then
  exit 1
fi
echo "OK: no fatal patterns"

