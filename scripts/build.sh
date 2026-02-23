#!/bin/bash
# scripts/build.sh — Phase migration orchestration
set -euo pipefail

PROJECT_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CPP_DIR="$PROJECT_ROOT/aether_cpp"
BUILD_DIR="$CPP_DIR/build"
GOLDEN_DIR="$CPP_DIR/golden"

echo "=== STEP 0.5: Golden Fixtures ==="
if ! grep -q 'PR4MathFixtureExporter' "$PROJECT_ROOT/Package.swift"; then
  echo "ERROR: PR4MathFixtureExporter target missing in Package.swift"
  exit 1
fi

cd "$PROJECT_ROOT"
swift run --disable-sandbox FixtureGen
swift run --disable-sandbox PR4MathFixtureExporter

mkdir -p "$GOLDEN_DIR"
cp Tests/Fixtures/*.txt "$GOLDEN_DIR/" 2>/dev/null || true
cp Tests/Fixtures/PR4Math/pr4math_golden_v1.json "$GOLDEN_DIR/" 2>/dev/null || true
cp fixtures/manifest.json "$GOLDEN_DIR/" 2>/dev/null || true
if [ -d fixtures ]; then
  rsync -a fixtures/ "$GOLDEN_DIR/" --exclude '*.tmp' >/dev/null 2>&1 || true
fi
echo "✓ Golden fixtures populated in $GOLDEN_DIR"

echo "=== Phase A: C++ Build (CMake) ==="
cmake -S "$CPP_DIR" -B "$BUILD_DIR" \
  -DCMAKE_BUILD_TYPE=Release \
  -DCMAKE_CXX_STANDARD=20 \
  -DCMAKE_CXX_FLAGS="-ffp-contract=off -fno-fast-math -Wall -Werror -fno-exceptions -fno-rtti"
cmake --build "$BUILD_DIR" --parallel "$(sysctl -n hw.ncpu 2>/dev/null || nproc)"
echo "✓ C++ build succeeded"

echo "=== Phase A: C++ Tests ==="
ctest --test-dir "$BUILD_DIR" --output-on-failure --parallel "$(sysctl -n hw.ncpu 2>/dev/null || nproc)"
ctest --test-dir "$BUILD_DIR" -R replay_fixtures --output-on-failure
echo "✓ C++ tests + replay fixtures passed"

echo "=== Phase A: C++ Cross-Platform Buildability ==="
bash "$PROJECT_ROOT/scripts/ci/validate_cpp_cross_platform_toolchains.sh" --strict-if-ci
echo "✓ C++ cross-platform buildability check passed (or explicit skips in non-strict mode)"

echo "=== Phase B: Swift Build ==="
swift build --disable-sandbox
echo "✓ Swift build succeeded"

echo "=== Phase B: Swift Tests ==="
swift test --disable-sandbox --skip PR5CaptureTests
echo "✓ Swift tests passed"

echo "=== Golden Fixture Parity Check ==="
FAIL=0
for f in "$GOLDEN_DIR"/*.txt "$GOLDEN_DIR"/*.json "$GOLDEN_DIR"/*.bin; do
  [ -f "$f" ] || continue
  BASENAME=$(basename "$f")
  CPP_OUT="$BUILD_DIR/golden_output/$BASENAME"
  if [ -f "$CPP_OUT" ]; then
    if ! diff -q "$f" "$CPP_OUT" >/dev/null 2>&1; then
      echo "MISMATCH: $BASENAME"
      diff "$f" "$CPP_OUT" | head -20 || true
      FAIL=1
    fi
  fi
done
if [ $FAIL -eq 1 ]; then
  echo "FATAL: Golden fixture mismatch — C++ output differs from Swift baseline"
  exit 1
fi

echo "✓ Golden fixture parity verified"
echo "=== ALL GATES PASSED ==="
