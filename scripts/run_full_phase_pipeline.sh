#!/bin/bash
#
# Run full phase pipeline with hard-stop semantics.
# Usage:
#   ./scripts/run_full_phase_pipeline.sh [extra args...]
# Example:
#   ./scripts/run_full_phase_pipeline.sh --from-phase 0 --to-phase 15 --enforce-deliverables
#

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
cd "$REPO_ROOT"

python3 -u governance/scripts/run_full_phase_pipeline.py "$@"
