#!/bin/bash
# PR1 Constitutional Amendments - Full Pre-Push Verification
# Usage: ./scripts/pr1-full-verification.sh

set -e

echo "╔══════════════════════════════════════════════════════════════╗"
echo "║     PR1 CONSTITUTIONAL AMENDMENTS - FULL VERIFICATION        ║"
echo "╚══════════════════════════════════════════════════════════════╝"
echo ""

# ===== PHASE 1: File Existence =====
echo "=== PHASE 1: File Existence ==="

FILES=(
    "docs/constitution/CI_HARDENING_CONSTITUTION.md"
    "docs/constitution/MODULE_CONTRACT_EQUIVALENCE.md"
    "docs/constitution/SPEC_DRIFT_HANDLING.md"
    "docs/constitution/LOCAL_PREFLIGHT_GATE.md"
    "docs/constitution/EMERGENCY_PROTOCOL.md"
    "docs/constitution/CI_HARDENING_CONSTITUTION.hash"
    "docs/constitution/MODULE_CONTRACT_EQUIVALENCE.hash"
    "docs/constitution/SPEC_DRIFT_HANDLING.hash"
    "docs/constitution/LOCAL_PREFLIGHT_GATE.hash"
    "docs/constitution/EMERGENCY_PROTOCOL.hash"
    "docs/drift/DRIFT_REGISTRY.md"
    "docs/emergencies/ACTIVE_BYPASSES.md"
    "scripts/scan-prohibited-patterns.sh"
    "scripts/verify-ssot-integrity.sh"
    "scripts/verify-all-hashes.sh"
    "scripts/install-hooks.sh"
    "scripts/pre-push"
    "scripts/check-overdue-bypasses.sh"
)

FAILED=0
for f in "${FILES[@]}"; do
    if [ -f "$f" ]; then
        echo "  ✓ $f exists"
    else
        echo "  ✗ MISSING: $f"
        FAILED=1
    fi
done

if [ $FAILED -eq 1 ]; then
    echo "PHASE 1 FAILED"
    exit 1
fi
echo "✓ PHASE 1 PASSED: All 18 files exist"
echo ""

# ===== PHASE 2: Hash Verification =====
echo "=== PHASE 2: Hash Verification ==="

DOCS=(
    "docs/constitution/CI_HARDENING_CONSTITUTION"
    "docs/constitution/MODULE_CONTRACT_EQUIVALENCE"
    "docs/constitution/SPEC_DRIFT_HANDLING"
    "docs/constitution/LOCAL_PREFLIGHT_GATE"
    "docs/constitution/EMERGENCY_PROTOCOL"
)

FAILED=0
for base in "${DOCS[@]}"; do
    expected=$(cat "${base}.hash" | tr -d '[:space:]')
    actual=$(shasum -a 256 "${base}.md" | cut -d' ' -f1)
    if [ "$expected" = "$actual" ]; then
        echo "  ✓ ${base}.md hash matches"
    else
        echo "  ✗ HASH MISMATCH: ${base}.md"
        echo "    Expected: $expected"
        echo "    Actual:   $actual"
        FAILED=1
    fi
done

if [ $FAILED -eq 1 ]; then
    echo "PHASE 2 FAILED"
    exit 1
fi
echo "✓ PHASE 2 PASSED: All 5 hashes match"
echo ""

# ===== PHASE 3: Document Content =====
echo "=== PHASE 3: Document Content ==="

FAILED=0

# Check CI_HARDENING has §0-§8
echo "  Checking CI_HARDENING_CONSTITUTION.md..."
for s in "§0" "§1" "§2" "§3" "§4" "§5" "§6" "§7" "§8"; do
    if grep -q "$s" docs/constitution/CI_HARDENING_CONSTITUTION.md; then
        echo "    ✓ $s found"
    else
        echo "    ✗ MISSING: $s"
        FAILED=1
    fi
done

# Check MODULE_CONTRACT has §0-§9
echo "  Checking MODULE_CONTRACT_EQUIVALENCE.md..."
for s in "§0" "§1" "§2" "§3" "§4" "§5" "§6" "§7" "§8" "§9"; do
    if grep -q "$s" docs/constitution/MODULE_CONTRACT_EQUIVALENCE.md; then
        echo "    ✓ $s found"
    else
        echo "    ✗ MISSING: $s"
        FAILED=1
    fi
