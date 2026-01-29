#!/bin/bash
#
# quality_lint.sh
# PR#5 Quality Pre-check - Static lint rules (functional + strict)
#

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
cd "$PROJECT_ROOT"

ERRORS=0

# Exclude directories
EXCLUDE_DIRS="-path */DerivedData -o -path */build -o -path */.build -o -path */vendor"

echo "Running Quality Pre-check static lint rules..."

# lintNoNilCoalescing - 禁止 ?? 0
echo "[1/10] Checking for nil coalescing (?? 0)..."
VIOLATIONS=$(find Core/Quality -name "*.swift" -type f \( $EXCLUDE_DIRS \) -prune -o -print0 | xargs -0 grep -rn "?? 0" 2>/dev/null || true)
if [ -n "$VIOLATIONS" ]; then
    echo "ERROR: Found '?? 0' pattern - use explicit nil handling"
    echo "$VIOLATIONS"
    ERRORS=1
fi

# lintNoWallClockInDecisions - 禁止 Date() 用于决策窗口
echo "[2/10] Checking for Date() usage in decision windows..."
VIOLATIONS=$(find Core/Quality/State Core/Quality/Direction Core/Quality/Speed Core/Quality/Degradation -name "*.swift" -type f 2>/dev/null | xargs grep -rn "Date()" 2>/dev/null | grep -v "ts_wallclock_real\|display\|comment\|//\|MonotonicClock.swift" || true)
if [ -n "$VIOLATIONS" ]; then
    echo "ERROR: Found Date() usage in decision code (should use MonotonicClock)"
    echo "$VIOLATIONS"
    ERRORS=1
fi

# lintCanonicalJSONSingleFile - 确保仅一个文件包含 canonical encoder in PR#5 domain
echo "[3/10] Checking CanonicalJSON single file (PR#5 domain only)..."
CANONICAL_FILES=$(find Core/Quality/Serialization -name "*CanonicalJSON*.swift" -type f 2>/dev/null | wc -l | tr -d ' ')
if [ "$CANONICAL_FILES" -ne 1 ]; then
    echo "ERROR: Expected exactly 1 CanonicalJSON file in Core/Quality/Serialization/, found $CANONICAL_FILES"
    find Core/Quality/Serialization -name "*CanonicalJSON*.swift" -type f 2>/dev/null
    ERRORS=1
fi

# lintNoJSONSerializationForAudit - 禁止 JSONEncoder/JSONSerialization 用于审计
echo "[4/10] Checking for JSONEncoder/JSONSerialization in audit paths..."
VIOLATIONS=$(find Core/Quality/Serialization -name "*.swift" -type f | xargs grep -rn "JSONEncoder\|JSONSerialization" 2>/dev/null | grep -v "//\|comment" || true)
if [ -n "$VIOLATIONS" ]; then
    echo "ERROR: Found JSONEncoder/JSONSerialization in audit serialization (SSOT violation)"
    echo "$VIOLATIONS"
    ERRORS=1
fi

# lintNoDirectConfidenceGateForWhite - 禁止在 DecisionPolicy 外部使用 ConfidenceGate
echo "[5/10] Checking ConfidenceGate.checkGrayToWhite usage..."
VIOLATIONS=$(find Core/Quality -name "*.swift" -type f | xargs grep -rn "ConfidenceGate\.checkGrayToWhite\|checkGrayToWhite" 2>/dev/null | grep -v "DecisionPolicy.swift\|//\|comment" || true)
if [ -n "$VIOLATIONS" ]; then
    echo "ERROR: ConfidenceGate.checkGrayToWhite called outside DecisionPolicy"
    echo "$VIOLATIONS"
    ERRORS=1
fi

# lintNoDuplicateSSOTImplementation - 禁止 SSOT 重复实现 (PR#5 domain only)
echo "[6/10] Checking SSOT implementations (PR#5 domain: Core/Quality/ only)..."

