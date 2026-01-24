#!/bin/bash
# repo_hygiene.sh
# Fast-fail repository hygiene checks
# Ensures no CRLF, valid JSON/YAML, no forbidden patterns

set -euo pipefail

REPO_ROOT="${1:-$(git rev-parse --show-toplevel)}"
cd "$REPO_ROOT" || exit 1

ERRORS=0

echo "🧹 Repository Hygiene Checks"
echo "============================"
echo ""

# 1. Check for CRLF line endings
echo "1. Checking for CRLF line endings..."
CRLF_FILES=$(grep -RIl $'\r' docs .github Tests Core 2>/dev/null || true)
if [ -n "$CRLF_FILES" ]; then
    echo "   ❌ Found CRLF in files:"
    echo "$CRLF_FILES" | sed 's/^/      /'
    ERRORS=$((ERRORS + 1))
else
    echo "   ✅ No CRLF found"
fi

echo ""

# 2. Validate JSON files
echo "2. Validating JSON files..."
JSON_FILES=$(find docs/constitution/constants -name "*.json" 2>/dev/null || true)
JSON_ERRORS=0
for json_file in $JSON_FILES; do
    if ! python3 -c "import json; json.load(open('$json_file'))" 2>/dev/null; then
        echo "   ❌ Invalid JSON: $json_file"
        JSON_ERRORS=$((JSON_ERRORS + 1))
    fi
done

if [ $JSON_ERRORS -eq 0 ]; then
    echo "   ✅ All JSON files valid"
else
    echo "   ❌ Found $JSON_ERRORS invalid JSON file(s)"
    ERRORS=$((ERRORS + JSON_ERRORS))
fi

echo ""

# 3. Validate YAML files
echo "3. Validating YAML files..."
YAML_FILES=$(find .github/workflows -name "*.yml" -o -name "*.yaml" 2>/dev/null || true)
YAML_ERRORS=0
for yaml_file in $YAML_FILES; do
    if ! python3 -c "import yaml; yaml.safe_load(open('$yaml_file'))" 2>/dev/null; then
        echo "   ❌ Invalid YAML: $yaml_file"
        YAML_ERRORS=$((YAML_ERRORS + 1))
    fi
done

if [ $YAML_ERRORS -eq 0 ]; then
    echo "   ✅ All YAML files valid"
else
    echo "   ❌ Found $YAML_ERRORS invalid YAML file(s)"
    ERRORS=$((ERRORS + YAML_ERRORS))
fi

echo ""

# 4. Check for forbidden patterns
echo "4. Checking for forbidden patterns..."

