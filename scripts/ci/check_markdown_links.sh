#!/bin/bash
# check_markdown_links.sh
# Validates markdown links in constitution docs
# Ensures referenced files exist and INDEX.md entries are correct

set -euo pipefail

REPO_ROOT="${1:-$(git rev-parse --show-toplevel)}"
cd "$REPO_ROOT" || exit 1

CONSTITUTION_DIR="docs/constitution"
ERRORS=0

echo "🔗 Markdown Link Checker"
echo "======================="
echo ""

# Check that INDEX.md exists
if [ ! -f "$CONSTITUTION_DIR/INDEX.md" ]; then
    echo "❌ INDEX.md not found"
    ERRORS=$((ERRORS + 1))
    exit 1
fi

# Find all markdown files in constitution
MD_FILES=$(find "$CONSTITUTION_DIR" -name "*.md" -type f)

echo "Checking links in constitution markdown files..."
echo ""

for md_file in $MD_FILES; do
    # Extract relative links (format: [text](path) or [text](./path))
    links=$(grep -oP '\[([^\]]+)\]\(([^)]+)\)' "$md_file" || true)
    
    if [ -z "$links" ]; then
        continue
    fi
    
    while IFS= read -r link; do
        # Extract the path part
        path=$(echo "$link" | sed -n 's/.*](\(.*\))/\1/p')
        
        # Skip external links (http/https)
        if [[ "$path" =~ ^https?:// ]]; then
            continue
        fi
        
        # Skip anchor links (starting with #)
        if [[ "$path" =~ ^# ]]; then
            continue
        fi
        
        # Resolve relative path
        md_dir=$(dirname "$md_file")
        resolved_path="$md_dir/$path"
        
        # Normalize path (remove ./ and ../)
        resolved_path=$(cd "$md_dir" && realpath "$path" 2>/dev/null || echo "")
        
        if [ -z "$resolved_path" ] || [ ! -e "$resolved_path" ]; then
            echo "❌ Broken link in $md_file:"
            echo "   Link: $link"
            echo "   Path: $path"
            ERRORS=$((ERRORS + 1))
        fi
    done <<< "$links"
done

# Check INDEX.md references
echo "Checking INDEX.md references..."
INDEX_ENTRIES=$(grep -oP '\[([^\]]+)\]\(([^)]+)\)' "$CONSTITUTION_DIR/INDEX.md" || true)

if [ -n "$INDEX_ENTRIES" ]; then
    while IFS= read -r entry; do
        path=$(echo "$entry" | sed -n 's/.*](\(.*\))/\1/p')
        
        # Skip external links
        if [[ "$path" =~ ^https?:// ]]; then
            continue
        fi
        
        # Resolve path relative to INDEX.md
        resolved_path="$CONSTITUTION_DIR/$path"
        
        if [ ! -e "$resolved_path" ]; then
            echo "❌ INDEX.md references non-existent file:"
            echo "   Entry: $entry"
            echo "   Path: $path"
            ERRORS=$((ERRORS + 1))
        fi
    done <<< "$INDEX_ENTRIES"
fi

echo ""

if [ $ERRORS -eq 0 ]; then
    echo "✅ All markdown links valid"
    exit 0
else
    echo "❌ Found $ERRORS broken link(s)"
    exit 1
fi
