#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$ROOT_DIR"

python3 governance/scripts/validate_governance.py --report governance/generated/governance_diagnostics.json
python3 governance/scripts/generate_cursor_runbooks.py --output governance/generated/phases
python3 governance/scripts/generate_cursor_runbooks.py --check --output governance/generated/phases

echo "governance-pipeline: completed"