# CanonicalJSON (PR#5 domain only)
CANONICAL_COUNT=$(find Core/Quality -name "*CanonicalJSON*.swift" -type f 2>/dev/null | wc -l | tr -d ' ')
if [ "$CANONICAL_COUNT" -ne 1 ]; then
    echo "ERROR: Multiple CanonicalJSON implementations found in Core/Quality/ ($CANONICAL_COUNT)"
    find Core/Quality -name "*CanonicalJSON*.swift" -type f 2>/dev/null
    ERRORS=1
fi

# CoverageDelta encoder (check for encode() method)
DELTA_ENCODER_COUNT=$(grep -rl "func encode()" Core/Quality/WhiteCommitter/CoverageDelta.swift 2>/dev/null | wc -l | tr -d ' ')
if [ "$DELTA_ENCODER_COUNT" -ne 1 ]; then
    echo "ERROR: CoverageDelta encoder not found or multiple implementations"
    ERRORS=1
fi

# DeterministicTriangulator
TRIANGULATOR_COUNT=$(find Core/Quality/Geometry -name "*Triangulator*.swift" -type f 2>/dev/null | wc -l | tr -d ' ')
if [ "$TRIANGULATOR_COUNT" -ne 1 ]; then
    echo "ERROR: Multiple Triangulator implementations found ($TRIANGULATOR_COUNT)"
    find Core/Quality/Geometry -name "*Triangulator*.swift" -type f 2>/dev/null
    ERRORS=1
fi

# SHA256Utility (PR#5 domain only)
SHA256_COUNT=$(find Core/Quality -name "*SHA256*.swift" -type f 2>/dev/null | wc -l | tr -d ' ')
if [ "$SHA256_COUNT" -ne 1 ]; then
    echo "ERROR: Multiple SHA256 implementations found in Core/Quality/ ($SHA256_COUNT)"
    find Core/Quality -name "*SHA256*.swift" -type f 2>/dev/null
    ERRORS=1
fi

# lintNoDecisionPolicyBypass - 禁止绕过 DecisionPolicy
echo "[7/10] Checking DecisionPolicy bypass..."
# Check that all Gray→White decisions go through DecisionPolicy.canTransition
# This is a structural check - would need AST parsing for full verification
# For now, check that no other files have "Gray→White" logic
VIOLATIONS=$(find Core/Quality -name "*.swift" -type f | xargs grep -rn "to.*\.white\|VisualState\.white" 2>/dev/null | grep -v "DecisionPolicy\|DecisionController\|//\|comment" || true)
if [ -n "$VIOLATIONS" ]; then
    echo "WARNING: Potential DecisionPolicy bypass detected (manual check required)"
    echo "$VIOLATIONS"
    # Don't fail, but warn
fi

# lintNoFrameBasedTiming - 禁止基于帧的计时 (H2)
echo "[8/10] Checking for frame-based timing..."
VIOLATIONS=$(find Core/Quality -name "*.swift" -type f | xargs grep -rn "frameCount\|frame.*time\|frames.*ms" 2>/dev/null | grep -v "//\|comment" || true)
if [ -n "$VIOLATIONS" ]; then
    echo "ERROR: Found frame-based timing (should use MonotonicClock milliseconds)"
    echo "$VIOLATIONS"
    ERRORS=1
fi

# lintNoSharedMutableStateAcrossAnalyzers - 禁止分析器之间的共享可变状态 (H2)
echo "[9/10] Checking for shared mutable state..."
# Check for shared variables between analyzer files
# This is a structural check - would need deeper analysis
# For now, check that analyzers don't import each other's internal state
echo "  (Structural check - manual review recommended)"

# lintNoLocaleSensitiveComparisons - 禁止区域敏感比较 (H2)
echo "[10/10] Checking for locale-sensitive comparisons..."
VIOLATIONS=$(find Core/Quality -name "*.swift" -type f | xargs grep -rn "\.localizedCompare\|Locale\|localizedString" 2>/dev/null | grep -v "en_US_POSIX\|//\|comment" || true)
if [ -n "$VIOLATIONS" ]; then
    echo "ERROR: Found locale-sensitive comparisons (should use bytewise UTF-8)"
    echo "$VIOLATIONS"
    ERRORS=1
fi

if [ $ERRORS -eq 1 ]; then
    echo "Lint checks FAILED"
    exit 1
fi

echo "Lint checks completed successfully"
exit 0
