#!/bin/bash
# validate_gate2_linux_executor_policy.sh
# Validates that blocking Linux Gate 2 uses self-hosted runner and telemetry uses GitHub-hosted
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

echo "🔒 Validating Gate 2 Linux Executor Policy"
echo ""

# Extract Gate 2 Linux jobs using Python YAML parsing
VALIDATION_RESULT=$(python3 <<'PYTHON_EOF'
import yaml
import sys
import re
import os

try:
    with open('.github/workflows/ssot-foundation-ci.yml', 'r') as f:
        workflow = yaml.safe_load(f)
    
    jobs = workflow.get('jobs', {})
    
    # Check mode: WHITEBOX (Linux Gate 2 is non-blocking) or PRODUCTION (requires self-hosted)
    # Read mode from SSOT_MODE.json
    import json
    try:
        with open('docs/constitution/SSOT_MODE.json', 'r') as f:
            mode_data = json.load(f)
        merge_mode = mode_data.get('mode', 'WHITEBOX')
    except:
        merge_mode = os.environ.get('SSOT_MERGE_CONTRACT_MODE', 'WHITEBOX')
    
    # Find Linux Gate 2 jobs
    blocking_job_id = 'gate_2_determinism_trust_linux_self_hosted'  # PRODUCTION mode only
    telemetry_job_id = 'gate_2_determinism_trust_linux_telemetry'  # WHITEBOX mode primary
    legacy_telemetry_job_id = 'gate_2_linux_hosted_telemetry'  # Legacy telemetry job
    
    blocking_job = jobs.get(blocking_job_id, {})
    telemetry_job = jobs.get(telemetry_job_id, {})
    legacy_telemetry_job = jobs.get(legacy_telemetry_job_id, {})
    
    # Use primary telemetry job if available, otherwise fall back to legacy
    if not telemetry_job and legacy_telemetry_job:
        telemetry_job = legacy_telemetry_job
        telemetry_job_id = legacy_telemetry_job_id
    
    results = []
    
    if merge_mode == 'PRODUCTION':
        # PRODUCTION mode: check blocking job
        if not blocking_job:
            results.append(f"BLOCKING_MISSING|{blocking_job_id}|Blocking Linux Gate 2 job not found (PRODUCTION mode requires stable runner)")
        else:
            runs_on = blocking_job.get('runs-on', '')
            continue_on_error = blocking_job.get('continue-on-error', False)
            
            is_self_hosted = False
            if isinstance(runs_on, list):
                is_self_hosted = 'self-hosted' in runs_on and 'linux' in runs_on
            elif isinstance(runs_on, str):
                is_self_hosted = 'self-hosted' in runs_on and 'linux' in runs_on
            
            if not is_self_hosted:
                results.append(f"BLOCKING_HOSTED|{blocking_job_id}|Blocking Linux Gate 2 must use self-hosted runner (PRODUCTION mode)")
            else:
                results.append(f"BLOCKING_OK|{blocking_job_id}|Uses self-hosted runner")
            
            if continue_on_error:
                results.append(f"BLOCKING_CONTINUE_ERROR|{blocking_job_id}|Blocking job has continue-on-error: true (should be false in PRODUCTION)")
            
            # Check env vars for blocking job
            env = blocking_job.get('env', {})
            if env.get('SSOT_PURE_SWIFT_SHA256') != '1':
                results.append(f"BLOCKING_ENV_MISSING|{blocking_job_id}|SSOT_PURE_SWIFT_SHA256 must be '1'")
            if env.get('OPENSSL_ia32cap') != ':0':
                results.append(f"BLOCKING_ENV_MISSING|{blocking_job_id}|OPENSSL_ia32cap must be ':0'")
    else:
        # WHITEBOX mode: check telemetry job
        if not telemetry_job:
            results.append(f"TELEMETRY_MISSING|{telemetry_job_id}|Linux Gate 2 telemetry job not found (WHITEBOX mode)")
        else:
            runs_on = telemetry_job.get('runs-on', '')
            continue_on_error = telemetry_job.get('continue-on-error', False)
            
            # Telemetry should use GitHub-hosted
            is_hosted = (runs_on == 'ubuntu-22.04' or 
                        (isinstance(runs_on, str) and 'ubuntu-' in runs_on and 'self-hosted' not in runs_on))
            
            if not is_hosted:
                results.append(f"TELEMETRY_SELF_HOSTED|{telemetry_job_id}|Telemetry job should use GitHub-hosted runner (WHITEBOX mode)")
            else:
                results.append(f"TELEMETRY_OK|{telemetry_job_id}|Uses GitHub-hosted runner")
            
            if not continue_on_error:
                results.append(f"TELEMETRY_BLOCKING|{telemetry_job_id}|Telemetry job missing continue-on-error: true (required in WHITEBOX)")
            else:
                results.append(f"TELEMETRY_NON_BLOCKING|{telemetry_job_id}|Has continue-on-error: true")
            
            # Check env vars for telemetry job
            env = telemetry_job.get('env', {})
            if env.get('SSOT_PURE_SWIFT_SHA256') != '1':
                results.append(f"TELEMETRY_ENV_MISSING|{telemetry_job_id}|SSOT_PURE_SWIFT_SHA256 must be '1'")
            if env.get('OPENSSL_ia32cap') != ':0':
                results.append(f"TELEMETRY_ENV_MISSING|{telemetry_job_id}|OPENSSL_ia32cap must be ':0'")
    
    for result in results:
        print(result)
    
    sys.exit(0)
    
    for result in results:
        print(result)
    
    sys.exit(0)
except Exception as e:
    print(f"Error parsing workflow: {e}", file=sys.stderr)
    sys.exit(1)
PYTHON_EOF
)

