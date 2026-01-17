#!/bin/bash
# Install git hooks for Quality Pre-check
# PR#5.1: Hook installation script

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
cd "$REPO_ROOT"

# Verify we're in a git repository
if ! git rev-parse --git-dir > /dev/null 2>&1; then
    echo "ERROR: Not in a git repository" >&2
    exit 1
fi

HOOKS_DIR="$REPO_ROOT/.git/hooks"
TEMPLATE_DIR="$REPO_ROOT/scripts/hooks"

# Create hooks directory if it doesn't exist
mkdir -p "$HOOKS_DIR"

# Install pre-push hook
PRE_PUSH_TEMPLATE="$TEMPLATE_DIR/pre-push"
PRE_PUSH_HOOK="$HOOKS_DIR/pre-push"

if [ ! -f "$PRE_PUSH_TEMPLATE" ]; then
    echo "ERROR: Pre-push hook template not found: $PRE_PUSH_TEMPLATE" >&2
    exit 1
fi

echo "Installing pre-push hook..."
cp "$PRE_PUSH_TEMPLATE" "$PRE_PUSH_HOOK"
chmod +x "$PRE_PUSH_HOOK"

echo "✅ Pre-push hook installed successfully"
echo ""
echo "Note: Hooks are not version-controlled. Run this script after cloning the repository."

