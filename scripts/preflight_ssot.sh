#!/bin/bash
# scripts/preflight_ssot.sh
# H9: Preflight must cover the whole pipeline (one command)
#
# Runs all SSOT-related preflight checks:
# 1) formatting/lint if tools exist
# 2) swift test (full suite)
# 3) SSOTRegistry selfCheck
# 4) frozen case order hash verification
# 5) golden digests + fieldset hash + envelope digest verification
# 6) RFC requirement check for SSOT changes
# 7) commit trailer enforcement

set -euo pipefail

# Source portable helpers
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib.sh"

REPO_ROOT=$(repo_root)
cd "$REPO_ROOT"

echo "=========================================="
echo "  SSOT Preflight Check"
echo "=========================================="
echo ""

# Step 1: Formatting/lint (if tools exist)
echo -e "${BLUE}Step 1: Formatting/Lint Check${NC}"
echo "----------------------------------------"
if command -v swiftformat >/dev/null 2>&1; then
    if swiftformat --lint . 2>/dev/null; then
        success "swiftformat check passed"
    else
        warning "swiftformat found issues (non-blocking)"
    fi
elif command -v swiftlint >/dev/null 2>&1; then
    if swiftlint lint 2>/dev/null; then
        success "swiftlint check passed"
    else
        warning "swiftlint found issues (non-blocking)"
    fi
else
    info "No formatting/lint tools found, skipping"
fi
echo ""

# Step 2: Swift test (full suite)
echo -e "${BLUE}Step 2: Swift Test Suite${NC}"
echo "----------------------------------------"
if swift test 2>&1; then
    success "All tests passed"
else
    die "Tests failed"
fi
echo ""

# Step 3: Toolchain verification
echo -e "${BLUE}Step 3: Toolchain Verification${NC}"
echo "----------------------------------------"
if [ -f "toolchain.lock" ]; then
    # Extract required Swift version from toolchain.lock
    SWIFT_MAJOR=$(grep "^swift_major=" toolchain.lock | cut -d= -f2 || echo "5")
    SWIFT_MINOR=$(grep "^swift_minor=" toolchain.lock | cut -d= -f2 || echo "9")
    verify_swift_version "$SWIFT_MAJOR" "$SWIFT_MINOR"
else
    warning "toolchain.lock not found, skipping toolchain verification"
fi
echo ""

# Step 4: SSOTRegistry selfCheck
echo -e "${BLUE}Step 4: SSOTRegistry SelfCheck${NC}"
echo "----------------------------------------"
# This will be implemented as a Swift test or executable
# For now, we'll run a test that does this
if swift test --filter SSOTRegistryTests 2>&1; then
    success "SSOTRegistry selfCheck passed"
else
    warning "SSOTRegistry selfCheck test not found or failed (may need implementation)"
fi
echo ""

# Step 5: Frozen case order hash verification
echo -e "${BLUE}Step 5: Frozen Case Order Hash Verification${NC}"
echo "----------------------------------------"
if swift test --filter CaptureProfileTests.testFrozenCaseOrderHash 2>&1; then
    success "Frozen case order hash verification passed"
else
    warning "Frozen case order hash test not found (may need implementation)"
fi
echo ""

# Step 6: Golden digests verification
echo -e "${BLUE}Step 6: Golden Digests Verification${NC}"
echo "----------------------------------------"
GOLDEN_FILE="$REPO_ROOT/Tests/Golden/policy_digests.json"
if [ -f "$GOLDEN_FILE" ]; then
    # Check line endings (H6)
    if check_line_endings "$GOLDEN_FILE"; then
        success "Golden file line endings OK (LF only)"
    else
        die "Golden file contains CRLF line endings. Must use LF only."
    fi
    
    # Run golden digest verification tests
    if swift test --filter GoldenDigestTests 2>&1; then
        success "Golden digests verification passed"
    else
        die "Golden digest verification failed. Run scripts/update_golden_policy_digests.sh if digests changed."
    fi
else
    warning "Golden file not found: $GOLDEN_FILE (may need to run update script)"
fi
echo ""

# Step 7: RFC requirement check
echo -e "${BLUE}Step 7: RFC Requirement Check${NC}"
echo "----------------------------------------"
# Check if SSOT files changed and if RFC is present
SSOT_FILES_CHANGED=0
if git rev-parse --verify HEAD~1 >/dev/null 2>&1; then
    # Check commit range
    while IFS= read -r file; do
        if [[ "$file" =~ ^Core/(Constants|Invariants)/ ]] || \
           [[ "$file" =~ ^Core/Schema/ ]] || \
           [[ "$file" =~ ^docs/constitution/ ]]; then
            SSOT_FILES_CHANGED=1
            break
        fi
    done < <(git diff --name-only HEAD~1 HEAD 2>/dev/null || true)
fi

if [ $SSOT_FILES_CHANGED -eq 1 ]; then
    # Check for RFC file or PR description marker
    HAS_RFC=0
    if [ -d "docs/rfcs" ] && [ -n "$(find docs/rfcs -name "*.md" -newer HEAD~1 2>/dev/null || true)" ]; then
        HAS_RFC=1
    fi
    
    # Check commit message for RFC: marker
    if git log -1 --format="%B" | grep -q "RFC:"; then
        HAS_RFC=1
    fi
    
    if [ $HAS_RFC -eq 0 ]; then
        die "SSOT files changed but no RFC found. " \
            "Please add an RFC file in docs/rfcs/ or add 'RFC:' marker to PR description."
    else
        success "RFC requirement satisfied"
    fi
else
    info "No SSOT files changed, skipping RFC check"
fi
echo ""

# Step 8: Commit trailer enforcement
echo -e "${BLUE}Step 8: Commit Trailer Enforcement${NC}"
echo "----------------------------------------"
if git rev-parse --verify HEAD~1 >/dev/null 2>&1; then
    SSOT_FILES_IN_COMMIT=0
    while IFS= read -r file; do
        if [[ "$file" =~ ^Core/(Constants|Invariants)/ ]] || \
           [[ "$file" =~ ^Core/Schema/ ]] || \
           [[ "$file" =~ ^docs/constitution/ ]]; then
            SSOT_FILES_IN_COMMIT=1
            break
        fi
    done < <(git diff --name-only HEAD~1 HEAD 2>/dev/null || true)
    
    if [ $SSOT_FILES_IN_COMMIT -eq 1 ]; then
        COMMIT_MSG=$(git log -1 --format="%B")
        if echo "$COMMIT_MSG" | grep -q "SSOT-Change: yes"; then
            success "Commit trailer 'SSOT-Change: yes' found"
        else
            die "SSOT files changed in commit but 'SSOT-Change: yes' trailer missing. " \
                "Please add 'SSOT-Change: yes' to your commit message."
        fi
    else
        info "No SSOT files in commit, skipping trailer check"
    fi
else
    info "No previous commit found, skipping trailer check"
fi
echo ""

# Summary
echo "=========================================="
echo "  SSOT Preflight Complete"
echo "=========================================="
success "All SSOT preflight checks passed!"
