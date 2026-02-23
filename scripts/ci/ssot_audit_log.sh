#!/usr/bin/env bash
set -euo pipefail

# SSOT Audit Log Generator
# Creates machine-readable audit log of SSOT changes
# Only runs in CI environment

echo "==> SSOT Audit Log Generation"

# Only run in CI
if [[ -z "${CI:-}" ]]; then
  echo "SSOT audit log only runs in CI"
  exit 0
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
cd "$REPO_ROOT"

AUDIT_LOG="$REPO_ROOT/.ssot_audit.jsonl"

BASE_REF="${GITHUB_BASE_REF:-main}"
COMMIT_SHA="${GITHUB_SHA:-$(git rev-parse HEAD 2>/dev/null || echo "unknown")}"
PR_NUMBER="${GITHUB_PR_NUMBER:-${GITHUB_EVENT_PULL_REQUEST_NUMBER:-none}}"
ACTOR="${GITHUB_ACTOR:-unknown}"
TIMESTAMP=$(date -u +"%Y-%m-%dT%H:%M:%SZ")

# Get SSOT changes
SSOT_CHANGES=$(git diff --name-only "origin/$BASE_REF"...HEAD -- \
  Core/Constants/ \
  Core/SSOT/ \
  docs/constitution/ \
  .github/workflows/ \
  scripts/ci/ \
  scripts/hooks/ \
  2>/dev/null || true)

if [[ -n "$SSOT_CHANGES" ]]; then
  # Create audit entry (simplified JSON without jq dependency)
  # Format: {"timestamp":"...","commit":"...","pr":"...","actor":"...","ssot_files":["..."]}
  
  # Convert file list to JSON array format
  FILES_JSON="["
  FIRST=true
  while IFS= read -r f; do
    [[ -z "$f" ]] && continue
    if [[ "$FIRST" == "true" ]]; then
      FIRST=false
    else
      FILES_JSON="$FILES_JSON,"
    fi
    FILES_JSON="$FILES_JSON\"$f\""
  done <<< "$SSOT_CHANGES"
  FILES_JSON="$FILES_JSON]"
  
  # Create entry
  ENTRY="{\"timestamp\":\"$TIMESTAMP\",\"commit\":\"$COMMIT_SHA\",\"pr\":\"$PR_NUMBER\",\"actor\":\"$ACTOR\",\"ssot_files\":$FILES_JSON}"
  
  echo "$ENTRY" >> "$AUDIT_LOG"
  echo "SSOT audit log entry created"
  echo "Entry: $ENTRY"
else
  echo "No SSOT changes detected, skipping audit log entry"
fi

exit 0
