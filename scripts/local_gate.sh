#!/usr/bin/env bash
set -euo pipefail

# CI-HARDENED: Local gate with zero-dependency guarantee (no brew/ripgrep required).
# Supports --quick mode for fast local validation.

QUICK_MODE=0
if [[ "${1:-}" == "--quick" ]]; then
  QUICK_MODE=1
fi

echo "=========================================="
echo "  LOCAL CI GATE"
echo "=========================================="
if [[ "$QUICK_MODE" -eq 1 ]]; then
  echo "  Mode: QUICK (fast validation only)"
else
  echo "  Mode: FULL (complete validation)"
fi
echo ""

# ============================================================
# Prerequisite checks (closed-world, fail-fast)
# ============================================================
echo "==> Checking prerequisites..."

MISSING_DEPS=()

if ! command -v swift &> /dev/null; then
  MISSING_DEPS+=("swift")
fi

if ! command -v git &> /dev/null; then
  MISSING_DEPS+=("git")
fi

if ! command -v grep &> /dev/null; then
  MISSING_DEPS+=("grep")
fi

if [[ ${#MISSING_DEPS[@]} -ne 0 ]]; then
  echo "❌ Missing required commands: ${MISSING_DEPS[*]}"
  echo ""
  echo "Install hints:"
  for dep in "${MISSING_DEPS[@]}"; do
    case "$dep" in
      swift)
        echo "  - swift: Install Xcode Command Line Tools: xcode-select --install"
        ;;
      git)
        echo "  - git: Install Xcode Command Line Tools: xcode-select --install"
        ;;
      grep)
        echo "  - grep: Should be available by default. Check PATH."
        ;;
    esac
  done
  exit 1
fi

echo "✅ All prerequisites available"
echo ""

# ============================================================
# Quick mode: fast validation only
# ============================================================
if [[ "$QUICK_MODE" -eq 1 ]]; then
  echo "==> [QUICK] Running fast validation checks..."
  echo ""
  
  # 1. Fatal pattern scan
  echo "==> [1/3] prohibit_fatal_patterns"
  if ./scripts/ci/02_prohibit_fatal_patterns.sh; then
    echo "✅ PASSED"
  else
    echo "❌ FAILED"
    exit 1
  fi
  echo ""
  
  # 2. SSOT declaration check
  echo "==> [2/3] require_ssot_declaration"
  if ./scripts/ci/03_require_ssot_declaration.sh; then
    echo "✅ PASSED"
  else
    echo "❌ FAILED"
    exit 1
  fi
  echo ""
  
  # 3. Static scan tests
  echo "==> [3/3] CaptureStaticScanTests"
  if swift test --filter CaptureStaticScanTests 2>&1; then
    echo "✅ PASSED"
  else
    echo "❌ FAILED"
    exit 1
  fi
  echo ""
  
  echo "=========================================="
  echo "  LOCAL CI GATE (QUICK) PASSED"
  echo "=========================================="
  exit 0
fi

# ============================================================
# Full mode: complete validation
# ============================================================
echo "==> [FULL] Running complete validation..."
echo ""

# 1. Fatal pattern scan
echo "==> [1/4] prohibit_fatal_patterns"
if ./scripts/ci/02_prohibit_fatal_patterns.sh; then
  echo "✅ PASSED"
else
  echo "❌ FAILED"
  exit 1
fi
echo ""

# 2. SSOT declaration check
echo "==> [2/4] require_ssot_declaration"
if ./scripts/ci/03_require_ssot_declaration.sh; then
  echo "✅ PASSED"
else
  echo "❌ FAILED"
  exit 1
fi
echo ""

# 3. Static scan tests
echo "==> [3/4] CaptureStaticScanTests"
if swift test --filter CaptureStaticScanTests 2>&1; then
  echo "✅ PASSED"
else
  echo "❌ FAILED"
  exit 1
fi
echo ""

# 4. Full build
echo "==> [4/4] swift build"
if swift build 2>&1; then
  echo "✅ PASSED"
else
  echo "❌ FAILED"
  exit 1
fi
echo ""

echo "=========================================="
echo "  LOCAL CI GATE (FULL) PASSED"
echo "=========================================="
