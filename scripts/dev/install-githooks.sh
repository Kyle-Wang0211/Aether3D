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

echo "Configuring Git to use .githooks/ directory..."

# Configure Git to use .githooks as hooks directory
git config core.hooksPath .githooks

# Ensure hooks are executable
chmod +x .githooks/pre-push
chmod +x scripts/ci/piz_local_gate.sh
chmod +x scripts/dev/install-githooks.sh

echo ""
echo "✅ Git hooks configured successfully!"
echo ""
echo "Note: PR1 branches require these hooks to be installed."
echo "The pre-push hook will run PIZ local gate checks before allowing a push."
echo ""
echo "Git hooks path: $(git config core.hooksPath)"
