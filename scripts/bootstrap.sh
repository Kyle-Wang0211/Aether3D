#!/bin/bash
# Bootstrap Script
# Initial setup for new developers

set -euo pipefail

# Colors for output
GREEN='\033[0;32m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

echo "=========================================="
echo "  Aether3D Bootstrap"
echo "=========================================="
echo ""

echo -e "${BLUE}Welcome to Aether3D!${NC}"
echo ""
echo "This script will help you get started."
echo ""

# Check Git
if ! command -v git &> /dev/null; then
    echo "❌ Git is not installed. Please install Git first."
    exit 1
fi

echo "✅ Git found"

# Check Swift/Xcode
if command -v xcodebuild &> /dev/null; then
    echo "✅ Xcode found"
    xcodebuild -version
elif command -v swift &> /dev/null; then
    echo "✅ Swift found"
    swift --version
else
    echo "⚠️  Warning: Neither Xcode nor Swift found. You may need to install Xcode."
fi

echo ""
echo -e "${GREEN}✅ Bootstrap complete!${NC}"
echo ""
echo "Next steps:"
echo "  1. Read: docs/constitution/INDEX.md"
echo "  2. Run: bash scripts/preflight.sh"
echo ""

