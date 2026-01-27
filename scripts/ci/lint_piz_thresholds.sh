#!/usr/bin/env bash
# lint_piz_thresholds.sh
# PR1 PIZ Detection - Lint for inline thresholds and forbidden imports
# **Rule ID:** PIZ_TOLERANCE_SSOT_001, PIZ_NUMERIC_ACCELERATION_BAN_001

set -euo pipefail

VIOLATIONS=0

echo "🔍 Checking for inline PIZ thresholds..."

# Check for inline threshold numbers (not from PIZThresholds)
# Pattern: floating-point numbers that might be thresholds
INLINE_THRESHOLD_PATTERN='(0\.75|0\.5|0\.05|0\.7|0\.3|0\.05|8|1024|128|1e-[346])'

# Check Core/PIZ directory
# Exclude: ISO8601DateFormatter (date formatting, not threshold)
# Exclude: roundHalfAwayFromZero rounding logic (0.5 is rounding constant, not threshold)
# Exclude: String format patterns (%.f, etc.)
if grep -rnE "$INLINE_THRESHOLD_PATTERN" Core/PIZ/ --include="*.swift" | \
   grep -v "PIZThresholds" | \
   grep -v "test" | \
   grep -v "//" | \
   grep -v "\.md" | \
   grep -v "XCTAssertEqual.*PIZThresholds" | \
   grep -v "ISO8601DateFormatter" | \
   grep -v "roundHalfAwayFromZero" | \
   grep -v "String(format:" | \
   grep -v "absTruncated == 0.5" | \
   grep -v "value + 0.5" | \
   grep -v "value - 0.5" > /tmp/inline_thresholds.txt 2>/dev/null; then
    echo "[PIZ_SPEC_VIOLATION] Found potential inline thresholds in Core/PIZ/:"
    cat /tmp/inline_thresholds.txt
    VIOLATIONS=$((VIOLATIONS + 1))
fi

# Check Tests/PIZ directory (allow in tests, but warn)
if grep -rnE "$INLINE_THRESHOLD_PATTERN" Tests/PIZ/ --include="*.swift" | grep -v "PIZThresholds" | grep -v "test" | grep -v "//" | grep -v "XCTAssertEqual.*PIZThresholds" > /tmp/inline_thresholds_tests.txt 2>/dev/null; then
    echo "⚠️  Found potential inline thresholds in Tests/PIZ/ (may be acceptable in tests):"
    cat /tmp/inline_thresholds_tests.txt
fi

echo "🔍 Checking for forbidden numeric acceleration imports..."

# Check for forbidden imports in PIZ decision path
FORBIDDEN_IMPORTS=(
    "import Accelerate"
    "import simd"
    "import vDSP"
    "import BLAS"
    "import LAPACK"
    "import Metal"
    "import MetalKit"
)

for import in "${FORBIDDEN_IMPORTS[@]}"; do
    if grep -rn "$import" Core/PIZ/ --include="*.swift" > /dev/null 2>&1; then
        echo "[PIZ_SPEC_VIOLATION] Found forbidden import in PIZ decision path: $import"
        grep -rn "$import" Core/PIZ/ --include="*.swift"
        VIOLATIONS=$((VIOLATIONS + 1))
    fi
done

# Check for BLAS/LAPACK keywords (function calls)
if grep -rnE '\b(cblas_|lapack_|vDSP_|vForce_|vImage_|BNNS|Accelerate)' Core/PIZ/ --include="*.swift" > /dev/null 2>&1; then
    echo "[PIZ_SPEC_VIOLATION] Found forbidden numeric acceleration function calls in PIZ decision path:"
    grep -rnE '\b(cblas_|lapack_|vDSP_|vForce_|vImage_|BNNS|Accelerate)' Core/PIZ/ --include="*.swift"
    VIOLATIONS=$((VIOLATIONS + 1))
fi

# Check for inline epsilon values
echo "🔍 Checking for inline epsilon values..."

if grep -rnE '(epsilon|eps|tolerance|tol)\s*=\s*[0-9]' Core/PIZ/ --include="*.swift" | grep -v "PIZThresholds" | grep -v "test" | grep -v "//" | grep -v "\.md" > /tmp/inline_epsilon.txt 2>/dev/null; then
    echo "[PIZ_SPEC_VIOLATION] Found inline epsilon/tolerance values:"
    cat /tmp/inline_epsilon.txt
    VIOLATIONS=$((VIOLATIONS + 1))
fi

if [ $VIOLATIONS -eq 0 ]; then
    echo "✅ No inline thresholds or forbidden imports found"
    exit 0
else
    echo "[PIZ_SPEC_VIOLATION] Found $VIOLATIONS violation(s)"
    exit 1
fi
