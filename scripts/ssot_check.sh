#!/bin/bash
# scripts/ssot_check.sh
# Single developer entrypoint for SSOT validation
# Productized failures with clear remediation

set -euo pipefail

# SSOT_SKIP_TESTS=1 -> skip swift test execution (work-controlled)
SKIP_TESTS=0
if [[ "${SSOT_SKIP_TESTS:-0}" == "1" ]]; then
  echo "⚠️ SSOT_SKIP_TESTS=1 -> skipping swift test execution in ssot_check.sh"
  SKIP_TESTS=1
fi

# Source portable helpers
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib.sh"

REPO_ROOT=$(repo_root)
cd "$REPO_ROOT"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Track failures
FAILURES=0
FAILURE_MESSAGES=()

# Helper to record failures
record_failure() {
    FAILURES=$((FAILURES + 1))
    FAILURE_MESSAGES+=("$1")
}

# Print header
echo "=========================================="
echo "  SSOT Check (One-Command Entrypoint)"
echo "=========================================="
echo ""

# Step 1: Toolchain verification
echo -e "${BLUE}Step 1: Toolchain Verification${NC}"
echo "----------------------------------------"
if [ -f "toolchain.lock" ]; then
    SWIFT_MAJOR=$(grep "^swift_major=" toolchain.lock | cut -d= -f2 || echo "5")
    SWIFT_MINOR=$(grep "^swift_minor=" toolchain.lock | cut -d= -f2 || echo "9")
    if verify_swift_version "$SWIFT_MAJOR" "$SWIFT_MINOR"; then
        echo -e "${GREEN}✓${NC} Swift version matches toolchain.lock"
    else
        record_failure "Swift version mismatch. Expected: $SWIFT_MAJOR.$SWIFT_MINOR"
        echo -e "${RED}✗${NC} Swift version mismatch"
    fi
else
    warning "toolchain.lock not found, skipping"
fi
echo ""

# Step 2: Formatting/Lint (non-blocking)
echo -e "${BLUE}Step 2: Formatting/Lint Check${NC}"
echo "----------------------------------------"
if command -v swiftformat >/dev/null 2>&1; then
    if swiftformat --lint . 2>/dev/null; then
        echo -e "${GREEN}✓${NC} swiftformat check passed"
    else
        warning "swiftformat found issues (non-blocking)"
    fi
elif command -v swiftlint >/dev/null 2>&1; then
    if swiftlint lint 2>/dev/null; then
        echo -e "${GREEN}✓${NC} swiftlint check passed"
    else
        warning "swiftlint found issues (non-blocking)"
    fi
else
    info "No formatting/lint tools found, skipping"
fi
echo ""

# Step 3: Swift test suite
echo -e "${BLUE}Step 3: Swift Test Suite${NC}"
echo "----------------------------------------"
if swift test -v 2>&1 | tee /tmp/ssot_test_output.log; then
    echo -e "${GREEN}✓${NC} All tests passed"
else
    record_failure "Tests failed. Review output above or run: swift test -v"
    echo -e "${RED}✗${NC} Tests failed"
    
    # Extract failure summary
    FAILED_COUNT=$(grep -c "failed\|error:" /tmp/ssot_test_output.log || echo "0")
    if [ "$FAILED_COUNT" -gt 0 ]; then
        echo ""
        echo "Failed test summary:"
        grep -E "failed|error:" /tmp/ssot_test_output.log | head -10
    fi
fi
echo ""

# Step 4: SSOTRegistry selfCheck
echo -e "${BLUE}Step 4: SSOTRegistry SelfCheck${NC}"
echo "----------------------------------------"
if swift test --filter SSOTRegistryTests.testSelfCheckPasses 2>&1 | grep -q "passed"; then
    echo -e "${GREEN}✓${NC} SSOTRegistry selfCheck passed"
else
    record_failure "SSOTRegistry selfCheck failed"
    echo -e "${RED}✗${NC} SSOTRegistry selfCheck failed"
fi
echo ""

# Step 5: Frozen case order hash verification
echo -e "${BLUE}Step 5: Frozen Case Order Hash${NC}"
echo "----------------------------------------"
if swift test --filter CaptureProfileTests.testFrozenCaseOrderHash 2>&1 | grep -q "passed"; then
    echo -e "${GREEN}✓${NC} Frozen case order hash verified"
else
    record_failure "Frozen case order hash mismatch"
    echo -e "${RED}✗${NC} Frozen case order hash mismatch"
fi
echo ""

