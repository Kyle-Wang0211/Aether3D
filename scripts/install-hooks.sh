#!/bin/bash
# Install git hooks for PR1 Constitution compliance
# Source: LOCAL_PREFLIGHT_GATE.md §2.1

set -e

HOOK_DIR=".git/hooks"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

echo "Installing git hooks..."

# Install pre-push hook
if [ -f "$HOOK_DIR/pre-push" ]; then
    echo "Backing up existing pre-push hook..."
    mv "$HOOK_DIR/pre-push" "$HOOK_DIR/pre-push.backup"
fi

cp "$SCRIPT_DIR/pre-push" "$HOOK_DIR/pre-push"
chmod +x "$HOOK_DIR/pre-push"

echo "✓ pre-push hook installed"
echo ""
echo "Hooks installed successfully!"
echo "Run './scripts/pre-push' manually to test."
