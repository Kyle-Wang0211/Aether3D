#!/bin/bash
# validate_workflow_bash_syntax.sh
# Validates bash syntax of all 'run:' blocks in GitHub Actions workflows
# Prevents shell syntax errors like "unexpected end of file" from reaching CI

set -euo pipefail

WORKFLOW_FILE="${1:-}"
if [ -z "$WORKFLOW_FILE" ]; then
    echo "Usage: validate_workflow_bash_syntax.sh <workflow_file>"
    exit 1
fi

# Determine repo root
if [ -f "$WORKFLOW_FILE" ]; then
    REPO_ROOT=$(cd "$(dirname "$WORKFLOW_FILE")/../.." && pwd)
else
    REPO_ROOT=$(git rev-parse --show-toplevel 2>/dev/null || pwd)
fi

cd "$REPO_ROOT" || exit 1

if [ ! -f "$WORKFLOW_FILE" ]; then
    echo "❌ Workflow file not found: $WORKFLOW_FILE"
    exit 1
fi

if ! command -v python3 >/dev/null 2>&1; then
    echo "⚠️  python3 not available, skipping bash syntax validation"
    exit 0
fi

if ! python3 -c "import yaml" 2>/dev/null; then
    echo "⚠️  python3-yaml not available, skipping bash syntax validation"
    exit 0
fi

WORKFLOW_NAME=$(basename "$WORKFLOW_FILE" .yml | sed 's/\.yaml$//')
ERRORS=0
TEMP_DIR=$(mktemp -d)
trap "rm -rf $TEMP_DIR" EXIT

echo "🔍 Validating bash syntax in workflow: $WORKFLOW_NAME"
echo ""

# Parse YAML and extract run blocks
python3 <<PYTHON_EOF
import yaml
import sys
import os
import subprocess

errors = False

try:
    with open('$WORKFLOW_FILE', 'r') as f:
        workflow = yaml.safe_load(f)
    
    if not workflow or 'jobs' not in workflow:
        print("⚠️  No jobs found in workflow")
        sys.exit(0)
    
    for job_id, job_config in workflow.get('jobs', {}).items():
        if 'steps' not in job_config:
            continue
        
        for step_idx, step in enumerate(job_config['steps']):
            if 'run' not in step:
                continue
            
            step_name = step.get('name', f'step_{step_idx}')
            run_content = step['run']
            
            # Skip if shell is explicitly set to non-bash
            shell = step.get('shell', 'bash')
            if shell and 'bash' not in shell.lower():
                continue
            
            # Replace GitHub Actions expressions with placeholders to avoid bash parse errors
            # We only want to validate bash syntax, not GitHub expression syntax
            sanitized = run_content.replace('\${{', '__GH_EXPR_START__').replace('}}', '__GH_EXPR_END__')
            
            # Check if run block already starts with set -euo pipefail
            has_set_euo = sanitized.strip().startswith('set -euo pipefail')
            
            # FAIL if missing set -euo pipefail (hard requirement)
            if not has_set_euo:
                print(f"❌ Job '{job_id}', step '{step_name}': Missing 'set -euo pipefail'")
                print(f"   Workflow: $WORKFLOW_FILE")
                print(f"   Fix: Add 'set -euo pipefail' as the first line of the run block")
                # Show first ~20 lines of the run block
                lines = sanitized.split('\n')[:20]
                print(f"   Run block preview:")
                for i, line in enumerate(lines, 1):
                    print(f"      {i}: {line}")
                total_lines = len(sanitized.split('\n'))
                if total_lines > 20:
                    remaining = total_lines - 20
                    print(f"      ... ({remaining} more lines)")
                errors = True
                continue
            
            # Write to temp file for syntax validation
            temp_file = f'$TEMP_DIR/{job_id}_{step_idx}.sh'
            with open(temp_file, 'w') as tf:
                tf.write(sanitized)
                tf.write('\n')
            
            # Run bash -n (syntax check only)
            result = subprocess.run(['bash', '-n', temp_file], capture_output=True, text=True)
            
            if result.returncode != 0:
                print(f"❌ Job '{job_id}', step '{step_name}': Bash syntax error")
                print(f"   Workflow: $WORKFLOW_FILE")
                print(f"   Error: {result.stderr.strip()}")
                # Show first ~20 lines of the run block
                lines = sanitized.split('\n')[:20]
                print(f"   Run block preview:")
                for i, line in enumerate(lines, 1):
                    print(f"      {i}: {line}")
                total_lines = len(sanitized.split('\n'))
                if total_lines > 20:
                    remaining = total_lines - 20
                    print(f"      ... ({remaining} more lines)")
                errors = True
            else:
                print(f"   ✅ Job '{job_id}', step '{step_name}': Bash syntax valid")
    
    if errors:
        print("")
        print("❌ Found bash syntax error(s) or missing 'set -euo pipefail' in workflow run blocks")
        sys.exit(1)
    else:
        print("")
        print("✅ All bash syntax checks passed")
        sys.exit(0)
except Exception as e:
    print(f"❌ Error parsing workflow: {e}")
    sys.exit(1)
PYTHON_EOF

EXIT_CODE=$?
exit $EXIT_CODE
