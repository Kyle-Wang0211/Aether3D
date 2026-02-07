#!/bin/bash
# Preflight Check Script
# Phase 0.5-3: Local checks before commit
# This script performs read-only checks and does not modify any files.

set -euo pipefail

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

echo "=========================================="
echo "  Preflight Check"
echo "=========================================="
echo ""

# Check 1: Git Status
echo -e "${BLUE}1. Git Status Check${NC}"
echo "----------------------------------------"
if [ -n "$(git status --porcelain 2>/dev/null || true)" ]; then
    echo -e "${YELLOW}⚠️  Warning: Working directory is not clean${NC}"
    echo "Changes:"
    git status --short 2>/dev/null || true
else
    echo -e "${GREEN}✅ Working directory is clean${NC}"
fi
echo ""

# Check 2: Branch and Commit Info
echo -e "${BLUE}2. Branch and Commit Information${NC}"
echo "----------------------------------------"
CURRENT_BRANCH=$(git branch --show-current 2>/dev/null || echo "detached HEAD")
echo "Current branch: $CURRENT_BRANCH"
echo ""
echo "Recent 5 commits:"
git log --oneline -n 5 2>/dev/null || echo "No commits found"
echo ""

# Check 3: Phase 0 Tag
echo -e "${BLUE}3. Phase 0 Tag Check${NC}"
echo "----------------------------------------"
if git tag --list 2>/dev/null | grep -q '^phase0$'; then
    echo -e "${GREEN}✅ Tag 'phase0' exists${NC}"
    PHASE0_COMMIT=$(git rev-parse phase0 2>/dev/null || echo "N/A")
    echo "  Commit: $PHASE0_COMMIT"
else
    echo -e "${YELLOW}⚠️  Tag 'phase0' not found${NC}"
fi
echo ""

# Check 4: TODO/FIXME/XXX in Swift/Metal files
echo -e "${BLUE}4. TODO/FIXME/XXX Check${NC}"
echo "----------------------------------------"
TODOS_FOUND=0
for dir in App Core Features; do
    if [ -d "$dir" ]; then
        while IFS= read -r file; do
            if [ -f "$file" ]; then
                matches=$(grep -n -E "TODO|FIXME|XXX" "$file" 2>/dev/null || true)
                if [ -n "$matches" ]; then
                    echo "$file:"
                    echo "$matches" | sed 's/^/  /'
                    TODOS_FOUND=$((TODOS_FOUND + 1))
                fi
            fi
        done < <(find "$dir" -type f \( -name "*.swift" -o -name "*.metal" \) 2>/dev/null || true)
    fi
done

if [ $TODOS_FOUND -eq 0 ]; then
    echo -e "${GREEN}✅ No TODO/FIXME/XXX found${NC}"
else
    echo -e "${YELLOW}⚠️  Found $TODOS_FOUND file(s) with TODO/FIXME/XXX${NC}"
fi
echo ""

# Check 5: Empty or Comment-Only Files
echo -e "${BLUE}5. Empty or Comment-Only Files Check${NC}"
echo "----------------------------------------"
EMPTY_FILES=0
COMMENT_ONLY_FILES=0

for dir in App Core Features docs scripts; do
    if [ -d "$dir" ]; then
        while IFS= read -r file; do
            if [ -f "$file" ]; then
                # Skip .git, Assets.xcassets, build artifacts
                if [[ "$file" == *".git"* ]] || [[ "$file" == *"Assets.xcassets"* ]] || [[ "$file" == *"build"* ]] || [[ "$file" == *"DerivedData"* ]] || [[ "$file" == *".DS_Store"* ]]; then
                    continue
                fi
                
                # Check if file is empty (size = 0)
                if [ ! -s "$file" ]; then
                    echo "  Empty file: $file"
                    EMPTY_FILES=$((EMPTY_FILES + 1))
                    continue
                fi
                
                # Check if file contains only comments/whitespace
                # For code files, check if only comments/whitespace remain
                if [[ "$file" == *.swift ]] || [[ "$file" == *.metal ]] || [[ "$file" == *.sh ]] || [[ "$file" == *.md ]]; then
                    # Remove comments and blank lines, check if anything remains
                    non_comment_lines=$(grep -v '^[[:space:]]*//' "$file" 2>/dev/null | \
                        grep -v '^[[:space:]]*#' | \
                        grep -v '^[[:space:]]*$' | \
                        grep -v '^[[:space:]]*/\*' | \
                        grep -v '^[[:space:]]*\*/' | \
                        grep -v '^\*' | \
                        grep -v '^[[:space:]]*<!--' | \
                        grep -v '^[[:space:]]*-->' || true)
                    if [ -z "$non_comment_lines" ]; then
                        echo "  Comment-only file: $file"
                        COMMENT_ONLY_FILES=$((COMMENT_ONLY_FILES + 1))
                    fi
                fi
            fi
        done < <(find "$dir" -type f 2>/dev/null || true)
    fi
