#!/bin/bash
# Linux CI Inner Script (Container-Only)
# 
# This script runs INSIDE the Docker container and performs:
# - Copying workspace to container-local location
# - Installing Linux dependencies
# - Building and testing Swift package
#
# DO NOT run this script directly on the host.
# It is invoked by docker_linux_ci.sh via docker run.

set -euo pipefail

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

echo '=========================================='
echo 'Container Setup'
echo '=========================================='
echo "Container user: $(whoami)"
echo "Container UID: $(id -u)"
echo "Container GID: $(id -g)"
echo "Working directory: $(pwd)"
echo ''

# Verify we're in a container (sanity check)
if [ ! -f /.dockerenv ] && [ ! -f /proc/self/cgroup ] || ! grep -q docker /proc/self/cgroup 2>/dev/null; then
    echo -e "${YELLOW}Warning: This script is designed to run inside a Docker container${NC}"
    echo "If you're seeing this, the container detection may have failed."
    echo "Continuing anyway..."
fi

# Install Ubuntu dependencies
echo 'Installing Ubuntu dependencies...'
apt-get update -qq
apt-get install -y -qq libsqlite3-dev pkg-config git ca-certificates rsync > /dev/null 2>&1
echo -e "${GREEN}✅ Dependencies installed${NC}"
echo ''

# Create container-local directories
echo 'Creating container-local directories...'
mkdir -p /tmp/aether3d_src
mkdir -p /tmp/aether3d_build
mkdir -p /tmp/home
echo -e "${GREEN}✅ Directories created${NC}"
echo ''

# Copy workspace to container-local location
echo 'Copying workspace to container-local location...'
if [ ! -d /workspace ]; then
    echo -e "${RED}Error: /workspace not found. Ensure docker_linux_ci.sh mounts the repo correctly.${NC}"
    exit 1
fi

rsync -a /workspace/ /tmp/aether3d_src/ --exclude='.build' --exclude='.swiftpm' --exclude='.git' --exclude='artifacts'
echo -e "${GREEN}✅ Workspace copied${NC}"
echo ''

# Set environment variables for SPM
export TMPDIR=/tmp
export HOME=/tmp/home
export SWIFT_PACKAGE_BUILD_DIR=/tmp/aether3d_build

# Change to container-local workspace
cd /tmp/aether3d_src

echo '=========================================='
echo 'Swift Package Manager Setup'
echo '=========================================='
echo "Working directory: $(pwd)"
echo "TMPDIR: $TMPDIR"
echo "HOME: $HOME"
echo "SWIFT_PACKAGE_BUILD_DIR: $SWIFT_PACKAGE_BUILD_DIR"
echo ''

# Clean any existing build artifacts
echo 'Cleaning SPM workspace...'
swift package clean || true
echo -e "${GREEN}✅ Clean completed${NC}"
echo ''

# Resolve dependencies
echo 'Resolving dependencies...'
if ! swift package resolve 2>&1 | tee /tmp/resolve.log; then
    echo -e "${RED}❌ Dependency resolution failed${NC}"
    echo ''
    echo 'Full resolve log:'
    cat /tmp/resolve.log
    exit 1
fi
echo -e "${GREEN}✅ Dependencies resolved${NC}"
echo ''

echo '=========================================='
echo 'Building Package'
echo '=========================================='

# Build package
if ! swift build 2>&1 | tee /tmp/build.log; then
    echo -e "${RED}❌ Build failed${NC}"
    echo ''
    echo 'Last 50 lines of build log:'
    tail -50 /tmp/build.log
    exit 1
fi
echo -e "${GREEN}✅ Build succeeded${NC}"
echo ''

echo '=========================================='
echo 'Running Tests'
echo '=========================================='

# Run tests
if ! swift test 2>&1 | tee /tmp/test.log; then
    echo -e "${RED}❌ Tests failed${NC}"
    echo ''
    echo 'Last 50 lines of test log:'
    tail -50 /tmp/test.log
    exit 1
fi
echo -e "${GREEN}✅ Tests passed${NC}"
echo ''

echo '=========================================='
echo 'Success'
echo '=========================================='
echo 'Build and tests completed successfully'
