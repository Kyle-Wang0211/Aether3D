#!/bin/bash
# Artifact Contract Lint Script
# Checks for forbidden APIs and extension bypasses in Core/Artifacts

set -euo pipefail

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

ERRORS=0

echo "=========================================="
echo "  Artifact Contract Lint"
echo "=========================================="
echo ""

# Section 1: Check Core/Artifacts exists
echo -e "${BLUE}1. Checking Core/Artifacts directory${NC}"
echo "----------------------------------------"
if [ ! -d "Core/Artifacts" ]; then
    echo -e "${RED}❌ Core/Artifacts directory not found${NC}"
    ERRORS=$((ERRORS + 1))
else
    echo -e "${GREEN}✅ Core/Artifacts directory exists${NC}"
    SWIFT_FILES=$(find Core/Artifacts -name "*.swift" 2>/dev/null | wc -l | tr -d ' ')
    if [ "$SWIFT_FILES" -eq "0" ]; then
        echo -e "${YELLOW}⚠️  No .swift files found in Core/Artifacts${NC}"
    else
        echo -e "${GREEN}✅ Found $SWIFT_FILES .swift file(s)${NC}"
    fi
fi
echo ""

# Section 2: Forbidden APIs in Core/Artifacts
echo -e "${BLUE}2. Checking for forbidden APIs in Core/Artifacts${NC}"
echo "----------------------------------------"

FORBIDDEN_PATTERNS=(
    "Date()"
    "Date.now"
    "UUID()"
    "UUID.init"
    "random"
    "JSONEncoder"
    "JSONSerialization"
    "NumberFormatter"
    "Locale\\."
    "TimeZone\\."
    "ProcessInfo\\.processInfo\\.environment"
    "Bundle\\.main"
    "String\\(format:"
)

PATTERN_NAMES=(
    "Date()"
    "Date.now"
    "UUID()"
    "UUID.init"
    "random generation"
    "JSONEncoder"
    "JSONSerialization"
    "NumberFormatter"
    "Locale."
    "TimeZone."
    "ProcessInfo.processInfo.environment"
    "Bundle.main"
    "String(format:)"
)

for i in "${!FORBIDDEN_PATTERNS[@]}"; do
    PATTERN="${FORBIDDEN_PATTERNS[$i]}"
    NAME="${PATTERN_NAMES[$i]}"
    
    # Search for pattern, excluding comments (lines starting with // or containing // before the pattern)
    FOUND=$(find Core/Artifacts -name "*.swift" -type f 2>/dev/null | \
        xargs grep -n "$PATTERN" 2>/dev/null | \
        grep -v "^\s*//" | \
        grep -v "//.*$PATTERN" | \
        head -1 || true)
    
    if [ -n "$FOUND" ]; then
        echo -e "${RED}❌ Found forbidden API: $NAME${NC}"
        find Core/Artifacts -name "*.swift" -type f 2>/dev/null | \
            xargs grep -n "$PATTERN" 2>/dev/null | \
            grep -v "^\s*//" | \
            grep -v "//.*$PATTERN" | \
            head -5 | sed 's/^/  /'
        ERRORS=$((ERRORS + 1))
    fi
done

# More precise check for String(format:)
FOUND=$(find Core/Artifacts -name "*.swift" -type f 2>/dev/null | \
    xargs grep -n "String(format:" 2>/dev/null | \
    grep -v "^\s*//" | \
    grep -v "//.*String(format:" | \
    head -1 || true)

if [ -n "$FOUND" ]; then
    echo -e "${RED}❌ Found forbidden API: String(format:)${NC}"
    find Core/Artifacts -name "*.swift" -type f 2>/dev/null | \
        xargs grep -n "String(format:" 2>/dev/null | \
        grep -v "^\s*//" | \
        grep -v "//.*String(format:" | \
        head -5 | sed 's/^/  /'
    ERRORS=$((ERRORS + 1))
fi

if [ $ERRORS -eq 0 ]; then
    echo -e "${GREEN}✅ No forbidden APIs found${NC}"
fi
echo ""

# Section 3: Repo-wide extension bypass check
echo -e "${BLUE}3. Checking for Equatable/Hashable extensions${NC}"
echo "----------------------------------------"

EXCLUDE_DIRS="Core/Artifacts|Tests|docs|\\.git|\\.build|DerivedData"

# Search for extension ArtifactManifest : Equatable
EQUATABLE_FOUND=$(find . -type f -name "*.swift" 2>/dev/null | \
    grep -vE "($EXCLUDE_DIRS)" | \
    xargs grep -l "extension ArtifactManifest.*Equatable" 2>/dev/null | \
    head -1 || true)

# Search for extension ArtifactManifest : Hashable
HASHABLE_FOUND=$(find . -type f -name "*.swift" 2>/dev/null | \
    grep -vE "($EXCLUDE_DIRS)" | \
    xargs grep -l "extension ArtifactManifest.*Hashable" 2>/dev/null | \
    head -1 || true)

if [ -n "$EQUATABLE_FOUND" ] || [ -n "$HASHABLE_FOUND" ]; then
    echo -e "${RED}❌ Found forbidden extension conformance${NC}"
    if [ "$EQUATABLE_MATCHES" -gt "0" ]; then
        echo -e "${RED}  Found Equatable extension:${NC}"
        find . -type f -name "*.swift" 2>/dev/null | \
            grep -vE "($EXCLUDE_DIRS)" | \
            xargs grep -n "extension ArtifactManifest.*Equatable" 2>/dev/null | head -5 | sed 's/^/    /'
    fi
    if [ "$HASHABLE_MATCHES" -gt "0" ]; then
        echo -e "${RED}  Found Hashable extension:${NC}"
        find . -type f -name "*.swift" 2>/dev/null | \
            grep -vE "($EXCLUDE_DIRS)" | \
            xargs grep -n "extension ArtifactManifest.*Hashable" 2>/dev/null | head -5 | sed 's/^/    /'
    fi
    ERRORS=$((ERRORS + 1))
else
    echo -e "${GREEN}✅ No forbidden extensions found${NC}"
fi
echo ""

# Final summary
echo "=========================================="
if [ $ERRORS -eq 0 ]; then
    echo -e "${GREEN}✅ All lint checks passed${NC}"
    exit 0
else
    echo -e "${RED}❌ Found $ERRORS error(s)${NC}"
    exit 1
fi