# Step 6: Golden digest verification
echo -e "${BLUE}Step 6: Golden Digest Verification${NC}"
echo "----------------------------------------"
GOLDEN_FILE="$REPO_ROOT/Tests/Golden/policy_digests.json"
if [ -f "$GOLDEN_FILE" ]; then
    # Check line endings
    if check_line_endings "$GOLDEN_FILE"; then
        echo -e "${GREEN}✓${NC} Golden file line endings OK (LF only)"
    else
        record_failure "Golden file contains CRLF. Run: scripts/update_golden_policy_digests.sh"
        echo -e "${RED}✗${NC} Golden file line endings invalid"
    fi
    
    # Run golden digest tests
    if swift test --filter GoldenDigestTests 2>&1 | grep -q "passed"; then
        echo -e "${GREEN}✓${NC} Golden digests match"
    else
        record_failure "Golden digest mismatch. Run: scripts/update_golden_policy_digests.sh"
        echo -e "${RED}✗${NC} Golden digest mismatch"
    fi
else
    record_failure "Golden file not found. Run: scripts/update_golden_policy_digests.sh"
    echo -e "${RED}✗${NC} Golden file not found"
fi
echo ""

# Step 7: UpdateGolden determinism check (N>=5 runs)
echo -e "${BLUE}Step 7: UpdateGolden Determinism Check (5 runs)${NC}"
echo "----------------------------------------"
TEMP_DIR=$(mktemp -d)
trap "rm -rf $TEMP_DIR" EXIT

# Run UpdateGoldenDigests N times (N>=5) and compare
if swift build --product UpdateGoldenDigests 2>&1 >/dev/null; then
    # Run N times
    for i in {1..5}; do
        "$REPO_ROOT/.build/debug/UpdateGoldenDigests" > "$TEMP_DIR/run$i.json" 2>&1 || true
    done
    
    # Compare all runs
    ALL_MATCH=1
    FIRST_RUN="$TEMP_DIR/run1.json"
    for i in {2..5}; do
        if ! diff -q "$FIRST_RUN" "$TEMP_DIR/run$i.json" >/dev/null 2>&1; then
            ALL_MATCH=0
            record_failure "UpdateGoldenDigests produces non-deterministic output (run 1 vs run $i)"
            echo -e "${RED}✗${NC} UpdateGoldenDigests non-deterministic (run 1 vs run $i)"
            # Show minimal diff
            diff -u "$FIRST_RUN" "$TEMP_DIR/run$i.json" | head -20
            break
        fi
    done
    
    if [ $ALL_MATCH -eq 1 ]; then
        echo -e "${GREEN}✓${NC} UpdateGoldenDigests is deterministic (5 runs match)"
    fi
else
    warning "Could not build UpdateGoldenDigests, skipping determinism check"
fi
echo ""

# Step 8: Governance gates (RFC + trailer)
echo -e "${BLUE}Step 8: Governance Gates${NC}"
echo "----------------------------------------"

# Check for SSOT file changes (committed or uncommitted)
SSOT_FILES_CHANGED=0
SSOT_FILES_LIST=()

# Check committed changes (if HEAD~1 exists)
if git rev-parse --verify HEAD~1 >/dev/null 2>&1; then
    while IFS= read -r file; do
        if [[ "$file" =~ ^Core/(Constants|Invariants)/ ]] || \
           [[ "$file" =~ ^Core/Schema/ ]] || \
           [[ "$file" =~ ^docs/constitution/ ]]; then
            SSOT_FILES_CHANGED=1
            SSOT_FILES_LIST+=("$file")
        fi
    done < <(git diff --name-only HEAD~1 HEAD 2>/dev/null || true)
fi

# Check uncommitted changes (for local development)
while IFS= read -r file; do
    if [[ "$file" =~ ^Core/(Constants|Invariants)/ ]] || \
       [[ "$file" =~ ^Core/Schema/ ]] || \
       [[ "$file" =~ ^docs/constitution/ ]]; then
        SSOT_FILES_CHANGED=1
        SSOT_FILES_LIST+=("$file")
    fi
done < <(git diff --name-only HEAD 2>/dev/null || true)