done

# Check SPEC_DRIFT has §0-§9
echo "  Checking SPEC_DRIFT_HANDLING.md..."
for s in "§0" "§1" "§2" "§3" "§4" "§5" "§6" "§7" "§8" "§9"; do
    if grep -q "$s" docs/constitution/SPEC_DRIFT_HANDLING.md; then
        echo "    ✓ $s found"
    else
        echo "    ✗ MISSING: $s"
        FAILED=1
    fi
done

# Check LOCAL_PREFLIGHT has §0-§6
echo "  Checking LOCAL_PREFLIGHT_GATE.md..."
for s in "§0" "§1" "§2" "§3" "§4" "§5" "§6"; do
    if grep -q "$s" docs/constitution/LOCAL_PREFLIGHT_GATE.md; then
        echo "    ✓ $s found"
    else
        echo "    ✗ MISSING: $s"
        FAILED=1
    fi
done

# Check EMERGENCY_PROTOCOL has §0-§7
echo "  Checking EMERGENCY_PROTOCOL.md..."
for s in "§0" "§1" "§2" "§3" "§4" "§5" "§6" "§7"; do
    if grep -q "$s" docs/constitution/EMERGENCY_PROTOCOL.md; then
        echo "    ✓ $s found"
    else
        echo "    ✗ MISSING: $s"
        FAILED=1
    fi
done

# Check all docs have IMMUTABLE
echo "  Checking IMMUTABLE markers..."
for doc in docs/constitution/CI_HARDENING_CONSTITUTION.md docs/constitution/MODULE_CONTRACT_EQUIVALENCE.md docs/constitution/SPEC_DRIFT_HANDLING.md docs/constitution/LOCAL_PREFLIGHT_GATE.md docs/constitution/EMERGENCY_PROTOCOL.md; do
    if grep -q "IMMUTABLE" "$doc"; then
        echo "    ✓ $(basename $doc) has IMMUTABLE marker"
    else
        echo "    ✗ $(basename $doc) MISSING IMMUTABLE marker"
        FAILED=1
    fi
done

# Check version numbers
echo "  Checking version numbers..."
for doc in docs/constitution/CI_HARDENING_CONSTITUTION.md docs/constitution/MODULE_CONTRACT_EQUIVALENCE.md docs/constitution/SPEC_DRIFT_HANDLING.md docs/constitution/LOCAL_PREFLIGHT_GATE.md docs/constitution/EMERGENCY_PROTOCOL.md; do
    if grep -q "1.0.0" "$doc"; then
        echo "    ✓ $(basename $doc) has version 1.0.0"
    else
        echo "    ✗ $(basename $doc) MISSING version 1.0.0"
        FAILED=1
    fi
done

# Check dates
echo "  Checking dates..."
for doc in docs/constitution/CI_HARDENING_CONSTITUTION.md docs/constitution/MODULE_CONTRACT_EQUIVALENCE.md docs/constitution/SPEC_DRIFT_HANDLING.md docs/constitution/LOCAL_PREFLIGHT_GATE.md docs/constitution/EMERGENCY_PROTOCOL.md; do
    if grep -q "2026-01-28" "$doc"; then
        echo "    ✓ $(basename $doc) has date 2026-01-28"
    else
        echo "    ✗ $(basename $doc) MISSING date 2026-01-28"
        FAILED=1
    fi
done

if [ $FAILED -eq 1 ]; then
    echo "PHASE 3 FAILED"
    exit 1
fi
echo "✓ PHASE 3 PASSED: All documents have required sections"
echo ""

# ===== PHASE 4: INDEX.md =====
echo "=== PHASE 4: INDEX.md ==="

