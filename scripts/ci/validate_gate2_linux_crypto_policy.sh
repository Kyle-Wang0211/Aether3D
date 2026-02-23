#!/bin/bash
# validate_gate2_linux_crypto_policy.sh
# Validates that Linux Gate 2 explicitly sets SSOT_PURE_SWIFT_SHA256="1" (closed-world policy)
# Includes escape hatch with audit logging

set -euo pipefail

WORKFLOW_FILE="${1:-.github/workflows/ssot-foundation-ci.yml}"

if [ ! -f "$WORKFLOW_FILE" ]; then
    # SSOT Foundation workflow removed - exit gracefully
    exit 0
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
import os

try:
    workflow_file = '$WORKFLOW_FILE'
    with open(workflow_file, 'r') as f:
        workflow = yaml.safe_load(f)
    
    # Find Linux Gate 2 job (telemetry in WHITEBOX mode)
    # Read mode from SSOT_MODE.json
    import json
    try:
        with open('docs/constitution/SSOT_MODE.json', 'r') as f:
            mode_data = json.load(f)
        merge_mode = mode_data.get('mode', 'WHITEBOX')
    except:
        merge_mode = os.environ.get('SSOT_MERGE_CONTRACT_MODE', 'WHITEBOX')
    jobs = workflow.get('jobs', {})
    if merge_mode == 'PRODUCTION':
        gate2_job_id = 'gate_2_determinism_trust_linux_self_hosted'
    else:
        gate2_job_id = 'gate_2_determinism_trust_linux_telemetry'
    gate2_job = jobs.get(gate2_job_id, {})
    
    if not gate2_job:
        print(f"{gate2_job_id} job not found", file=sys.stderr)
        sys.exit(1)
    
    # Get job-level env (Linux Gate 2 uses direct env, not matrix)
    job_env = gate2_job.get('env', {})
    
    # Read raw YAML to check for escape hatches
    with open(workflow_file, 'r') as raw_f:
        lines = raw_f.readlines()
    
    # Check job-level env for SSOT_PURE_SWIFT_SHA256
    if 'SSOT_PURE_SWIFT_SHA256' not in job_env:
        print("MISSING|1|SSOT_PURE_SWIFT_SHA256 not set in job env")
    elif job_env.get('SSOT_PURE_SWIFT_SHA256') != "1":
        print(f"INVALID|1|SSOT_PURE_SWIFT_SHA256='{job_env.get('SSOT_PURE_SWIFT_SHA256')}' (must be '1')")
    else:
        print("VALID|1|SSOT_PURE_SWIFT_SHA256='1'")
    
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
            echo "  ❌ Blocking Linux Gate 2: $detail"
            ERRORS=$((ERRORS + 1))
            ;;
        INVALID)
            echo "  ❌ Blocking Linux Gate 2: $detail"
            ERRORS=$((ERRORS + 1))
            ;;
        VALID)
            echo "  ✅ Blocking Linux Gate 2: $detail"
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
    echo "Policy: Blocking Linux Gate 2 job must explicitly set SSOT_PURE_SWIFT_SHA256=\"1\" in job env"
    echo "Escape hatch: Add '# ssot-guardrail: allow-linux-crypto-policy-change(<reason>)' before the entry"
    echo "Escape hatch requires: Commit message must contain 'Crypto-Policy-Change: yes'"
    exit 1
fi
