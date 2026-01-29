#!/usr/bin/env bash
set -euo pipefail

# CI-HARDENED: SSOT document hash integrity verification
# Ported from pr1/ssot-foundation-v1_1
# Zero external dependencies (uses only shasum, grep, git)

echo "==> SSOT Integrity Verification"

# Dependency check
for cmd in shasum grep git; do
  if ! command -v "$cmd" &> /dev/null; then
    echo "❌ Missing required command: $cmd"
    exit 1
  fi
done

FAILED=0
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
cd "$REPO_ROOT"

# ============================================================================
# Check 1: Constitution document hash integrity
# ============================================================================
echo "[1/3] Verifying constitution document hashes..."

HASH_CHECKED=0
HASH_MISSING=0
HASH_MISMATCH=0

for md in docs/constitution/*.md; do
  [ -f "$md" ] || continue

  hash_file="${md%.md}.hash"
  if [ ! -f "$hash_file" ]; then
    # Hash file not required for all documents (yet)
    # Track as missing but don't fail
    HASH_MISSING=$((HASH_MISSING + 1))
    continue
  fi

  HASH_CHECKED=$((HASH_CHECKED + 1))
  expected=$(cat "$hash_file" | tr -d '[:space:]')
  actual=$(shasum -a 256 "$md" | cut -d' ' -f1)

  if [ "$expected" != "$actual" ]; then
    echo "❌ INTEGRITY VIOLATION: $md"
    echo "   Document has been modified without updating hash"
    echo "   Expected: $expected"
    echo "   Actual:   $actual"
    echo "   Fix: shasum -a 256 $md | cut -d' ' -f1 > $hash_file"
    HASH_MISMATCH=$((HASH_MISMATCH + 1))
    FAILED=1
  fi
done

if [ $HASH_MISMATCH -eq 0 ]; then
  echo "   ✅ $HASH_CHECKED documents verified, $HASH_MISSING without hash files (acceptable)"
else
  echo "   ❌ $HASH_MISMATCH hash mismatches found"
fi

# ============================================================================
# Check 2: Constants files have CONSTITUTIONAL CONTRACT header
# NOTE: This is a WARNING check, not blocking. Will be enforced in future.
# ============================================================================
echo "[2/3] Verifying constants file headers..."

HEADER_CHECKED=0
HEADER_MISSING=0

for swift in Core/Constants/*.swift; do
  [ -f "$swift" ] || continue
  HEADER_CHECKED=$((HEADER_CHECKED + 1))

  # Check for CONSTITUTIONAL CONTRACT or SSOT marker in first 20 lines
  if ! head -20 "$swift" | grep -qE "CONSTITUTIONAL CONTRACT|SSOT|Single Source of Truth"; then
    echo "⚠️  HEADER MISSING: $swift"
    echo "   Constants file missing 'CONSTITUTIONAL CONTRACT' or 'SSOT' header"
    echo "   Fix: Add '// SSOT: Single Source of Truth' comment in file header"
    HEADER_MISSING=$((HEADER_MISSING + 1))
    # NOTE: Not failing for now - this will be enforced after headers are added
    # FAILED=1
  fi
done

if [ $HEADER_MISSING -eq 0 ]; then
  echo "   ✅ $HEADER_CHECKED constants files have proper headers"
else
  echo "   ⚠️  $HEADER_MISSING files missing headers (warning only, will be enforced later)"
fi

# ============================================================================
# Check 3: SSOT registry consistency (code vs docs)
# ============================================================================
echo "[3/3] Verifying SSOT registry consistency..."

# Check that SSOT_CONSTANTS.md exists and has required sections
SSOT_DOC="docs/constitution/SSOT_CONSTANTS.md"
if [ ! -f "$SSOT_DOC" ]; then
  echo "❌ SSOT_CONSTANTS.md not found"
  FAILED=1
else
  SECTIONS_OK=1

  # Required SSOT markers
  for marker in "SSOT:VERSION:BEGIN" "SSOT:VERSION:END" "SSOT:FILES:BEGIN" "SSOT:FILES:END" "SSOT:SYSTEM_CONSTANTS:BEGIN" "SSOT:SYSTEM_CONSTANTS:END"; do
    if ! grep -q "$marker" "$SSOT_DOC"; then
      echo "❌ Missing required section marker: $marker"
      SECTIONS_OK=0
      FAILED=1
    fi
  done

  if [ $SECTIONS_OK -eq 1 ]; then
    echo "   ✅ SSOT_CONSTANTS.md has all required section markers"
  fi
fi

# ============================================================================
# Summary
# ============================================================================
echo ""
if [ $FAILED -ne 0 ]; then
  echo "❌ SSOT integrity verification FAILED"
  exit 1
fi

echo "==> SSOT integrity verification PASSED"
exit 0
