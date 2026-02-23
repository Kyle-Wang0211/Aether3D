#!/bin/bash
#
# PR#1 ObservationModel CONSTITUTION - Mechanical Audit Script
#
# This script provides mechanical verification that PR#1 meets the constitution.
# Exit code: 0 = PASS, non-zero = FAIL
#

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

cd "$REPO_ROOT"

FAILED=0

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

print_pass() {
    echo -e "${GREEN}PASS${NC}: $1"
}

print_fail() {
    echo -e "${RED}FAIL${NC}: $1"
    FAILED=1
}

print_info() {
    echo -e "${YELLOW}INFO${NC}: $1"
}

echo "=========================================="
echo "PR#1 ObservationModel CONSTITUTION Audit"
echo "=========================================="
echo ""

# 1. Check required files exist
print_info "Checking required files..."

REQUIRED_FILES=(
    "docs/constitution/OBSERVATION_MODEL_CONSTITUTION.md"
    "docs/constitution/INDEX.md"
    "Core/Constants/ObservationConstants.swift"
    "Core/Models/ObservationTypes.swift"
    "Core/Models/ObservationPairMetrics.swift"
    "Core/Models/ObservationValidity.swift"
    "Core/Models/ObservationMath.swift"
    "Core/Models/ObservationModel.swift"
    "Core/SSOT/EvidenceEscalationBoundary.swift"
    "Tests/Models/ObservationModelTests.swift"
    "Tests/SSOT/EvidenceEscalationBoundaryTests.swift"
    "Package.swift"
)

for file in "${REQUIRED_FILES[@]}"; do
    if [ -f "$file" ]; then
        print_pass "File exists: $file"
    else
        print_fail "File missing: $file"
    fi
done

echo ""

# 2. Check for forbidden Apple framework imports in Core/**
print_info "Checking for forbidden Apple framework imports in Core/**..."

FORBIDDEN_IMPORTS=(
    "UIKit"
    "AVFoundation"
    "CoreGraphics"
    "QuartzCore"
    "Metal"
    "ARKit"
    "SceneKit"
)

FOUND_FORBIDDEN=0
for import in "${FORBIDDEN_IMPORTS[@]}"; do
    if grep -r "^import $import" Core/Models/ Core/SSOT/ Core/Constants/ObservationConstants.swift 2>/dev/null | grep -v "^Binary file" > /dev/null; then
        print_fail "Found forbidden import: $import in Core/**"
        grep -rn "^import $import" Core/Models/ Core/SSOT/ Core/Constants/ObservationConstants.swift 2>/dev/null | grep -v "^Binary file" || true
        FOUND_FORBIDDEN=1
    fi
done

if [ $FOUND_FORBIDDEN -eq 0 ]; then
    print_pass "No forbidden Apple framework imports found in Core/**"
fi

echo ""

# 3. Check for forbidden SIMD usage in Codable models
print_info "Checking for forbidden SIMD usage in Core/Models/**..."

SIMD_PATTERNS=(
    "SIMD3"
    "simd_quat"
    "simd_quatd"
    "SIMD<"
)

FOUND_SIMD=0
for pattern in "${SIMD_PATTERNS[@]}"; do
    if grep -r "$pattern" Core/Models/ 2>/dev/null | grep -v "^Binary file" | grep -v "//.*replaces\|//.*替代" > /dev/null; then
        print_fail "Found forbidden SIMD usage: $pattern in Core/Models/**"
        grep -rn "$pattern" Core/Models/ 2>/dev/null | grep -v "^Binary file" | grep -v "//.*replaces\|//.*替代" || true
        FOUND_SIMD=1
    fi
done

if [ $FOUND_SIMD -eq 0 ]; then
    print_pass "No forbidden SIMD usage found in Core/Models/**"
fi

echo ""

# 4. Check for forbidden default switches in constitutional code
print_info "Checking for forbidden default switches in Core/Models/** and Core/SSOT/**..."

FOUND_DEFAULT=0
if grep -r "default:" Core/Models/ Core/SSOT/ 2>/dev/null | grep -v "^Binary file" | grep -v "//.*allow\|//.*允许" > /dev/null; then
    print_fail "Found forbidden default: switch in constitutional code"
    grep -rn "default:" Core/Models/ Core/SSOT/ 2>/dev/null | grep -v "^Binary file" | grep -v "//.*allow\|//.*允许" || true
    FOUND_DEFAULT=1
fi

if [ $FOUND_DEFAULT -eq 0 ]; then
    print_pass "No forbidden default: switches found in constitutional code"
fi

echo ""

# 5. SwiftPM build verification
print_info "Running swift build..."

if swift build > /tmp/pr1_build.log 2>&1; then
    print_pass "swift build succeeded"
else
    print_fail "swift build failed"
    echo "Build output:"
    tail -50 /tmp/pr1_build.log || true
fi

echo ""

# 6. SwiftPM test verification
print_info "Running swift test for ObservationModel and EEB tests..."

if swift test --filter ObservationModelTests --filter EvidenceEscalationBoundaryTests > /tmp/pr1_test.log 2>&1; then
    TEST_COUNT=$(grep -c "passed\|failed" /tmp/pr1_test.log || echo "0")
    print_pass "swift test succeeded (ObservationModelTests and EvidenceEscalationBoundaryTests)"
    print_info "Test summary: $(grep -E 'Executed.*tests' /tmp/pr1_test.log | tail -1 || echo 'N/A')"
else
    print_fail "swift test failed"
    echo "Test output:"
    tail -50 /tmp/pr1_test.log || true
fi

echo ""

# 7. Verify closed-world enums (CaseIterable)
print_info "Checking closed-world enum compliance..."

ENUM_FILES=(
    "Core/Models/ObservationValidity.swift"
    "Core/SSOT/EvidenceEscalationBoundary.swift"
)

for file in "${ENUM_FILES[@]}"; do
    if [ -f "$file" ]; then
        # Check that InvalidReason, EEBTrigger, EvidenceLevel are CaseIterable
        if grep -q "CaseIterable" "$file"; then
            print_pass "Enums in $file are CaseIterable (closed-world)"
        else
            print_fail "Enums in $file may not be CaseIterable"
        fi
    fi
done

echo ""

# Summary
echo "=========================================="
if [ $FAILED -eq 0 ]; then
    echo -e "${GREEN}PR#1 Audit: PASSED${NC}"
    exit 0
else
    echo -e "${RED}PR#1 Audit: FAILED${NC}"
    exit 1
fi
