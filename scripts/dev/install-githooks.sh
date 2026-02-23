#!/usr/bin/env bash
set -euo pipefail

ROOT="$(git rev-parse --show-toplevel)"
cd "$ROOT"

git config core.hooksPath .githooks
echo "✅ Installed githooks via core.hooksPath=.githooks"
echo "   pre-push will now enforce: scripts/ci/piz_local_gate.sh"