if [ $SSOT_FILES_CHANGED -eq 1 ]; then
    # Print changed files for clarity
    if [ ${#SSOT_FILES_LIST[@]} -gt 0 ]; then
        echo "SSOT files changed:"
        for file in "${SSOT_FILES_LIST[@]}"; do
            echo "  - $file"
        done
        echo ""
    fi
    
    # Check RFC
    HAS_RFC=0
    RFC_FILE=""
    RFC_SATISFIED_VIA=""
    
    # Method A: Check for RFC files in PR diff (committed changes)
    if git rev-parse --verify HEAD~1 >/dev/null 2>&1; then
        while IFS= read -r file; do
            if [[ "$file" =~ ^docs/rfcs/.*\.md$ ]]; then
                RFC_FILE="$file"
                HAS_RFC=1
                RFC_SATISFIED_VIA="docs/rfcs diff"
                break
            fi
        done < <(git diff --name-only HEAD~1 HEAD 2>/dev/null || true)
    fi
    
    # Method B: Check for RFC files in uncommitted changes (local development)
    if [ $HAS_RFC -eq 0 ]; then
        while IFS= read -r file; do
            if [[ "$file" =~ ^docs/rfcs/.*\.md$ ]]; then
                RFC_FILE="$file"
                HAS_RFC=1
                RFC_SATISFIED_VIA="uncommitted diff"
                break
            fi
        done < <(git diff --name-only HEAD 2>/dev/null || true)
    fi
    
    # Method C: Check commit message for RFC: marker (case-sensitive, must start line)
    if [ $HAS_RFC -eq 0 ] && git rev-parse --verify HEAD >/dev/null 2>&1; then
        COMMIT_MSG=$(git log -1 --format="%B" 2>/dev/null || echo "")
        if echo "$COMMIT_MSG" | grep -qE "^RFC:"; then
            HAS_RFC=1
            RFC_SATISFIED_VIA="commit message trailer (RFC:)"
        fi
    fi
    
    # Diagnostics output
    if [ ${#SSOT_FILES_LIST[@]} -gt 0 ]; then
        echo "SSOT files changed:"
        for file in "${SSOT_FILES_LIST[@]}"; do
            echo "  - $file"
        done
        echo ""
    fi
    
    if [ $HAS_RFC -eq 0 ]; then
        record_failure "SSOT files changed but no RFC found. Add RFC file or 'RFC:' marker"
        echo -e "${RED}✗${NC} RFC requirement not satisfied"
        echo ""
        echo "Remediation:"
        echo "  1. Create RFC file: docs/rfcs/00X-ssot-change-description.md"
        echo "  2. Use template: docs/rfcs/000-template.md"
        echo "  3. Or add 'RFC: <number>' to commit message (must start the line)"
        if [ ${#SSOT_FILES_LIST[@]} -gt 0 ]; then
            echo ""
            echo "Changed SSOT files requiring RFC:"
            for file in "${SSOT_FILES_LIST[@]}"; do
                echo "  - $file"
            done
        fi
    else
        if [ -n "$RFC_FILE" ]; then
            echo -e "${GREEN}✓${NC} RFC requirement satisfied via: $RFC_SATISFIED_VIA (file: $RFC_FILE)"
        else
            echo -e "${GREEN}✓${NC} RFC requirement satisfied via: $RFC_SATISFIED_VIA"
        fi
    fi
    
    # Check commit trailer (only for committed changes)
    if git rev-parse --verify HEAD >/dev/null 2>&1; then
        COMMIT_MSG=$(git log -1 --format="%B" 2>/dev/null || echo "")
        COMMIT_SHA=$(git rev-parse --short HEAD 2>/dev/null || echo "unknown")
        COMMIT_SUBJECT=$(git log -1 --format="%s" 2>/dev/null || echo "unknown")
        
        if echo "$COMMIT_MSG" | grep -q "SSOT-Change: yes"; then
            echo -e "${GREEN}✓${NC} Commit trailer 'SSOT-Change: yes' found"
        else
            # Only fail if there are committed changes
            if git rev-parse --verify HEAD~1 >/dev/null 2>&1 && \
               git diff --name-only HEAD~1 HEAD 2>/dev/null | grep -qE "^Core/(Constants|Invariants)/|^Core/Schema/|^docs/constitution/"; then
                record_failure "SSOT files changed but 'SSOT-Change: yes' trailer missing"
                echo -e "${RED}✗${NC} Commit trailer missing"
                echo ""
                echo "Commit context:"
                echo "  SHA: $COMMIT_SHA"
                echo "  Subject: $COMMIT_SUBJECT"
                echo ""
                echo "Remediation:"
                echo "  The commit message MUST include 'SSOT-Change: yes' in the trailer section."
                echo "  PR description does NOT satisfy this requirement."
                echo ""
                echo "  To fix, amend the commit:"
                echo "    git commit --amend"
                echo ""
                echo "  Then add a blank line and the trailer at the end:"
                echo "    SSOT-Change: yes"
                echo ""
                echo "  Example commit message format:"
                echo "    <commit subject>"
                echo ""
                echo "    <commit body>"
                echo ""
                echo "    SSOT-Change: yes"
            else
                info "No committed SSOT changes, trailer check skipped"
            fi
        fi
    else
        info "No commits found, trailer check skipped"
    fi
else
    info "No SSOT files changed, skipping governance gates"
fi
echo ""

# Summary
echo "=========================================="
echo "  SSOT Check Complete"
echo "=========================================="

if [ $FAILURES -eq 0 ]; then
    echo -e "${GREEN}✓ All checks passed!${NC}"
    exit 0
else
    echo -e "${RED}✗ $FAILURES check(s) failed${NC}"
    echo ""
    echo "Failures:"
    for msg in "${FAILURE_MESSAGES[@]}"; do
        echo "  - $msg"
    done
    echo ""
    echo "Remediation:"
    echo "  1. Review failures above"
    echo "  2. Run: ./scripts/ssot_check.sh"
    echo "  3. If golden mismatch: ./scripts/update_golden_policy_digests.sh"
    exit 1
fi
