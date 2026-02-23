#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$ROOT_DIR"

REQUIRED_VERSION="6.2.3"
FAILURES=0

pass() { echo "✅ $1"; }
fail() { echo "❌ $1"; FAILURES=$((FAILURES + 1)); }

assert_contains() {
  local file="$1"
  local needle="$2"
  local label="$3"
  if grep -Fq "$needle" "$file"; then
    pass "$label"
  else
    fail "$label (missing '$needle' in $file)"
  fi
}

assert_not_contains() {
  local file="$1"
  local needle="$2"
  local label="$3"
  if grep -Fq "$needle" "$file"; then
    fail "$label (found forbidden '$needle' in $file)"
  else
    pass "$label"
  fi
}

validate_all_workflow_swift_pins() {
  local line
  local mismatches=0
  local has_swift_version=0
  local has_swift_env=0

  while IFS= read -r line; do
    has_swift_version=1
    if [[ "$line" != *"${REQUIRED_VERSION}"* ]]; then
      fail "workflow swift-version not pinned to ${REQUIRED_VERSION}: ${line}"
      mismatches=1
    fi
  done < <(rg -n "swift-version:" .github/workflows/*.yml || true)

  while IFS= read -r line; do
    has_swift_env=1
    if [[ "$line" != *"\"${REQUIRED_VERSION}\""* ]]; then
      fail "workflow SWIFT_VERSION not pinned to ${REQUIRED_VERSION}: ${line}"
      mismatches=1
    fi
  done < <(rg -n "\\bSWIFT_VERSION=\\\"[^\\\"]+\\\"" .github/workflows/*.yml || true)

  if [ "$has_swift_version" -eq 0 ]; then
    fail "no workflow swift-version entries found"
    mismatches=1
  fi
  if [ "$has_swift_env" -eq 0 ]; then
    fail "no workflow SWIFT_VERSION assignments found"
    mismatches=1
  fi

  if [ "$mismatches" -eq 0 ]; then
    pass "all workflow swift-version/SWIFT_VERSION entries pinned to ${REQUIRED_VERSION}"
  fi
}

echo "==> Swift ${REQUIRED_VERSION} pinning validation"

assert_contains "Package.swift" "// swift-tools-version: 6.2" "Package tools-version is 6.2 (Swift 6.2.x baseline)"

for lock_file in "toolchain.lock"; do
  assert_contains "$lock_file" "swift_major=6" "$lock_file major pin"
  assert_contains "$lock_file" "swift_minor=2" "$lock_file minor pin"
  assert_contains "$lock_file" "swift_patch=3" "$lock_file patch pin"
done

if [ -f "toolchain 2.lock" ]; then
  assert_contains "toolchain 2.lock" "swift_major=6" "toolchain 2.lock major pin"
  assert_contains "toolchain 2.lock" "swift_minor=2" "toolchain 2.lock minor pin"
  assert_contains "toolchain 2.lock" "swift_patch=3" "toolchain 2.lock patch pin"
else
  echo "ℹ️ toolchain 2.lock not present; skipped optional shadow lock check"
fi

assert_contains ".github/workflows/ci.yml" "swift-version: \"6.2.3\"" "ci.yml matrix pin"
assert_contains ".github/workflows/quality_precheck.yml" "swift-version: [\"6.2.3\"]" "quality_precheck.yml matrix pin"
assert_contains ".github/workflows/pr1_v24_cross_platform.yml" "swift-version: \"6.2.3\"" "pr1_v24_cross_platform.yml matrix pin"
validate_all_workflow_swift_pins

assert_not_contains ".github/workflows/ci.yml" "swift-version: \"6.2\"" "ci.yml forbids loose 6.2 pin"
assert_not_contains ".github/workflows/quality_precheck.yml" "swift-version: [\"6.2\"]" "quality_precheck.yml forbids loose 6.2 pin"
assert_not_contains ".github/workflows/pr1_v24_cross_platform.yml" "swift-version: \"6.2\"" "pr1_v24_cross_platform.yml forbids loose 6.2 pin"

assert_contains "scripts/docker_linux_ci.sh" "DOCKER_IMAGE=\"swift:6.2.3-jammy\"" "docker_linux_ci.sh image pin"
assert_contains "scripts/ci/run_linux_spm_matrix.sh" "SWIFT_VERSION=\"\${SWIFT_VERSION:-6.2.3}\"" "run_linux_spm_matrix.sh default pin"
assert_not_contains "scripts/pre-push-verify.sh" "CI uses Swift 5.9.2" "pre-push message updated"
assert_contains "scripts/pre-push-verify.sh" "Swift version must be exactly 6.2.3" "pre-push hard pin check"

if command -v swift >/dev/null 2>&1; then
  SWIFT_VERSION_OUTPUT="$(swift --version 2>&1 || true)"
  if echo "$SWIFT_VERSION_OUTPUT" | grep -Eq "Apple Swift version ${REQUIRED_VERSION}|Swift version ${REQUIRED_VERSION}"; then
    pass "runtime swift --version is ${REQUIRED_VERSION}"
  else
    fail "runtime swift --version is not ${REQUIRED_VERSION}"
    echo "$SWIFT_VERSION_OUTPUT" | head -n 2 | sed 's/^/   /'
  fi
else
  echo "ℹ️ swift not found in PATH; skipped runtime version check"
fi

if command -v xcrun >/dev/null 2>&1; then
  XCRUN_SWIFT_OUTPUT="$(xcrun swift --version 2>&1 || true)"
  if echo "$XCRUN_SWIFT_OUTPUT" | grep -Eq "Apple Swift version ${REQUIRED_VERSION}|Swift version ${REQUIRED_VERSION}"; then
    pass "runtime xcrun swift --version is ${REQUIRED_VERSION}"
  else
    fail "runtime xcrun swift --version is not ${REQUIRED_VERSION}"
    echo "$XCRUN_SWIFT_OUTPUT" | head -n 2 | sed 's/^/   /'
  fi
fi

if [ "$FAILURES" -ne 0 ]; then
  echo "==> Swift ${REQUIRED_VERSION} pinning gate FAILED (${FAILURES} finding(s))"
  exit 1
fi

echo "==> Swift ${REQUIRED_VERSION} pinning gate PASSED"
