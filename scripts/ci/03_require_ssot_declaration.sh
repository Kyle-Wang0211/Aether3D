#!/usr/bin/env bash
set -euo pipefail

# CI-HARDENED: SSOT declaration check using only git + grep.
# Zero external dependencies.

SSOT_PATH_PREFIXES=(
  "Core/Constants/"
  "docs/constitution/"
)

# Dependency check
if ! command -v git &> /dev/null; then
  echo "❌ Missing required command: git"
  echo "   git is required for SSOT declaration check. Install via system package manager."
  exit 1
fi

if ! command -v grep &> /dev/null; then
  echo "❌ Missing required command: grep"
  echo "   grep is required for SSOT declaration check. Install via system package manager."
  exit 1
fi

# Prefer staged changes; fall back to working tree.
changed="$(git diff --name-only --cached 2>/dev/null || true)"
if [[ -z "$changed" ]]; then
  changed="$(git diff --name-only 2>/dev/null || true)"
fi

needs_yes=0
while IFS= read -r f; do
  [[ -z "$f" ]] && continue
  for p in "${SSOT_PATH_PREFIXES[@]}"; do
    if [[ "$f" == "$p"* ]]; then
      needs_yes=1
      break
    fi
  done
  [[ "$needs_yes" -eq 1 ]] && break
done <<< "$changed"

TARGET_COMMIT="HEAD"
if git rev-parse -q --verify HEAD^2 >/dev/null 2>&1; then
  TARGET_COMMIT="$(git rev-parse HEAD^2)"
fi

msg="$(git log -1 --pretty=%B "$TARGET_COMMIT" 2>/dev/null || echo "")"

has_footer=0
if printf "%s\n" "$msg" | grep -Eq '^SSOT-Change: (yes|no)$'; then
  has_footer=1
fi

if [[ "$needs_yes" -eq 1 ]]; then
  if ! printf "%s\n" "$msg" | grep -Eq '^SSOT-Change: yes$'; then
    echo "❌ SSOT declaration check FAILED"
    echo "Touched SSOT paths (${SSOT_PATH_PREFIXES[*]}), but commit message lacks:"
    echo "  SSOT-Change: yes"
    echo ""
    echo "Fix:"
    echo "  git commit --amend"
    exit 1
  fi
else
  if [[ "$has_footer" -ne 1 ]]; then
    echo "❌ SSOT declaration check FAILED"
    echo "Commit message must include one footer line:"
    echo "  SSOT-Change: yes"
    echo "  or"
    echo "  SSOT-Change: no"
    echo ""
    echo "Fix:"
    echo "  git commit --amend"
    exit 1
  fi
fi

echo "==> require_ssot_declaration PASSED"
