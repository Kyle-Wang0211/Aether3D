#!/bin/bash
# validate_runner_pinning.sh
# Ensures gates use pinned runners (not ubuntu-latest, macos-latest)

set -euo pipefail

WORKFLOW_FILE="${1:-.github/workflows/ssot-foundation-ci.yml}"

if [ ! -f "$WORKFLOW_FILE" ]; then
    echo "❌ Workflow file not found: $WORKFLOW_FILE"
    exit 1
fi

ERRORS=0

echo "🔒 Validating Runner Pinning"
echo ""

# Extract job runner specifications
RUNNER_SPECS=$(python3 <<'PYTHON_EOF'
import yaml
import sys

try:
    with open('.github/workflows/ssot-foundation-ci.yml', 'r') as f:
        workflow = yaml.safe_load(f)
    
    jobs = workflow.get('jobs', {})
    
    results = []
    
    for job_id, job_def in jobs.items():
        runs_on = job_def.get('runs-on', '')
        job_name = job_def.get('name', job_id)
        
        # Check if job is a gate (blocking)
        is_gate = 'gate' in job_id.lower() or 'gate' in job_name.lower()
        
        # Check if this is blocking Gate 2 Linux (must use self-hosted in PRODUCTION mode)
        # In WHITEBOX mode, Linux Gate 2 is non-blocking telemetry
        # Read mode from SSOT_MODE.json
        import json
        try:
            with open('docs/constitution/SSOT_MODE.json', 'r') as f:
                mode_data = json.load(f)
            merge_mode = mode_data.get('mode', 'WHITEBOX')
        except:
            merge_mode = os.environ.get('SSOT_MERGE_CONTRACT_MODE', 'WHITEBOX')
        is_blocking_gate2_linux = False
        if merge_mode == 'PRODUCTION':
            is_blocking_gate2_linux = (job_id == 'gate_2_determinism_trust_linux_self_hosted' or
                                       (job_id == 'gate_2_determinism_trust' and 
                                        'linux' in job_name.lower() and 'self-hosted' in job_name.lower()))
        
        if is_gate:
            # Blocking Gate 2 Linux must use self-hosted runner
            if is_blocking_gate2_linux:
                # Check if runs_on is a matrix reference
                if '${{' in str(runs_on):
                    # Check matrix entries for self-hosted Linux
                    strategy = job_def.get('strategy', {})
                    matrix = strategy.get('matrix', {})
                    includes = matrix.get('include', [])
                    has_self_hosted_linux = False
                    has_hosted_ubuntu = False
                    for entry in includes:
                        entry_runs_on = entry.get('runs_on', entry.get('os', ''))
                        if isinstance(entry_runs_on, list):
                            if 'self-hosted' in entry_runs_on and 'linux' in entry_runs_on:
                                has_self_hosted_linux = True
                            if 'ubuntu-22.04' in entry_runs_on or entry_runs_on == 'ubuntu-22.04':
                                has_hosted_ubuntu = True
                        elif isinstance(entry_runs_on, str):
                            if 'self-hosted' in entry_runs_on and 'linux' in entry_runs_on:
                                has_self_hosted_linux = True
                            if entry_runs_on == 'ubuntu-22.04':
                                has_hosted_ubuntu = True
                    
                    if has_hosted_ubuntu and not has_self_hosted_linux:
                        results.append(f"GATE2_LINUX_HOSTED|{job_id}|Blocking Gate 2 Linux must use self-hosted runner")
                    elif has_self_hosted_linux:
                        results.append(f"GATE_PINNED|{job_id}|{runs_on} (self-hosted Linux)")
                    else:
                        results.append(f"GATE_MATRIX_RUNNER|{job_id}|{runs_on}")
                else:
                    # Direct runner specification
                    if isinstance(runs_on, list):
                        if 'self-hosted' in runs_on and 'linux' in runs_on:
                            results.append(f"GATE_PINNED|{job_id}|{runs_on}")
                        elif 'ubuntu-22.04' in runs_on or runs_on == 'ubuntu-22.04':
                            results.append(f"GATE2_LINUX_HOSTED|{job_id}|Blocking Gate 2 Linux must use self-hosted runner")
                        else:
                            results.append(f"GATE_PINNED|{job_id}|{runs_on}")
                    elif runs_on == 'ubuntu-latest' or runs_on == 'macos-latest':
                        results.append(f"GATE_UNPINNED|{job_id}|{runs_on}")
                    elif 'ubuntu-' in str(runs_on) or 'macos-' in str(runs_on):
                        if runs_on == 'ubuntu-22.04' and is_blocking_gate2_linux:
                            results.append(f"GATE2_LINUX_HOSTED|{job_id}|Blocking Gate 2 Linux must use self-hosted runner")
                        else:
                            results.append(f"GATE_PINNED|{job_id}|{runs_on}")
                    else:
                        results.append(f"GATE_PINNED|{job_id}|{runs_on}")
            else:
                # Other gates: standard pinning check
                if runs_on == 'ubuntu-latest' or runs_on == 'macos-latest':
                    results.append(f"GATE_UNPINNED|{job_id}|{runs_on}")
                elif 'ubuntu-' in str(runs_on) or 'macos-' in str(runs_on):
                    if '${{' in str(runs_on):
                        results.append(f"GATE_MATRIX_RUNNER|{job_id}|{runs_on}")
                    else:
                        results.append(f"GATE_PINNED|{job_id}|{runs_on}")
                else:
                    results.append(f"GATE_PINNED|{job_id}|{runs_on}")
    
    for result in results:
        print(result)
    
    sys.exit(0)
except Exception as e:
    print(f"Error parsing workflow: {e}", file=sys.stderr)
    sys.exit(1)
PYTHON_EOF
)

# Process results
while IFS='|' read -r status job_id runs_on; do
    case "$status" in
        GATE_PINNED)
            echo "  ✅ Gate '$job_id': Uses pinned runner ($runs_on)"
            ;;
        GATE_MATRIX_RUNNER)
            echo "  ✅ Gate '$job_id': Uses matrix runner ($runs_on) - check matrix values are pinned"
            ;;
        GATE_UNPINNED)
            echo "  ❌ Gate '$job_id': Uses unpinned runner ($runs_on)"
            ERRORS=$((ERRORS + 1))
            ;;
    esac
done <<< "$RUNNER_SPECS"

echo ""

if [ $ERRORS -eq 0 ]; then
    echo "✅ Runner pinning validation passed"
    exit 0
else
    echo "❌ Runner pinning validation failed ($ERRORS error(s))"
    echo ""
    echo "Policy:"
    echo "  - Blocking gates must use pinned runners (ubuntu-22.04, macos-14, not ubuntu-latest)"
    echo "  - Blocking Gate 2 Linux must use self-hosted runner ([self-hosted, linux, x86_64, ssot-gate2])"
    echo "  - GitHub-hosted ubuntu-22.04 is forbidden for blocking Gate 2 Linux"
    echo ""
    echo "Escape hatch: Add '# ssot-guardrail: allow-hosted-blocking-gate2(<reason>)' before the entry"
    echo "Escape hatch requires: Commit message must contain 'Hosted-Blocking-Gate2: yes'"
    exit 1
fi
