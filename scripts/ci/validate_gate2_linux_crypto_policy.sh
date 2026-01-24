#!/bin/bash
# validate_gate2_linux_crypto_policy.sh
# Validates that Linux Gate 2 explicitly sets SSOT_PURE_SWIFT_SHA256="1" (closed-world policy)
# Includes escape hatch with audit logging

set -euo pipefail

WORKFLOW_FILE="${1:-.github/workflows/ssot-foundation-ci.yml}"

if [ ! -f "$WORKFLOW_FILE" ]; then
    echo "❌ Workflow file not found: $WORKFLOW_FILE"
    exit 1
fi

ERRORS=0
ESCAPE_HATCHES=0
AUDIT_RECORDS=()

echo "🔒 Validating Gate 2 Linux Crypto Policy (closed-world assertion)"
echo ""

# Extract Gate 2 job section
GATE2_SECTION=$(python3 <<PYTHON_EOF
import yaml
import sys

try:
    with open('$WORKFLOW_FILE', 'r') as f:
        workflow = yaml.safe_load(f)
    
    # Find gate_2_determinism_trust job
    jobs = workflow.get('jobs', {})
    gate2_job = jobs.get('gate_2_determinism_trust', {})
    
    if not gate2_job:
        print("gate_2_determinism_trust job not found", file=sys.stderr)
        sys.exit(1)
    
    # Get matrix entries
    strategy = gate2_job.get('strategy', {})
    matrix = strategy.get('matrix', {})
    includes = matrix.get('include', [])
    
    # Read raw YAML to check for escape hatches
    with open('$WORKFLOW_FILE', 'r') as raw_f:
        lines = raw_f.readlines()
    
    # Check each Ubuntu entry
    for idx, entry in enumerate(includes):
        if entry.get('os') == 'ubuntu-22.04':
            # Find the line number where this entry's os field appears
            entry_line_num = None
            for line_num, line in enumerate(lines, 1):
                if f"os: ubuntu-22.04" in line:
                    # Check if we've already processed this entry
                    if entry_line_num is None or line_num > entry_line_num + 10:
                        entry_line_num = line_num
                        # Check previous line for escape hatch
                        if line_num > 1:
                            prev_line = lines[line_num - 2].strip()
                            if "ssot-guardrail: allow-linux-crypto-policy-change" in prev_line:
                                # Extract reason from comment (required, non-empty, ≤120 chars, single-line)
                                reason_match = ""
                                if "(" in prev_line and ")" in prev_line:
                                    reason_start = prev_line.find("(") + 1
                                    reason_end = prev_line.find(")")
                                    reason_match = prev_line[reason_start:reason_end].strip()
                                
                                # Validate reason requirements
                                if not reason_match:
                                    print(f"ESCAPE_HATCH_INVALID|{line_num - 1}|Reason is required and must be non-empty")
                                elif len(reason_match) > 120:
                                    print(f"ESCAPE_HATCH_INVALID|{line_num - 1}|Reason exceeds 120 characters (got {len(reason_match)})")
                                elif "\n" in reason_match:
                                    print(f"ESCAPE_HATCH_INVALID|{line_num - 1}|Reason must be single-line")
                                else:
                                    print(f"ESCAPE_HATCH|{line_num - 1}|{reason_match}")
                                break
                        
                        # Check if SSOT_PURE_SWIFT_SHA256 is set correctly
                        if 'SSOT_PURE_SWIFT_SHA256' not in entry:
                            print(f"MISSING|{idx + 1}|SSOT_PURE_SWIFT_SHA256 not set")
                        elif entry.get('SSOT_PURE_SWIFT_SHA256') != "1":
                            print(f"INVALID|{idx + 1}|SSOT_PURE_SWIFT_SHA256='{entry.get('SSOT_PURE_SWIFT_SHA256')}' (must be '1')")
                        else:
                            print(f"VALID|{idx + 1}|SSOT_PURE_SWIFT_SHA256='1'")
                        break
    
    sys.exit(0)
except Exception as e:
    print(f"Error parsing workflow: {e}", file=sys.stderr)
    sys.exit(1)
PYTHON_EOF
)

