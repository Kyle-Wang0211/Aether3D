#!/bin/bash
# regen_fixtures.sh
# PR1 v2.4 Addendum - Regenerate fixtures with header validation

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

cd "$REPO_ROOT"

echo "Regenerating fixtures..."

# Run Swift fixture generator
swift run FixtureGen

# Normalize line endings (ensure LF only)
if command -v dos2unix &> /dev/null; then
    dos2unix Tests/Fixtures/*.txt 2>/dev/null || true
else
    # Fallback: use sed to convert CRLF to LF
    find Tests/Fixtures -name "*.txt" -type f -exec sed -i '' 's/\r$//' {} \; 2>/dev/null || \
    find Tests/Fixtures -name "*.txt" -type f -exec sed -i 's/\r$//' {} \; 2>/dev/null || true
fi

echo "Fixtures regenerated. Checking for changes..."
git diff --exit-code Tests/Fixtures || {
    echo "ERROR: Regenerated fixtures differ from committed fixtures."
    echo "Please review the diff and commit if changes are intentional."
    exit 1
}

echo "✓ Fixtures match committed versions."
