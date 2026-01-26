#!/bin/bash
# scripts/update_golden_policy_digests.sh
# H5: Golden policy digests auto-generation script
#
# Regenerates Tests/Golden/policy_digests.json deterministically
# Must be run from repo root

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib.sh"

REPO_ROOT=$(repo_root)
cd "$REPO_ROOT"

echo "Updating golden policy digests..."
echo "Repository root: $REPO_ROOT"

# Build the executable
if ! swift build --product UpdateGoldenDigests 2>&1; then
    die "Failed to build UpdateGoldenDigests executable"
fi

# Run the executable
if ! swift run UpdateGoldenDigests 2>&1; then
    die "Failed to run UpdateGoldenDigests"
fi

# Verify line endings (H6)
GOLDEN_FILE="$REPO_ROOT/Tests/Golden/policy_digests.json"
if ! check_line_endings "$GOLDEN_FILE"; then
    warning "Golden file contains CRLF. Converting to LF..."
    portable_sed_inplace "$GOLDEN_FILE" 's/\r$//'
    if ! check_line_endings "$GOLDEN_FILE"; then
        die "Failed to fix line endings in golden file"
    fi
fi

success "Golden policy digests updated successfully!"
echo "File: $GOLDEN_FILE"
