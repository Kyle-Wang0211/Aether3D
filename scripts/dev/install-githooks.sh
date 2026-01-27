#!/usr/bin/env bash
# install-githooks.sh
# Install Git hooks from .githooks/ to .git/hooks/
#
# Usage: bash scripts/dev/install-githooks.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

cd "$REPO_ROOT"

if [ ! -d ".git" ]; then
    echo "❌ Error: Not a git repository"
    exit 1
fi

if [ ! -d ".githooks" ]; then
    echo "❌ Error: .githooks/ directory not found"
    exit 1
fi

echo "Installing Git hooks from .githooks/ to .git/hooks/..."

for hook in .githooks/*; do
    if [ -f "$hook" ] && [ -x "$hook" ]; then
        hook_name=$(basename "$hook")
        target=".git/hooks/$hook_name"
        
        # Copy hook
        cp "$hook" "$target"
        chmod +x "$target"
        
        echo "✅ Installed: $hook_name"
    fi
done

echo ""
echo "✅ Git hooks installed successfully!"
echo ""
echo "Note: PR1 branches require these hooks to be installed."
echo "The pre-push hook will run PIZ local gate checks before allowing a push."
