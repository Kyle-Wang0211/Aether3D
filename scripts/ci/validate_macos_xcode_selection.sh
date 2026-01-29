#!/bin/bash
# validate_macos_xcode_selection.sh
# Validates Xcode selection and availability
# Ensures Xcode is usable before proceeding with builds

set -euo pipefail

REQUESTED_XCODE_VERSION="${1:-}"

echo "🔍 Xcode Selection Validation"
echo "=============================="
echo ""

# Print available Xcode installations
echo "Available Xcode installations:"
if ls -1 /Applications 2>/dev/null | grep -E '^Xcode.*\.app$' >/dev/null 2>&1; then
    ls -1 /Applications | grep -E '^Xcode.*\.app$' | sed 's/^/  - /'
else
    echo "  ⚠️  No Xcode.app found in /Applications"
fi
echo ""

# Print current Xcode selection
echo "Current Xcode selection:"
CURRENT_XCODE=$(xcode-select -p 2>/dev/null || echo "none")
echo "  Path: $CURRENT_XCODE"
echo ""

# Validate Xcode is usable
echo "Validating Xcode usability..."

# Check xcodebuild
if ! command -v xcodebuild &> /dev/null; then
    echo "  ❌ xcodebuild not found in PATH"
    exit 1
fi

# Get Xcode version
XCODE_VERSION_OUTPUT=$(xcodebuild -version 2>&1 || echo "")
if [ -z "$XCODE_VERSION_OUTPUT" ]; then
    echo "  ❌ xcodebuild -version failed"
    echo "     This indicates Xcode is not properly installed or selected"
    exit 1
fi

echo "  ✅ xcodebuild available"
echo "  Version:"
echo "$XCODE_VERSION_OUTPUT" | sed 's/^/    /'
echo ""

# Check Swift
if ! command -v swift &> /dev/null; then
    echo "  ❌ swift not found in PATH"
    exit 1
fi

SWIFT_VERSION_OUTPUT=$(swift --version 2>&1 || echo "")
if [ -z "$SWIFT_VERSION_OUTPUT" ]; then
    echo "  ❌ swift --version failed"
    exit 1
fi

echo "  ✅ swift available"
echo "  Version:"
echo "$SWIFT_VERSION_OUTPUT" | head -1 | sed 's/^/    /'
echo ""

# Check swiftc via xcrun
if ! xcrun --find swiftc &> /dev/null; then
    echo "  ❌ xcrun --find swiftc failed"
    exit 1
fi

SWIFTC_PATH=$(xcrun --find swiftc 2>/dev/null)
echo "  ✅ swiftc found: $SWIFTC_PATH"
echo ""

# If a specific version was requested, verify it matches
if [ -n "$REQUESTED_XCODE_VERSION" ]; then
    echo "Requested Xcode version: $REQUESTED_XCODE_VERSION"
    ACTUAL_VERSION=$(echo "$XCODE_VERSION_OUTPUT" | head -1 | grep -oE '[0-9]+\.[0-9]+' | head -1 || echo "")
    
    if [ -z "$ACTUAL_VERSION" ]; then
        echo "  ⚠️  Could not parse Xcode version from output"
    elif [ "$ACTUAL_VERSION" != "$REQUESTED_XCODE_VERSION" ]; then
        echo "  ⚠️  Version mismatch: requested $REQUESTED_XCODE_VERSION, got $ACTUAL_VERSION"
        echo "     This may be acceptable if the version is compatible"
    else
        echo "  ✅ Version matches requested: $REQUESTED_XCODE_VERSION"
    fi
    echo ""
fi

# Print runner OS info
echo "Runner OS information:"
if [ -f /System/Library/CoreServices/SystemVersion.plist ]; then
    OS_VERSION=$(defaults read /System/Library/CoreServices/SystemVersion.plist ProductVersion 2>/dev/null || echo "unknown")
    echo "  macOS Version: $OS_VERSION"
fi
echo ""

echo "✅ Xcode selection validation passed"
echo "   Xcode is properly installed and usable"
