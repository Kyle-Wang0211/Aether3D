#!/bin/bash
# validate_actions_pinning_audit_comment.sh
# Validates that all action pins have audit comments
# SSOT-blocking for SSOT workflows, warning for others

set -euo pipefail

WORKFLOW_FILE="${1:-.github/workflows/ssot-foundation-ci.yml}"

if [ ! -f "$WORKFLOW_FILE" ]; then
    # SSOT Foundation workflow removed - exit gracefully
    exit 0
fi

ERRORS=0
WARNINGS=0

# Determine if this is an SSOT workflow
IS_SSOT=0
if [[ "$WORKFLOW_FILE" == *"ssot-foundation"* ]]; then
    IS_SSOT=1
fi

if [ $IS_SSOT -eq 1 ]; then
    echo "🔒 Validating Actions Pinning Audit Comments (SSOT workflow - strict)"
else
    echo "🔒 Validating Actions Pinning Audit Comments (Non-SSOT workflow - warning only)"
fi
echo ""

# Extract uses: lines and check for audit comments
VALIDATION_RESULT=$(python3 <<PYTHON_EOF
import re
import sys

try:
    with open('$WORKFLOW_FILE', 'r') as f:
        lines = f.readlines()
    
    results = []
    
    for i, line in enumerate(lines, 1):
        # Check for uses: with SHA (40-char hex)
        if 'uses:' in line:
            uses_match = re.search(r'uses:\s*[^@]+@([a-f0-9]{40})', line)
            if uses_match:
                sha = uses_match.group(1)
                # Check previous line OR same line for audit comment
                has_audit_comment = False
                
                # Check same line (inline comment)
                comment_pattern = r'#\s*pinned\s+from\s+v\d+\s+\(\d{4}-\d{2}-\d{2}\)'
                if re.search(comment_pattern, line):
                    has_audit_comment = True
                
                # Check previous line (if exists)
                if not has_audit_comment and i > 1:
                    prev_line = lines[i-2].strip()
                    if re.match(comment_pattern, prev_line):
                        has_audit_comment = True
                
                if has_audit_comment:
                    results.append(f"VALID|{i}|{sha[:8]}... has audit comment")
                else:
                    results.append(f"MISSING|{i}|{sha[:8]}... missing audit comment")
    
    for result in results:
        print(result)
    
    sys.exit(0)
except Exception as e:
    print(f"Error: {e}", file=sys.stderr)
    sys.exit(1)
PYTHON_EOF
)

# Process results
while IFS='|' read -r status line_num detail; do
    case "$status" in
        VALID)
            echo "  ✅ Line $line_num: $detail"
            ;;
        MISSING)
            if [ $IS_SSOT -eq 1 ]; then
                echo "  ❌ Line $line_num: $detail"
                ERRORS=$((ERRORS + 1))
            else
                echo "  ⚠️  Line $line_num: $detail (warning only)"
                WARNINGS=$((WARNINGS + 1))
            fi
            ;;
    esac
done <<< "$VALIDATION_RESULT"

echo ""

if [ $ERRORS -eq 0 ]; then
    if [ $WARNINGS -gt 0 ]; then
        echo "✅ Actions pinning audit validation passed with warnings ($WARNINGS warning(s))"
    else
        echo "✅ Actions pinning audit validation passed"
    fi
    exit 0
else
    echo "❌ Actions pinning audit validation failed ($ERRORS error(s))"
    echo ""
    echo "Policy: Every 'uses:' line with a SHA must have an audit comment:"
    echo "  # pinned from vX (YYYY-MM-DD)"
    echo "  uses: owner/repo@<sha>"
    echo ""
    echo "See docs/constitution/ACTIONS_PINNING_POLICY.md"
    exit 1
fi
