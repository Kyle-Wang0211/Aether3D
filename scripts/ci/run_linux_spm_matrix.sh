#!/bin/bash
# run_linux_spm_matrix.sh
# Linux cross-platform validation using Docker
# Ensures SSOT contracts compile and tests run under Linux Swift toolchain

set -euo pipefail

REPO_ROOT="${1:-$(git rev-parse --show-toplevel)}"
cd "$REPO_ROOT" || exit 1

SWIFT_VERSION="${SWIFT_VERSION:-6.0}"
DOCKER_IMAGE="swift:${SWIFT_VERSION}"

echo "🐧 Linux SPM Matrix Validation"
echo "==============================="
echo "Swift Version: $SWIFT_VERSION"
echo "Docker Image: $DOCKER_IMAGE"
echo ""

# Check if Docker is available
if ! command -v docker &> /dev/null; then
    echo "⚠️  Docker not found. Skipping Linux validation."
    echo "   Install Docker to enable Linux cross-platform checks."
    exit 0
fi

# Check if Docker daemon is running
if ! docker info &> /dev/null; then
    echo "⚠️  Docker daemon not running. Skipping Linux validation."
    echo "   Start Docker to enable Linux cross-platform checks."
    exit 0
fi

echo "Running Linux build and tests in Docker container..."
echo ""

# Run Linux build and tests
docker run --rm \
    -v "$REPO_ROOT:/workspace" \
    -w /workspace \
    -e LC_ALL=en_US.UTF-8 \
    -e LANG=en_US.UTF-8 \
    -e TZ=UTC \
    "$DOCKER_IMAGE" \
    bash -c "
        set -euo pipefail
        echo '🔍 Swift Version:'
        swift --version
        echo ''
        echo '📦 Resolving dependencies...'
        swift package resolve
        echo ''
        echo '🔨 Building Debug...'
        swift build -c debug
        echo ''
        echo '🔨 Building Release...'
        swift build -c release
        echo ''
        echo '🧪 Running SSOT Foundation tests...'
        swift test -c debug \
            --filter EnumFrozenOrderTests \
            --filter CatalogSchemaTests \
            --filter DocumentationSyncTests \
            --filter DeterministicEncodingContractTests \
            --filter DeterministicQuantizationContractTests \
            --filter GoldenVectorsRoundTripTests \
            --filter ColorMatrixIntegrityTests \
            --filter DomainPrefixesTests \
            --filter ReproducibilityBoundaryTests \
            --filter BreakingSurfaceTests \
            --filter ExplanationCatalogCoverageTests \
            --filter ReasonCompatibilityTests \
            --filter MinimumExplanationSetTests \
            --filter CatalogUniquenessTests \
            --filter ExplanationIntegrityTests \
            --filter CatalogCrossReferenceTests \
            --filter CatalogActionabilityRulesTests \
            --filter DomainPrefixesClosureTests || {
            echo ''
            echo '❌ Linux tests failed'
            exit 1
        }
        echo ''
        echo '✅ Linux build and tests passed'
    "

EXIT_CODE=$?

if [ $EXIT_CODE -eq 0 ]; then
    echo ""
    echo "✅ Linux SPM matrix validation passed"
    exit 0
else
    echo ""
    echo "❌ Linux SPM matrix validation failed"
    exit 1
fi