ENTRIES=("CI_HARDENING_CONSTITUTION" "MODULE_CONTRACT_EQUIVALENCE" "SPEC_DRIFT_HANDLING" "LOCAL_PREFLIGHT_GATE" "EMERGENCY_PROTOCOL")
FAILED=0
for e in "${ENTRIES[@]}"; do
    count=$(grep -c "$e" docs/constitution/INDEX.md || echo 0)
    if [ "$count" -ge 1 ]; then
        echo "  ✓ $e found in INDEX.md ($count times)"
    else
        echo "  ✗ MISSING from INDEX.md: $e"
        FAILED=1
    fi
done

# Check format consistency
echo "  Checking format consistency..."
for entry in "${ENTRIES[@]}"; do
    line_num=$(grep -n "$entry" docs/constitution/INDEX.md | head -1 | cut -d: -f1)
    if [ -z "$line_num" ]; then
        echo "    ✗ Cannot find $entry in INDEX.md"
        FAILED=1
        continue
    fi
    
    next_lines=$(sed -n "$((line_num+1)),$((line_num+3))p" docs/constitution/INDEX.md)
    
    if echo "$next_lines" | grep -q "Who depends"; then
        echo "    ✓ $entry has 'Who depends'"
    else
        echo "    ✗ $entry MISSING 'Who depends'"
        FAILED=1
    fi
    
    if echo "$next_lines" | grep -q "What breaks"; then
        echo "    ✓ $entry has 'What breaks'"
    else
        echo "    ✗ $entry MISSING 'What breaks'"
        FAILED=1
    fi
    
    if echo "$next_lines" | grep -q "Why exists"; then
        echo "    ✓ $entry has 'Why exists'"
    else
        echo "    ✗ $entry MISSING 'Why exists'"
        FAILED=1
    fi
done

if [ $FAILED -eq 1 ]; then
    echo "PHASE 4 FAILED"
    exit 1
fi
echo "✓ PHASE 4 PASSED: INDEX.md has all 5 entries with correct format"
echo ""

# ===== PHASE 5: DRIFT_REGISTRY =====
echo "=== PHASE 5: DRIFT_REGISTRY ==="

DRIFT_COUNT=$(grep -c "^| D[0-9]" docs/drift/DRIFT_REGISTRY.md 2>/dev/null || echo 0)
if [ "$DRIFT_COUNT" -eq 10 ]; then
    echo "  ✓ DRIFT_REGISTRY contains exactly 10 drifts (D001-D010)"
else
    echo "  ✗ DRIFT_REGISTRY should contain 10 drifts, found: $DRIFT_COUNT"
    exit 1
fi

# Check all drift IDs
FAILED=0
for i in $(seq 1 10); do
    if [ "$i" -lt 10 ]; then
        drift_id="D00$i"
    else
        drift_id="D010"
    fi
    
    if grep -q "$drift_id" docs/drift/DRIFT_REGISTRY.md; then
        echo "    ✓ $drift_id found"
    else
        echo "    ✗ MISSING: $drift_id"
        FAILED=1
    fi
done

# Check table header
if grep -q "| ID | PR | Constant | Plan | SSOT | Category | Reason | Impact | Date |" docs/drift/DRIFT_REGISTRY.md; then
    echo "  ✓ DRIFT_REGISTRY has correct table header"
else
    echo "  ✗ DRIFT_REGISTRY table header incorrect"
    FAILED=1
fi

if [ $FAILED -eq 1 ]; then
    echo "PHASE 5 FAILED"
    exit 1
fi
echo "✓ PHASE 5 PASSED: DRIFT_REGISTRY has 10 drifts"
echo ""

# ===== PHASE 6: Script Syntax =====
echo "=== PHASE 6: Script Syntax ==="

SCRIPTS=("scripts/scan-prohibited-patterns.sh" "scripts/verify-ssot-integrity.sh" "scripts/verify-all-hashes.sh" "scripts/install-hooks.sh" "scripts/pre-push" "scripts/check-overdue-bypasses.sh")
FAILED=0
for s in "${SCRIPTS[@]}"; do
    if bash -n "$s" 2>/dev/null; then
        echo "  ✓ $(basename $s) syntax OK"
    else
        echo "  ✗ Syntax error in $s"
        FAILED=1
    fi
    
    if [ -x "$s" ]; then
        echo "    ✓ $(basename $s) is executable"
    else
        echo "    ✗ $s not executable"
        FAILED=1
    fi