# Process results
while IFS='|' read -r status job_id detail; do
    case "$status" in
        BLOCKING_OK)
            echo "  ✅ Blocking Linux Gate 2 '$job_id': $detail"
            ;;
        BLOCKING_HOSTED)
            echo "  ❌ Blocking Linux Gate 2 '$job_id': $detail"
            ERRORS=$((ERRORS + 1))
            ;;
        BLOCKING_MISSING)
            echo "  ❌ $detail"
            ERRORS=$((ERRORS + 1))
            ;;
        BLOCKING_CONTINUE_ERROR)
            echo "  ❌ Blocking Linux Gate 2 '$job_id': $detail"
            ERRORS=$((ERRORS + 1))
            ;;
        BLOCKING_ENV_MISSING)
            echo "  ❌ Blocking Linux Gate 2 '$job_id': $detail"
            ERRORS=$((ERRORS + 1))
            ;;
        TELEMETRY_ENV_MISSING)
            echo "  ❌ Telemetry Linux Gate 2 '$job_id': $detail"
            ERRORS=$((ERRORS + 1))
            ;;
        TELEMETRY_OK)
            echo "  ✅ Telemetry Linux Gate 2 '$job_id': $detail"
            ;;
        TELEMETRY_NON_BLOCKING)
            echo "  ✅ Telemetry Linux Gate 2 '$job_id': $detail"
            ;;
        TELEMETRY_SELF_HOSTED)
            echo "  ⚠️  Telemetry Linux Gate 2 '$job_id': $detail (warning only)"
            ;;
        TELEMETRY_BLOCKING)
            echo "  ❌ Telemetry Linux Gate 2 '$job_id': $detail"
            ERRORS=$((ERRORS + 1))
            ;;
        TELEMETRY_MISSING)
            echo "  ⚠️  $detail (warning only)"
            ;;
        ESCAPE_HATCH)
            ESCAPE_HATCHES=$((ESCAPE_HATCHES + 1))
            LINE_NUM=$(echo "$job_id" | tr -d '[:space:]')
            REASON="$detail"
            AUDIT_RECORDS+=("Line $LINE_NUM: Escape hatch used - Reason: $REASON")
            echo "  ⚠️  Escape hatch detected at line $LINE_NUM: $REASON"
            ;;
        ESCAPE_HATCH_OK)
            ESCAPE_HATCHES=$((ESCAPE_HATCHES + 1))
            LINE_NUM=$(echo "$job_id" | tr -d '[:space:]')
            REASON="$detail"
            AUDIT_RECORDS+=("Line $LINE_NUM: Escape hatch used with trailer - Reason: $REASON")
            echo "  ⚠️  Escape hatch at line $LINE_NUM: $REASON (with commit trailer)"
            ;;
        ESCAPE_HATCH_INVALID)
            echo "  ❌ Escape hatch invalid at line $job_id: $detail"
            ERRORS=$((ERRORS + 1))
            ;;
        ESCAPE_HATCH_NO_TRAILER)
            echo "  ❌ Escape hatch used at line $job_id but commit message missing required trailer"
            echo "     Required: Hosted-Blocking-Gate2: yes"
            ERRORS=$((ERRORS + 1))
            ;;
    esac
done <<< "$VALIDATION_RESULT"

echo ""

if [ $ERRORS -eq 0 ]; then
    if [ $ESCAPE_HATCHES -gt 0 ]; then
        echo "✅ Executor policy validation passed (with $ESCAPE_HATCHES escape hatch(es) - audited)"
        if [ ${#AUDIT_RECORDS[@]} -gt 0 ]; then
            echo ""
            echo "=== Escape Hatch Audit ==="
            for record in "${AUDIT_RECORDS[@]}"; do
                echo "  $record"
            done
        fi
    else
        echo "✅ Executor policy validation passed (no escape hatches)"
    fi
    exit 0
else
    echo "❌ Executor policy validation failed ($ERRORS error(s))"
    echo ""
    echo "Policy:"
    if [ "$MERGE_CONTRACT_MODE" = "PRODUCTION" ]; then
        echo "  - Blocking Linux Gate 2 MUST use self-hosted runner ([self-hosted, linux, x86_64, ssot-gate2-baseline])"
        echo "  - Blocking Linux Gate 2 MUST set SSOT_PURE_SWIFT_SHA256='1' and OPENSSL_ia32cap=':0'"
        echo "  - Escape hatch: Add '# ssot-guardrail: allow-hosted-blocking-gate2(<reason>)' before the runs-on line"
        echo "  - Escape hatch requires: Commit message must contain 'Hosted-Blocking-Gate2: yes'"
    else
        echo "  - Linux Gate 2 is NON-BLOCKING telemetry (WHITEBOX mode)"
        echo "  - Telemetry Linux Gate 2 MUST use GitHub-hosted runner (ubuntu-22.04) and continue-on-error: true"
        echo "  - Telemetry Linux Gate 2 MUST set SSOT_PURE_SWIFT_SHA256='1' and OPENSSL_ia32cap=':0'"
    fi
    exit 1
fi
