#!/bin/bash
# Docker Linux CI Script (Host-Only)
# 
# This script runs Swift build and tests inside a Linux Docker container
# to ensure cross-platform compatibility and avoid SPM permission issues
# when mounting from macOS.
#
# Usage:
#   bash scripts/docker_linux_ci.sh
#
# Requirements:
#   - Docker installed and running (on host)
#   - Repository checked out (run from repo root)
#
# This script MUST run on the host, not inside a container.

set -euo pipefail

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# Detect if we're running inside a container
# This script MUST NOT run inside a container
if [ -f /.dockerenv ] || ( [ -f /proc/self/cgroup ] && grep -q docker /proc/self/cgroup 2>/dev/null ); then
    echo -e "${RED}Error: This script must run on the host, not inside a Docker container${NC}"
    echo ""
    echo "docker_linux_ci.sh is a HOST-ONLY script that launches Docker containers."
    echo "If you need to run CI inside a container, use linux_ci_inner.sh instead."
    echo ""
    echo "Current execution context:"
    echo "  - Container detected: YES"
    echo "  - Expected: NO"
    exit 1
fi

# Script directory and repo root
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

# Docker image
DOCKER_IMAGE="swift:5.9-jammy"

# Artifacts directory (host)
ARTIFACTS_DIR="$REPO_ROOT/artifacts/docker-linux"
mkdir -p "$ARTIFACTS_DIR"

# Path to inner script (will be mounted into container)
INNER_SCRIPT="$SCRIPT_DIR/linux_ci_inner.sh"

# Verify inner script exists
if [ ! -f "$INNER_SCRIPT" ]; then
    echo -e "${RED}Error: Inner script not found: $INNER_SCRIPT${NC}"
    exit 1
fi

# Make inner script executable
chmod +x "$INNER_SCRIPT"

echo "=========================================="
echo "Docker Linux CI for Aether3D"
echo "=========================================="
echo "Repository: $REPO_ROOT"
echo "Docker Image: $DOCKER_IMAGE"
echo "Artifacts: $ARTIFACTS_DIR"
echo "Inner Script: $INNER_SCRIPT"
echo ""

# Check if Docker is available
if ! command -v docker &> /dev/null; then
    echo -e "${RED}Error: Docker is not installed or not in PATH${NC}"
    echo ""
    echo "Please install Docker and ensure it's in your PATH."
    exit 1
fi

# Check if Docker daemon is running
if ! docker info &> /dev/null; then
    echo -e "${RED}Error: Docker daemon is not running${NC}"
    echo ""
    echo "Please start Docker and try again."
    exit 1
fi

# Pull Docker image if needed
echo "Checking Docker image..."
if ! docker image inspect "$DOCKER_IMAGE" &> /dev/null; then
    echo "Pulling Docker image: $DOCKER_IMAGE"
    docker pull "$DOCKER_IMAGE"
else
    echo "Docker image already available"
fi

echo ""
echo "Starting Docker container..."

# Run Docker container with the following strategy:
# 1. Mount repo as read-only to avoid permission issues
# 2. Mount inner script as executable
# 3. Invoke inner script inside container
# 4. Inner script handles: copying workspace, installing deps, building, testing

docker run --rm \
    -v "$REPO_ROOT:/workspace:ro" \
    -v "$INNER_SCRIPT:/linux_ci_inner.sh:ro" \
    -w /tmp \
    "$DOCKER_IMAGE" \
    /bin/bash /linux_ci_inner.sh

EXIT_CODE=$?

# Handle exit code
if [ $EXIT_CODE -eq 0 ]; then
    echo ""
    echo -e "${GREEN}✅ Docker CI completed successfully${NC}"
    echo ""
    echo "Logs (if any) would be saved to: $ARTIFACTS_DIR"
    echo ""
    echo "Note: Build and test logs are printed to stdout above."
    echo "To capture logs to files, redirect docker run output:"
    echo "  bash scripts/docker_linux_ci.sh 2>&1 | tee $ARTIFACTS_DIR/full.log"
else
    echo ""
    echo -e "${RED}❌ Docker CI failed with exit code $EXIT_CODE${NC}"
    echo ""
    echo "Check Docker output above for details."
    echo "Common issues:"
    echo "  - Dependency resolution failures (check network)"
    echo "  - Build errors (check Swift code)"
    echo "  - Test failures (check test output above)"
fi

exit $EXIT_CODE
