#!/bin/bash
# scripts/lib.sh
# Portable helper functions for cross-platform scripts (macOS + Linux)
#
# H4: Script portability (macOS + Linux)
# - All scripts must be bash + POSIX-friendly
# - Do not use: sed -i without portability wrapper, grep -P, readlink -f, or mac-only flags

set -euo pipefail

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# MARK: - Repo Root

# Find repository root via git rev-parse (preferred) or by walking from current path
repo_root() {
    # Try git rev-parse first (fastest, most reliable)
    if command -v git >/dev/null 2>&1; then
        local git_root
        if git_root=$(git rev-parse --show-toplevel 2>/dev/null); then
            echo "$git_root"
            return 0
        fi
    fi
    
    # Fallback: walk up from current directory to find Package.swift
    local current_dir
    current_dir=$(pwd)
    
    while [ "$current_dir" != "/" ]; do
        if [ -f "$current_dir/Package.swift" ]; then
            echo "$current_dir"
            return 0
        fi
        current_dir=$(dirname "$current_dir")
    done
    
    # If we get here, we couldn't find the repo root
    echo "ERROR: Could not find repository root" >&2
    return 1
}

# MARK: - Portable sed in-place

# Portable sed in-place wrapper (works on both macOS and Linux)
portable_sed_inplace() {
    local file="$1"
    shift
    
    if [ ! -f "$file" ]; then
        die "File not found: $file"
    fi
    
    # macOS sed requires -i '' for in-place editing
    # Linux sed requires -i without extension
    if [[ "$OSTYPE" == "darwin"* ]]; then
        sed -i '' "$@" "$file"
    else
        sed -i "$@" "$file"
    fi
}

# MARK: - Die helper

# Die with consistent error formatting
die() {
    local message="$1"
    local exit_code="${2:-1}"
    
    echo -e "${RED}ERROR:${NC} $message" >&2
    exit "$exit_code"
}

# MARK: - Info/Warning helpers

info() {
    echo -e "${BLUE}INFO:${NC} $*"
}

warning() {
    echo -e "${YELLOW}WARNING:${NC} $*"
}

success() {
    echo -e "${GREEN}SUCCESS:${NC} $*"
}

# MARK: - Line ending check

# Check if file contains CRLF line endings
check_line_endings() {
    local file="$1"
    
    if [ ! -f "$file" ]; then
        die "File not found: $file"
    fi
    
    # Check for CRLF (carriage return + line feed)
    if file "$file" | grep -q "CRLF\|CR line terminators"; then
        return 1  # Found CRLF
    fi
    
    # Also check with hexdump/od if available
    if command -v od >/dev/null 2>&1; then
        if od -An -tx1 "$file" | grep -q "0d 0a"; then
            return 1  # Found CRLF (0x0D 0x0A)
        fi
    fi
    
    return 0  # No CRLF found
}

# MARK: - Toolchain verification

# Verify Swift version matches required version
verify_swift_version() {
    local required_major="$1"
    local required_minor="$2"
    
    if ! command -v swift >/dev/null 2>&1; then
        die "Swift toolchain not found. Please install Swift."
    fi
    
    local swift_version
    swift_version=$(swift --version 2>&1 | head -n 1)
    
    # Extract major.minor from version string
    # Format: "Swift version X.Y.Z" or "swift-driver version: X.Y.Z"
    local major minor
    if [[ "$swift_version" =~ Swift[[:space:]]+version[[:space:]]+([0-9]+)\.([0-9]+) ]]; then
        major="${BASH_REMATCH[1]}"
        minor="${BASH_REMATCH[2]}"
    elif [[ "$swift_version" =~ swift-driver[[:space:]]+version:[[:space:]]+([0-9]+)\.([0-9]+) ]]; then
        major="${BASH_REMATCH[1]}"
        minor="${BASH_REMATCH[2]}"
    else
        warning "Could not parse Swift version: $swift_version"
        return 0  # Don't fail if we can't parse
    fi
    
    if [ "$major" -lt "$required_major" ] || \
       ([ "$major" -eq "$required_major" ] && [ "$minor" -lt "$required_minor" ]); then
        die "Swift version mismatch. Required: $required_major.$required_minor.x, Found: $major.$minor.x" \
            "Please update your Swift toolchain."
    fi
    
    success "Swift version OK: $major.$minor.x"
}
