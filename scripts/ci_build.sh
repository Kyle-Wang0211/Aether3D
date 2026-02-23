#!/bin/bash
# CI Build Script
# Detects project type (Xcode or SPM) and builds accordingly

set -euo pipefail

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

echo "=========================================="
echo "  CI Build"
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
    # Try to detect scheme name (common patterns)
    if [ -f "$XCODE_PROJECT/project.pbxproj" ]; then
        # Try to extract scheme from project file
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
    echo -e "${RED}❌ Error: Could not detect project type (Xcode or SPM)${NC}"
    echo "Please ensure either:"
    echo "  - A .xcodeproj file exists, or"
    echo "  - A Package.swift file exists"
    exit 1
fi

# Build based on project type
if [ "$PROJECT_TYPE" == "xcode" ]; then
    echo ""
    echo -e "${BLUE}Building Xcode project...${NC}"
    
    # Use xcodebuild to build
    # Note: This requires a valid scheme and destination
    # For CI, we'll use generic iOS Simulator
    xcodebuild \
        -project "$XCODE_PROJECT" \
        -scheme "$SCHEME_NAME" \
        -destination 'platform=iOS Simulator,name=iPhone 15' \
        clean build \
        CODE_SIGN_IDENTITY="" \
        CODE_SIGNING_REQUIRED=NO \
        CODE_SIGNING_ALLOWED=NO || {
        echo -e "${YELLOW}⚠️  Warning: xcodebuild may require manual configuration${NC}"
        echo "If build fails, check:"
        echo "  - Scheme name: $SCHEME_NAME"
        echo "  - Valid simulator destination"
        echo "  - Code signing settings"
        exit 1
    }
    
    echo -e "${GREEN}✅ Build successful${NC}"
    
elif [ "$PROJECT_TYPE" == "spm" ]; then
    echo ""
    echo -e "${BLUE}Building Swift Package...${NC}"
    swift build
    echo -e "${GREEN}✅ Build successful${NC}"
fi

echo ""
echo "=========================================="
echo "  Build Complete"
echo "=========================================="

