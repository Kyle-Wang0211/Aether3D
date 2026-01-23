#!/bin/bash
# audit_docs_markers.sh
# Audits that required Guardian Layer documentation markers exist
# Prevents silent documentation drift

set -euo pipefail

REPO_ROOT="${1:-$(git rev-parse --show-toplevel)}"
cd "$REPO_ROOT" || exit 1

CONSTITUTION_DIR="docs/constitution"

# Required marker strings and their expected files
# Using arrays instead of associative arrays for compatibility
MARKERS=("GUARDIAN_LAYER" "FAILURE_TRIAGE" "EXPLANATION_INTEGRITY")
FILES=("GUARDIAN_LAYER.md" "FAILURE_TRIAGE_MAP.md" "EXPLANATION_INTEGRITY_AUDIT.md")

ERRORS=0

echo "🔍 Auditing Guardian Layer documentation markers"
echo ""

for i in "${!MARKERS[@]}"; do
    marker="${MARKERS[$i]}"
    expected_file="${FILES[$i]}"
    
    # Check if file exists
    if [ ! -f "$CONSTITUTION_DIR/$expected_file" ]; then
        echo "❌ Missing file: $CONSTITUTION_DIR/$expected_file"
        echo "   Expected marker: $marker"
        ERRORS=$((ERRORS + 1))
        continue
    fi
    
    # Check if marker appears in file
    if ! git grep -q "$marker" "$CONSTITUTION_DIR/$expected_file" 2>/dev/null; then
        echo "⚠️  Marker '$marker' not found in $expected_file"
        echo "   File exists but marker missing - may need update"
    else
        echo "✅ Found '$marker' in $expected_file"
    fi
done

# Check INDEX.md references
echo ""
echo "Checking INDEX.md references..."

for marker in "${!MARKERS[@]}"; do
    expected_file="${MARKERS[$marker]}"
    if ! git grep -q "$expected_file" "$CONSTITUTION_DIR/INDEX.md" 2>/dev/null; then
        echo "⚠️  $expected_file not referenced in INDEX.md"
        echo "   Add entry to INDEX.md with 'who depends / what breaks' notes"
    else
        echo "✅ $expected_file referenced in INDEX.md"
    fi
done

if [ $ERRORS -eq 0 ]; then
    echo ""
    echo "✅ All required documentation markers present"
    exit 0
else
    echo ""
    echo "❌ Found $ERRORS missing file(s)"
    echo "   Add missing files to $CONSTITUTION_DIR/"
    exit 1
fi