# TODO in constitution docs (exclude known report files and sections that document TODOs)
echo "   4.1 Checking for TODO in constitution docs..."
TODO_IN_CONSTITUTION=$(grep -RIl "TODO" docs/constitution/*.md 2>/dev/null | \
    grep -v "TEST_AND_CI_HARDENING_REPORT.md" | \
    grep -v "SHADOW_CROSSPLATFORM_REPORT.md" | \
    grep -v "FINAL_LOCAL_VERIFICATION_REPORT.md" || true)
# Further filter: only flag if TODO appears in actual content, not in "Remaining TODOs" sections
TODO_REAL=0
if [ -n "$TODO_IN_CONSTITUTION" ]; then
    for file in $TODO_IN_CONSTITUTION; do
        # Check if TODO appears outside of "Remaining TODOs" or "TODO:" section headers
        if grep -v "^##.*TODO\|^###.*TODO\|Remaining TODOs\|## Remaining" "$file" 2>/dev/null | grep -q "TODO"; then
            TODO_REAL=1
            break
        fi
    done
fi

if [ $TODO_REAL -eq 1 ]; then
    echo "   ❌ Found TODO in constitution docs (outside documented sections):"
    echo "$TODO_IN_CONSTITUTION" | sed 's/^/      /'
    ERRORS=$((ERRORS + 1))
else
    echo "   ✅ No TODO in constitution docs (excluding report files and documented TODO sections)"
fi

# FIXME anywhere in SSOT folders (exclude known report files, legacy docs, and rule definitions)
echo "   4.2 Checking for FIXME in SSOT folders..."
# Exclude FIXME that appears in rule definitions (like "TODO_FIXME" rule name)
FIXME_IN_SSOT=$(grep -RIl "FIXME" Core/Constants Tests/Constants docs/constitution 2>/dev/null | \
    grep -v "TEST_AND_CI_HARDENING_REPORT.md" | \
    grep -v "SHADOW_CROSSPLATFORM_REPORT.md" | \
    grep -v "FINAL_LOCAL_VERIFICATION_REPORT.md" | \
    grep -v "FP1_v" || true)
# Further filter: only flag if FIXME appears outside of rule definitions (not "TODO_FIXME" or similar patterns)
FIXME_REAL=0
if [ -n "$FIXME_IN_SSOT" ]; then
    for file in $FIXME_IN_SSOT; do
        # Check if FIXME appears in actual comments/code, not just in rule definitions
        if grep -v "ruleId\|rule\|pattern.*FIXME\|TODO_FIXME" "$file" 2>/dev/null | grep -q "FIXME"; then
            FIXME_REAL=1
            break
        fi
    done
fi

if [ $FIXME_REAL -eq 1 ]; then
    echo "   ❌ Found FIXME in SSOT folders (outside rule definitions):"
    echo "$FIXME_IN_SSOT" | sed 's/^/      /'
    ERRORS=$((ERRORS + 1))
else
    echo "   ✅ No FIXME in SSOT folders (excluding report files and rule definitions)"
fi

# System color APIs in ColorSpaceConstants (exclude comments)
echo "   4.3 Checking for forbidden system color APIs..."
FORBIDDEN_COLOR_APIS=("UIColor" "CGColorSpace" "ColorSync" "NSColor" "CGColor")
FOUND_FORBIDDEN=0
for api in "${FORBIDDEN_COLOR_APIS[@]}"; do
    # Check for API usage outside of comments (grep for lines not starting with // or containing //)
    if grep -v "^[[:space:]]*//" Core/Constants/ColorSpaceConstants.swift 2>/dev/null | grep -q "$api"; then
        echo "   ❌ Found forbidden API '$api' in ColorSpaceConstants.swift (outside comments)"
        FOUND_FORBIDDEN=1
    fi
done

if [ $FOUND_FORBIDDEN -eq 0 ]; then
    echo "   ✅ No forbidden color APIs found"
else
    ERRORS=$((ERRORS + FOUND_FORBIDDEN))
fi

echo ""

# 5. Check script executability
echo "5. Checking script executability..."
SCRIPT_ERRORS=0
for script in scripts/ci/*.sh; do
    if [ -f "$script" ] && [ ! -x "$script" ]; then
        echo "   ❌ Script not executable: $script"
        SCRIPT_ERRORS=$((SCRIPT_ERRORS + 1))
    fi
done

if [ $SCRIPT_ERRORS -eq 0 ]; then
    echo "   ✅ All scripts executable"
else
    echo "   ❌ Found $SCRIPT_ERRORS non-executable script(s)"
    ERRORS=$((ERRORS + SCRIPT_ERRORS))
fi

echo ""

# 6. Check for Apple-only imports in Linux-compiled targets
echo "6. Checking for Apple-only imports in Linux-compiled targets..."
if bash scripts/ci/ban_apple_only_imports.sh >/dev/null 2>&1; then
    echo "   ✅ No forbidden Apple-only imports found"
else
    echo "   ❌ Found Apple-only imports without conditional compilation guards"
    bash scripts/ci/ban_apple_only_imports.sh || true
    ERRORS=$((ERRORS + 1))
fi

echo ""

# 7. Verify workflow includes OPENSSL_ia32cap for ubuntu Gate 2 jobs
echo "7. Verifying OPENSSL_ia32cap guardrails in workflow..."
if grep -q "OPENSSL_ia32cap.*ubuntu-22.04" .github/workflows/ssot-foundation-ci.yml 2>/dev/null; then
    echo "   ✅ OPENSSL_ia32cap guardrails found in workflow"
else
    echo "   ⚠️  OPENSSL_ia32cap guardrails not found (may be acceptable if not using ubuntu jobs)"
fi

echo ""

# Summary
if [ $ERRORS -eq 0 ]; then
    echo "✅ All hygiene checks passed"
    exit 0
else
    echo "❌ Found $ERRORS hygiene issue(s)"
    exit 1
fi