# Process results
while IFS='|' read -r status idx detail; do
    case "$status" in
        ESCAPE_HATCH)
            ESCAPE_HATCHES=$((ESCAPE_HATCHES + 1))
            LINE_NUM=$(echo "$idx" | tr -d '[:space:]')
            REASON=$(echo "$detail" | tr -d '[:space:]')
            AUDIT_RECORDS+=("Line $LINE_NUM: Escape hatch used - Reason: $REASON")
            echo "  ⚠️  Escape hatch detected at line $LINE_NUM: $REASON"
            ;;
        MISSING)
            echo "  ❌ Ubuntu entry #$idx: $detail"
            ERRORS=$((ERRORS + 1))
            ;;
        INVALID)
            echo "  ❌ Ubuntu entry #$idx: $detail"
            ERRORS=$((ERRORS + 1))
            ;;
        VALID)
            echo "  ✅ Ubuntu entry #$idx: $detail"
            ;;
    esac
done <<< "$GATE2_SECTION"

# Check for escape hatches in raw file (more reliable method)
ESCAPE_HATCH_LINES=$(grep -n "ssot-guardrail: allow-linux-crypto-policy-change" "$WORKFLOW_FILE" 2>/dev/null || true)
if [ -n "$ESCAPE_HATCH_LINES" ]; then
    echo ""
    echo "=== Escape Hatch Audit ==="
    echo "$ESCAPE_HATCH_LINES" | while IFS=':' read -r line_num line_content; do
        # Extract reason from comment (validate requirements)
        REASON=$(echo "$line_content" | grep -oE "allow-linux-crypto-policy-change\([^)]*\)" | sed 's/allow-linux-crypto-policy-change(//;s/)//' | tr -d '\n' || echo "")
        if [ -z "$REASON" ]; then
            echo "  ❌ Line $line_num: Escape hatch reason is required and must be non-empty"
            ERRORS=$((ERRORS + 1))
        elif [ ${#REASON} -gt 120 ]; then
            echo "  ❌ Line $line_num: Escape hatch reason exceeds 120 characters (got ${#REASON})"
            ERRORS=$((ERRORS + 1))
        else
            echo "  Line $line_num: Escape hatch used - Reason: $REASON"
            AUDIT_RECORDS+=("Line $line_num: Escape hatch used - Reason: $REASON")
        fi
    done
    
    # Check commit message for required trailer
    if [ -d ".git" ]; then
        COMMIT_MSG=$(git log -1 --pretty=%B 2>/dev/null || echo "")
        if ! echo "$COMMIT_MSG" | grep -q "Crypto-Policy-Change: yes"; then
            echo ""
            echo "❌ Escape hatch used but commit message missing required trailer"
            echo "   Required: Crypto-Policy-Change: yes"
            echo "   Current commit message:"
            echo "$COMMIT_MSG" | head -5 | sed 's/^/      /'
            ERRORS=$((ERRORS + 1))
        else
            echo "  ✅ Commit message contains required trailer: Crypto-Policy-Change: yes"
        fi
    fi
fi

echo ""

if [ $ERRORS -eq 0 ]; then
    if [ $ESCAPE_HATCHES -gt 0 ]; then
        echo "✅ Policy validation passed (with $ESCAPE_HATCHES escape hatch(es) - audited)"
    else
        echo "✅ Policy validation passed (no escape hatches)"
    fi
    exit 0
else
    echo "❌ Policy validation failed ($ERRORS error(s))"
    echo ""
    echo "Policy: Linux Gate 2 matrix entries must explicitly set SSOT_PURE_SWIFT_SHA256=\"1\""
    echo "Escape hatch: Add '# ssot-guardrail: allow-linux-crypto-policy-change(<reason>)' before the entry"
    echo "Escape hatch requires: Commit message must contain 'Crypto-Policy-Change: yes'"
    exit 1
fi
