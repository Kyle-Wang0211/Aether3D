#!/bin/bash
# validate_no_duplicate_steps_keys.sh
# Validates that each job has exactly one 'steps:' key
# Uses Python YAML parsing for accurate detection

set -euo pipefail

# If first arg is a file path, use it; otherwise use default
if [ -f "${1:-}" ]; then
    WORKFLOW_FILE="$1"
    REPO_ROOT="$(cd "$(dirname "$WORKFLOW_FILE")/../.." && pwd)"
else
    REPO_ROOT="${1:-$(git rev-parse --show-toplevel)}"
    WORKFLOW_FILE="${2:-$REPO_ROOT/.github/workflows/ssot-foundation-ci.yml}"
    
    # SSOT Foundation workflow removed - skip if file doesn't exist
    if [ ! -f "$WORKFLOW_FILE" ]; then
        exit 0
    fi
fi

cd "$REPO_ROOT" || exit 1

ERRORS=0

echo "🔍 Validating no duplicate 'steps:' keys in workflow"
echo ""

if [ ! -f "$WORKFLOW_FILE" ]; then
    echo "⚠️  Workflow file not found: $WORKFLOW_FILE"
    exit 0
fi

# Check if python3 is available
if ! command -v python3 >/dev/null 2>&1; then
    echo "⚠️  python3 not available, skipping duplicate steps validation"
    exit 0
fi

# Check if yaml module is available
if ! python3 -c "import yaml" 2>/dev/null; then
    echo "⚠️  python3-yaml not available, skipping duplicate steps validation"
    exit 0
fi

# Use Python to parse YAML and check for duplicate steps keys
python3 << PYTHON_EOF
import yaml
import sys
import re

workflow_file = "$WORKFLOW_FILE"

try:
    with open(workflow_file, 'r') as f:
        workflow = yaml.safe_load(f)
    
    if 'jobs' not in workflow:
        print("⚠️  No 'jobs' section found in workflow")
        sys.exit(0)
    
    errors = 0
    for job_name, job_config in workflow['jobs'].items():
        if not isinstance(job_config, dict):
            continue
        
        # Count 'steps' keys (YAML parser will merge duplicates, so we check the source)
        # Instead, we'll check if steps is a list (correct) or something else (wrong)
        steps_count = 0
        if 'steps' in job_config:
            if isinstance(job_config['steps'], list):
                steps_count = 1
            else:
                print(f"❌ Job '{job_name}': 'steps' is not a list (may indicate YAML key duplication)")
                errors += 1
        
        # Also check raw file for duplicate 'steps:' patterns within job scope
        # This is a heuristic but catches the common case
        with open(workflow_file, 'r') as f:
            lines = f.readlines()
        
        in_job = False
        job_indent_level = 0
        steps_keys_found = []
        
        for i, line in enumerate(lines, 1):
            stripped = line.lstrip()
            current_indent = len(line) - len(stripped)
            
            # Detect job start
            if f"{job_name}:" in line and ":" in line and not stripped.startswith("#"):
                in_job = True
                job_indent_level = current_indent
                steps_keys_found = []
            # Detect next job (same or less indentation, has colon, not a comment)
            elif in_job and current_indent <= job_indent_level and ":" in stripped and not stripped.startswith("#"):
                if i > 1:  # Not the first line
                    in_job = False
            # Count steps: keys within this job (must be at job's children level)
            elif in_job and "steps:" in stripped and stripped.startswith("steps:"):
                if current_indent > job_indent_level:
                    steps_keys_found.append(i)
        
        if len(steps_keys_found) > 1:
            print(f"❌ Job '{job_name}': Found {len(steps_keys_found)} 'steps:' keys at lines: {', '.join(map(str, steps_keys_found))}")
            print(f"   Fix: Merge all steps into a single 'steps:' key")
            errors += 1
    
    if errors == 0:
        print("✅ No duplicate 'steps:' keys found")
        sys.exit(0)
    else:
        print(f"\n❌ Found {errors} job(s) with duplicate 'steps:' keys")
        sys.exit(1)

except yaml.YAMLError as e:
    print(f"❌ YAML parse error: {e}")
    sys.exit(1)
except Exception as e:
    print(f"❌ Error: {e}")
    sys.exit(1)
PYTHON_EOF

EXIT_CODE=$?

if [ $EXIT_CODE -ne 0 ]; then
    ERRORS=$((ERRORS + 1))
fi

# Legacy grep-based fallback removed - Python YAML parsing is the single authoritative mechanism
# This ensures structural correctness and prevents fragile pattern matching

if [ $ERRORS -eq 0 ]; then
    exit 0
else
    exit 1
fi