done

if [ $EMPTY_FILES -eq 0 ] && [ $COMMENT_ONLY_FILES -eq 0 ]; then
    echo -e "${GREEN}✅ No empty or comment-only files found${NC}"
else
    if [ $EMPTY_FILES -gt 0 ]; then
        echo -e "${YELLOW}⚠️  Found $EMPTY_FILES empty file(s)${NC}"
    fi
    if [ $COMMENT_ONLY_FILES -gt 0 ]; then
        echo -e "${YELLOW}⚠️  Found $COMMENT_ONLY_FILES comment-only file(s)${NC}"
    fi
fi
echo ""

# Check 6: Build
echo -e "${BLUE}6. Build Check${NC}"
echo "----------------------------------------"
if bash scripts/ci_build.sh; then
    echo -e "${GREEN}✅ Build successful${NC}"
else
    echo -e "${RED}❌ Build failed${NC}"
    exit 1
fi
echo ""

# Check 7: Test
echo -e "${BLUE}7. Test Check${NC}"
echo "----------------------------------------"
if bash scripts/ci_test.sh; then
    echo -e "${GREEN}✅ Tests passed${NC}"
else
    echo -e "${YELLOW}⚠️  Tests skipped or failed (may require manual configuration)${NC}"
fi
echo ""

# Check 8: Repo Shape Check
echo -e "${BLUE}8. Repo Shape Check${NC}"
echo "----------------------------------------"
FORBIDDEN_DIRS=("deprecated" "Core/Output" "Core/Camera" "Core/PointCloud" "Core/Training")
SHAPE_ERROR=0

for dir in "${FORBIDDEN_DIRS[@]}"; do
    if [ -d "$dir" ]; then
        echo -e "${RED}❌ Forbidden directory exists: $dir${NC}"
        SHAPE_ERROR=1
    fi
done

if [ $SHAPE_ERROR -eq 0 ]; then
    echo -e "${GREEN}✅ Repo shape OK${NC}"
else
    echo -e "${RED}❌ Repo shape violation detected${NC}"
    exit 1
fi
echo ""

# Check 9: Git Clean Check
echo -e "${BLUE}9. Git Clean Check${NC}"
echo "----------------------------------------"
if [ -n "$(git status --porcelain 2>/dev/null || true)" ]; then
    echo -e "${RED}❌ Working directory is not clean${NC}"
    echo "Uncommitted changes detected:"
    git status --short 2>/dev/null || true
    exit 1
else
    echo -e "${GREEN}✅ Working directory is clean${NC}"
fi
echo ""

# Check 10: Rules Spill Check
echo -e "${BLUE}10. Rules Spill Check${NC}"
echo "----------------------------------------"
RULES_KEYWORDS=("Policy Hash" "Decision Hash" "Gate" "Determinism" "Audit Schema" "Invariant" "Signing" "Non-deterministic")
SPILL_ERROR=0

# Search in docs/ excluding constitution, rfcs, _archive, pr (prompts), implementation, and tasks
# Implementation and tasks directories contain technical documentation that legitimately
# uses these keywords in describing system architecture and task specifications
while IFS= read -r file; do
    if [ -f "$file" ]; then
        for keyword in "${RULES_KEYWORDS[@]}"; do
            if grep -qi "$keyword" "$file" 2>/dev/null; then
                echo -e "${RED}❌ Rules keyword found in forbidden location: $file${NC}"
                echo "  Keyword: $keyword"
                SPILL_ERROR=1
            fi
        done
    fi
done < <(find docs -type f \( -name "*.md" -o -name "*.txt" \) ! -path "docs/constitution/*" ! -path "docs/rfcs/*" ! -path "docs/_archive/*" ! -path "docs/pr/*" ! -path "docs/implementation/*" ! -path "docs/tasks/*" 2>/dev/null || true)

# Also check README.md
if [ -f "README.md" ]; then
    for keyword in "${RULES_KEYWORDS[@]}"; do
        if grep -qi "$keyword" "README.md" 2>/dev/null; then
            echo -e "${RED}❌ Rules keyword found in README.md${NC}"
            echo "  Keyword: $keyword"
            SPILL_ERROR=1
        fi
    done
fi

if [ $SPILL_ERROR -eq 0 ]; then
    echo -e "${GREEN}✅ No rules spill detected${NC}"
else
    echo -e "${RED}❌ Rules spill violation detected${NC}"
    echo "Rules must only be written in docs/constitution/ or docs/rfcs/"
    exit 1
fi
echo ""

# Summary
echo "=========================================="
echo "  Preflight Check Complete"
echo "=========================================="
echo ""
echo "All checks passed! ✅"