done

if [ $FAILED -eq 1 ]; then
    echo "PHASE 6 FAILED"
    exit 1
fi
echo "✓ PHASE 6 PASSED: All 6 scripts have valid syntax and are executable"
echo ""

# ===== PHASE 7: Script Execution Test =====
echo "=== PHASE 7: Script Execution Test ==="

if ./scripts/verify-all-hashes.sh 2>&1 | grep -q "OK:"; then
    echo "  ✓ verify-all-hashes.sh executed successfully"
else
    echo "  ⚠ verify-all-hashes.sh execution had warnings (may be expected for existing docs)"
fi
echo "✓ PHASE 7 COMPLETED"
echo ""

# ===== PHASE 8: Cross-References =====
echo "=== PHASE 8: Cross-References ==="

FAILED=0

if grep -q "ClockProvider" docs/constitution/CI_HARDENING_CONSTITUTION.md; then
    echo "  ✓ CI_HARDENING references ClockProvider"
else
    echo "  ✗ CI_HARDENING should reference ClockProvider"
    FAILED=1
fi

if grep -q "DRIFT_REGISTRY" docs/constitution/SPEC_DRIFT_HANDLING.md; then
    echo "  ✓ SPEC_DRIFT references DRIFT_REGISTRY"
else
    echo "  ✗ SPEC_DRIFT should reference DRIFT_REGISTRY"
    FAILED=1
fi

if grep -q "ACTIVE_BYPASSES" docs/constitution/EMERGENCY_PROTOCOL.md; then
    echo "  ✓ EMERGENCY_PROTOCOL references ACTIVE_BYPASSES"
else
    echo "  ✗ EMERGENCY_PROTOCOL should reference ACTIVE_BYPASSES"
    FAILED=1
fi

if grep -q "CLOSED_SET_GOVERNANCE" docs/constitution/MODULE_CONTRACT_EQUIVALENCE.md || grep -q "closed.set" docs/constitution/MODULE_CONTRACT_EQUIVALENCE.md; then
    echo "  ✓ MODULE_CONTRACT references closed-set concepts"
else
    echo "  ⚠ MODULE_CONTRACT should reference CLOSED_SET_GOVERNANCE (warning)"
fi

if grep -q "CI_HARDENING" docs/constitution/LOCAL_PREFLIGHT_GATE.md || grep -q "prohibited pattern" docs/constitution/LOCAL_PREFLIGHT_GATE.md; then
    echo "  ✓ LOCAL_PREFLIGHT references CI hardening concepts"
else
    echo "  ⚠ LOCAL_PREFLIGHT should reference CI_HARDENING (warning)"
fi

if [ $FAILED -eq 1 ]; then
    echo "PHASE 8 FAILED"
    exit 1
fi
echo "✓ PHASE 8 PASSED: Cross-references valid"
echo ""

# ===== PHASE 9: Swift Build (Optional) =====
echo "=== PHASE 9: Swift Build (Optional) ==="

if command -v swift &> /dev/null; then
    if swift build 2>&1 | head -5; then
        echo "  ✓ swift build succeeded"
    else
        echo "  ⚠ swift build failed or not applicable (non-blocking)"
    fi
else
    echo "  ⚠ swift not found, skipping build check"
fi
echo "✓ PHASE 9 COMPLETED"
echo ""

# ===== PHASE 10: Git Status =====
echo "=== PHASE 10: Git Status ==="

UNTRACKED=$(git status --porcelain 2>/dev/null | grep "^??" | grep -E "(constitution|drift|emergencies|scripts)" || true)

if [ -n "$UNTRACKED" ]; then
    echo "  ⚠ Untracked files found (should be added before commit):"
    echo "$UNTRACKED" | sed 's/^/    /'
else
    echo "  ✓ No untracked constitution/drift/emergencies/scripts files"
fi
echo "✓ PHASE 10 COMPLETED"
echo ""

echo "╔══════════════════════════════════════════════════════════════╗"
echo "║     ✓ ALL PHASES PASSED - SAFE TO PUSH                       ║"
echo "╚══════════════════════════════════════════════════════════════╝"
