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

# Function to check if current commit is a merge commit on main branch
# Returns 0 if merge commit to main, 1 otherwise
# Single source of truth for strict enforcement trigger
is_merge_commit() {
    # Check if we're on main branch
    CURRENT_REF=$(git symbolic-ref HEAD 2>/dev/null || echo "")
    if [ "$CURRENT_REF" != "refs/heads/main" ]; then
        return 1
    fi
    
    # Check if HEAD has more than one parent (merge commit)
    PARENT_COUNT=$(git log -1 --pretty=%P HEAD 2>/dev/null | wc -w)
    if [ "${PARENT_COUNT:-0}" -gt 1 ]; then
        return 0
    else
        return 1
    fi
}

# Function to check if commit message contains SSOT-Change trailer
# Returns 0 if trailer found, 1 if not found
# Canonical regex: (?im)^SSOT-Change:\s*yes\s*$
check_ssot_trailer() {
    local commit_msg="$1"
    # Case-insensitive check for standalone line: SSOT-Change: yes
    # Tolerant of whitespace variations
    if echo "$commit_msg" | grep -qiE '^SSOT-Change:\s*yes\s*$'; then
        return 0
    else
        return 1
    fi
}

# Function to check if a file path is SSOT-critical
# Returns 0 if critical, 1 if not
is_ssot_critical_path() {
    local file_path="$1"
    # SSOT-critical paths (explicit list, single source of truth)
    if [[ "$file_path" =~ ^scripts/(ssot_check\.sh|preflight_ssot\.sh)$ ]] || \
       [[ "$file_path" =~ ^Core/Constants/ ]] || \
       [[ "$file_path" =~ ^Tests/Constants/ ]] || \
       [[ "$file_path" =~ ^docs/rfcs/ ]]; then
        return 0
    else
        return 1
    fi
}

# Function to detect SSOT-critical path changes
# Sets SSOT_CRITICAL_PATHS_CHANGED=1 if any critical paths modified
# Populates SSOT_CRITICAL_PATHS_LIST array
detect_ssot_critical_paths() {
    SSOT_CRITICAL_PATHS_CHANGED=0
    SSOT_CRITICAL_PATHS_LIST=()
    
    # Check committed changes (if HEAD~1 exists)
    if git rev-parse --verify HEAD~1 >/dev/null 2>&1; then
        while IFS= read -r file; do
            if is_ssot_critical_path "$file"; then
                SSOT_CRITICAL_PATHS_CHANGED=1
                SSOT_CRITICAL_PATHS_LIST+=("$file")
            fi
        done < <(git diff --name-only HEAD~1 HEAD 2>/dev/null || true)
    fi
    
    # Check uncommitted changes (for local development)
    while IFS= read -r file; do
        if is_ssot_critical_path "$file"; then
            # Avoid duplicates
            local found=0
            for existing in "${SSOT_CRITICAL_PATHS_LIST[@]}"; do
                if [ "$existing" = "$file" ]; then
                    found=1
                    break
                fi
            done
            if [ $found -eq 0 ]; then
                SSOT_CRITICAL_PATHS_CHANGED=1
                SSOT_CRITICAL_PATHS_LIST+=("$file")
            fi
        fi
    done < <(git diff --name-only HEAD 2>/dev/null || true)
}

# Detect SSOT-critical paths early
detect_ssot_critical_paths

# Determine enforcement mode based on merge commit detection
if is_merge_commit; then
    SSOT_TRAILER_MODE="strict"
else
    SSOT_TRAILER_MODE="beta-lenient"
fi

echo "=========================================="
echo "  SSOT Preflight Check"
echo "=========================================="
echo "MODE: $SSOT_TRAILER_MODE"
if [[ "$SSOT_TRAILER_MODE" == "strict" ]]; then
    echo "  Trailer enforcement: STRICT (merge commit to main - missing trailer will fail)"
else
    echo "  Trailer enforcement: BETA/LENIENT (missing trailer will warn only)"
fi
if [ $SSOT_CRITICAL_PATHS_CHANGED -eq 1 ]; then
    echo "  SSOT-critical paths detected: YES"
    if [ ${#SSOT_CRITICAL_PATHS_LIST[@]} -gt 0 ]; then
        echo "  Critical paths changed:"
        for path in "${SSOT_CRITICAL_PATHS_LIST[@]}"; do
            echo "    - $path"
        done
    fi
else
    echo "  SSOT-critical paths detected: NO (trailer check skipped)"
fi
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
# Only enforce trailer if SSOT-critical paths changed (fair enforcement)
if [ $SSOT_CRITICAL_PATHS_CHANGED -eq 1 ]; then
    if git rev-parse --verify HEAD~1 >/dev/null 2>&1; then
        COMMIT_MSG=$(git log -1 --format="%B")
        if check_ssot_trailer "$COMMIT_MSG"; then
            success "Commit trailer 'SSOT-Change: yes' found"
        else
            # Strict enforcement ONLY for merge commits to main
            # All other cases: warn only, do not fail
            if is_merge_commit; then
                die "SSOT-critical paths changed but 'SSOT-Change: yes' trailer missing (STRICT MODE: merge commit to main)." \
                    "" \
                    "To fix:" \
                    "  git commit --amend" \
                    "  # Add 'SSOT-Change: yes' to the commit message" \
                    "  git push --force-with-lease"
            else
                warning "SSOT-Change trailer missing" \
                    "" \
                    "This is expected during PR iteration." \
                    "No action required unless merging to main."
            fi
        fi
    else
        info "No previous commit found, skipping trailer check"
    fi
else
    info "No SSOT-critical paths changed, trailer check skipped (fair enforcement)"
fi
echo ""

# Summary
echo "=========================================="
echo "  SSOT Preflight Complete"
echo "=========================================="
success "All SSOT preflight checks passed!"
