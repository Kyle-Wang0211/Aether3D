#!/bin/bash
# Scan for CI_HARDENING_CONSTITUTION prohibited patterns
# Source: LOCAL_PREFLIGHT_GATE.md §3.1

set -e

VIOLATIONS=0

# Swift prohibited patterns
SWIFT_PATTERNS=(
    'Date()'
    'Timer\.scheduledTimer'
    'DispatchQueue.*asyncAfter'
    'Thread\.sleep'
    'Task\.sleep'
)

# Python prohibited patterns
PYTHON_PATTERNS=(
    'datetime\.now()'
    'datetime\.utcnow()'
    'time\.time()'
    'time\.sleep('
)

echo "Scanning Swift files..."
for pattern in "${SWIFT_PATTERNS[@]}"; do
    matches=$(grep -rn "$pattern" --include="*.swift" Sources/ 2>/dev/null | grep -v "Default.*Provider" | grep -v "Tests/" || true)
    if [ -n "$matches" ]; then
        echo "VIOLATION: $pattern found:"
        echo "$matches"
        VIOLATIONS=$((VIOLATIONS + 1))
    fi
done

echo "Scanning Python files..."
for pattern in "${PYTHON_PATTERNS[@]}"; do
    matches=$(grep -rn "$pattern" --include="*.py" src/ 2>/dev/null | grep -v "default.*provider" | grep -v "test_" || true)
    if [ -n "$matches" ]; then
        echo "VIOLATION: $pattern found:"
        echo "$matches"
        VIOLATIONS=$((VIOLATIONS + 1))
    fi
done

if [ $VIOLATIONS -gt 0 ]; then
    echo ""
    echo "Found $VIOLATIONS violation(s). See CI_HARDENING_CONSTITUTION.md §1."
    exit 1
fi

echo "No prohibited patterns found."
exit 0
