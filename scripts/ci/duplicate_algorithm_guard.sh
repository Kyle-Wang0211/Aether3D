#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
FAILED=0

require_contains() {
  local file="$1"
  local pattern="$2"
  local label="$3"
  if ! rg -n --fixed-strings "$pattern" "$file" >/dev/null 2>&1; then
    echo "duplicate-guard: FAIL [$label] missing pattern '$pattern' in $file"
    FAILED=1
  else
    echo "duplicate-guard: PASS [$label]"
  fi
}

require_not_contains() {
  local file="$1"
  local pattern="$2"
  local label="$3"
  if rg -n --fixed-strings "$pattern" "$file" >/dev/null 2>&1; then
    echo "duplicate-guard: FAIL [$label] found forbidden pattern '$pattern' in $file"
    FAILED=1
  else
    echo "duplicate-guard: PASS [$label]"
  fi
}

check_file() {
  local path="$1"
  if [[ ! -f "$path" ]]; then
    echo "duplicate-guard: FAIL missing file $path"
    FAILED=1
  fi
}

MC_FILE="$REPO_ROOT/Core/TSDF/MarchingCubes.swift"
INTEGRATION_FILE="$REPO_ROOT/Core/TSDF/CPUIntegrationBackend.swift"
ADJ_FILE="$REPO_ROOT/Core/Quality/Geometry/SpatialHashAdjacency.swift"
TRIANGULATOR_FILE="$REPO_ROOT/Core/Quality/Geometry/DeterministicTriangulator.swift"
TRI_TET_FILE="$REPO_ROOT/Core/Quality/Geometry/TriTetConsistencyEngine.swift"

check_file "$MC_FILE"
check_file "$INTEGRATION_FILE"
check_file "$ADJ_FILE"
check_file "$TRIANGULATOR_FILE"
check_file "$TRI_TET_FILE"

if [[ $FAILED -ne 0 ]]; then
  exit 1
fi

# Stage-0 migration hard contracts: Swift orchestrates, C++ owns kernels.
require_contains "$MC_FILE" "NativeMarchingCubesBridge.run" "mc-bridge"
require_not_contains "$MC_FILE" "static let edgeTable" "mc-no-local-edgetable"
require_not_contains "$MC_FILE" "static let triTable" "mc-no-local-tritable"

require_contains "$INTEGRATION_FILE" "aether_tsdf_integrate_external_blocks" "integration-bridge"
require_not_contains "$INTEGRATION_FILE" "for x in 0..<TSDFConstants.blockSize" "integration-no-local-voxel-loop"
require_not_contains "$INTEGRATION_FILE" "tsdTransform(worldToCamera" "integration-no-local-projection"

require_contains "$ADJ_FILE" "aether_spatial_adjacency_build" "adjacency-bridge"
require_contains "$TRIANGULATOR_FILE" "aether_deterministic_triangulate_quad" "triangulator-bridge"
require_contains "$TRI_TET_FILE" "aether_tri_tet_evaluate" "tritet-bridge"

if [[ $FAILED -ne 0 ]]; then
  echo "duplicate-guard: FAILED"
  exit 1
fi

echo "duplicate-guard: PASSED"
exit 0
