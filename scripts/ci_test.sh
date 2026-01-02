#!/bin/bash
# CI Test Script
# Detects project type (Xcode or SPM) and runs tests accordingly

set -euo pipefail

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

echo "=========================================="
echo "  CI Test"
echo "=========================================="
echo ""

# Detect project type
PROJECT_TYPE=""
SCHEME_NAME=""
XCODE_PROJECT=""

# Check for Xcode project
if find . -maxdepth 2 -name "*.xcodeproj" -type d | grep -q .; then
    PROJECT_TYPE="xcode"
    XCODE_PROJECT=$(find . -maxdepth 2 -name "*.xcodeproj" -type d | head -1)
    # Try to detect scheme name
    if [ -f "$XCODE_PROJECT/project.pbxproj" ]; then
        SCHEME_NAME=$(grep -o 'productName = [^;]*' "$XCODE_PROJECT/project.pbxproj" | head -1 | sed 's/productName = //' | tr -d '"' || echo "progect2")
    else
        SCHEME_NAME="progect2"
    fi
    echo -e "${BLUE}Detected: Xcode project${NC}"
    echo "Project: $XCODE_PROJECT"
    echo "Scheme: $SCHEME_NAME"
elif [ -f "Package.swift" ]; then
    PROJECT_TYPE="spm"
    echo -e "${BLUE}Detected: Swift Package Manager${NC}"
else
    echo -e "${YELLOW}⚠️  Warning: Could not detect project type${NC}"
    echo "Skipping tests (no Xcode project or Package.swift found)"
    exit 0
fi

# Run tests based on project type
if [ "$PROJECT_TYPE" == "xcode" ]; then
    echo ""
    echo -e "${BLUE}Running Xcode tests...${NC}"
    
    xcodebuild test \
        -project "$XCODE_PROJECT" \
        -scheme "$SCHEME_NAME" \
        -destination 'platform=iOS Simulator,name=iPhone 15' \
        CODE_SIGN_IDENTITY="" \
        CODE_SIGNING_REQUIRED=NO \
        CODE_SIGNING_ALLOWED=NO || {
        echo -e "${YELLOW}⚠️  Warning: xcodebuild test may require manual configuration${NC}"
        echo "If tests fail, check:"
        echo "  - Scheme name: $SCHEME_NAME"
        echo "  - Valid simulator destination"
        echo "  - Test targets exist"
        exit 1
    }
    
    echo -e "${GREEN}✅ Tests passed${NC}"
    
elif [ "$PROJECT_TYPE" == "spm" ]; then
    echo ""
    echo -e "${BLUE}Running Swift Package tests...${NC}"
    swift test
    echo -e "${GREEN}✅ Tests passed${NC}"
fi

echo ""
echo "=========================================="
echo "  Test Complete"
echo "=========================================="

