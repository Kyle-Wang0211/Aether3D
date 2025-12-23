#!/usr/bin/env bash
# Preflight Check Script
# Phase 0.5-3: Local checks before commit
# Read-only checks: does NOT modify files.

set -euo pipefail

# Colors
RED=$'\033[0;31m'
GREEN=$'\033[0;32m'
YELLOW=$'\033[0;33m'
BLUE=$'\033[0;34m'
NC=$'\033[0m'

hr() { echo "------------------------------------------"; }

echo "=========================================="
echo "  Preflight Check (Phase 0.5-3)"
echo "=========================================="
echo

# 1) Git Status (warn only)
echo -e "${BLUE}1. Git Status${NC}"
hr
if [[ -n "$(git status --porcelain 2>/dev/null || true)" ]]; then
  echo -e "${YELLOW}⚠️  Working tree is not clean:${NC}"
  git status --short 2>/dev/null || true
else
  echo -e "${GREEN}✅ Working tree clean${NC}"
fi
echo

# 2) Branch & recent commits
echo -e "${BLUE}2. Branch & Recent Commits${NC}"
hr
CURRENT_BRANCH="$(git branch --show-current 2>/dev/null || echo 'detached')"
echo "Current branch: ${CURRENT_BRANCH}"
git log --oneline -n 5 2>/dev/null || true
echo

# 3) Phase 0 tag check
echo -e "${BLUE}3. Phase 0 Tag${NC}"
hr
if git rev-parse -q --verify "refs/tags/phase0" >/dev/null 2>&1; then
  echo -e "${GREEN}✅ Tag 'phase0' exists${NC}"
  echo "phase0 commit -> $(git rev-list -n 1 phase0)"
else
  echo -e "${RED}❌ Tag 'phase0' NOT found${NC}"
  exit 1
fi
echo

# 4) TODO/FIXME/XXX scan (warn only)
echo -e "${BLUE}4. TODO/FIXME/XXX Check (Swift/Metal)${NC}"
hr
found=0
dirs=(App Core Features)
for d in "${dirs[@]}"; do
  [[ -d "$d" ]] || continue
  while IFS= read -r -d '' file; do
    matches="$(grep -nE 'TODO|FIXME|XXX' "$file" 2>/dev/null || true)"
    if [[ -n "$matches" ]]; then
      echo "$file:"
      echo "$matches" | sed 's/^/  /'
      found=1
    fi
  done < <(find "$d" -type f \( -name '*.swift' -o -name '*.metal' \) -print0 2>/dev/null || true)
done
if [[ $found -eq 0 ]]; then
  echo -e "${GREEN}✅ No TODO/FIXME/XXX found${NC}"
else
  echo -e "${YELLOW}⚠️  TODO/FIXME/XXX found (review before PR)${NC}"
fi
echo

# 5) Empty files check (warn  -e "${BLUE}5. Empty Files Check${NC}"
hr
empty=0
scan_dirs=(docs scripts)
for d in "${scan_dirs[@]}"; do
  [[ -d "$d" ]] || continue
  while IFS= read -r -d '' file; do
    # ignore common junk
    [[ "$file" == *".DS_Store"* ]] && continue
    [[ "$file" == *"Assets.xcassets"* ]] && continue
    [[ "$file" == *".git"* ]] && continue

    if [[ ! -s "$file" ]]; then
      echo "Empty file: $file"
      empty=1
    fi
  done < <(find "$d" -type f -print0 2>/dev/null || true)
done
if [[ $empty -eq 0 ]]; then
  echo -e "${GREEN}✅ No empty files found${NC}"
else
  echo -e "${YELLOW}⚠️  Empty files found (confirm intentional)${NC}"
fi
echo

echo "=========================================="
echo "  Preflight Complete (read-only)"
echo "=========================================="
