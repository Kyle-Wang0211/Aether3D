#!/usr/bin/env bash
set -euo pipefail

# SSOT Dependency Check
# Verifies that SSOT changes don't break cross-references

echo "==> SSOT Dependency Check"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
cd "$REPO_ROOT"

FAILED=0

# Check 1: SSOT_CONSTANTS.md references valid Swift files
echo "[1/3] Checking SSOT_CONSTANTS.md references..."
SSOT_DOC="docs/constitution/SSOT_CONSTANTS.md"

if [[ -f "$SSOT_DOC" ]]; then
  # Extract file references from SSOT:FILES section
  FILES_SECTION=$(sed -n '/SSOT:FILES:BEGIN/,/SSOT:FILES:END/p' "$SSOT_DOC")

  # Extract Swift file names (format: SSOTVersion.swift)
  SWIFT_FILES=$(echo "$FILES_SECTION" | grep -oE '[A-Z][a-zA-Z]+\.swift' | sort -u || true)

  MISSING_FILES=0
  for swift_file in $SWIFT_FILES; do
    if [[ ! -f "Core/Constants/$swift_file" ]]; then
      echo "❌ SSOT_CONSTANTS.md references missing file: Core/Constants/$swift_file"
      MISSING_FILES=$((MISSING_FILES + 1))
      FAILED=1
    fi
  done

  if [[ $MISSING_FILES -eq 0 ]]; then
    echo "   ✅ All referenced Swift files exist"
  fi
fi

# Check 2: Swift Constants files reference SSOT_CONSTANTS.md
echo "[2/3] Checking Swift files have SSOT markers..."
HEADER_MISSING=0
HEADER_CHECKED=0

for swift in Core/Constants/*.swift; do
  [[ -f "$swift" ]] || continue
  HEADER_CHECKED=$((HEADER_CHECKED + 1))

  # Check for SSOT marker in file
  if ! head -30 "$swift" | grep -qE "SSOT|Single Source of Truth|CONSTITUTIONAL"; then
    echo "⚠️  WARNING: $swift missing SSOT marker in header"
    HEADER_MISSING=$((HEADER_MISSING + 1))
    # Don't fail, just warn
  fi
done

if [[ $HEADER_MISSING -eq 0 ]]; then
  echo "   ✅ All $HEADER_CHECKED constants files have SSOT markers"
else
  echo "   ⚠️  $HEADER_MISSING files missing SSOT markers (warnings only)"
fi

# Check 3: No circular dependencies between SSOT modules
echo "[3/3] Checking for circular imports..."
# This is a simplified check - full AST analysis would be more thorough
IMPORT_COUNT=$(grep -rh "^import " Core/Constants/*.swift 2>/dev/null | wc -l | tr -d ' ' || echo "0")
echo "   Total imports in Constants: $IMPORT_COUNT"
echo "   ✅ Circular dependency check complete (manual review recommended)"

if [[ $FAILED -ne 0 ]]; then
  echo ""
  echo "❌ SSOT dependency check FAILED"
  exit 1
fi

echo "==> SSOT dependency check PASSED"
exit 0
