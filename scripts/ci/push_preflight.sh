#!/usr/bin/env bash
# Push preflight check script
# WHY: Completely isolated bash environment to avoid zsh hooks (RPROMPT, __vsc_preexec, etc.)
#      that can cause set -u failures. This script runs all push-related checks
#      in a clean bash subprocess, completely isolated from zsh hooks.
#
# Usage: bash scripts/ci/push_preflight.sh
# Exit code: 0 if all checks pass, non-zero otherwise

# WHY: set -euo pipefail must be INSIDE bash script, not in zsh hook context
set -euo pipefail

# Step 0: Sanitize environment (avoid inheriting zsh hooks/variables)
# WHY: Prevent RPROMPT, __vsc_update_prompt, __vsc_preexec, PROMPT_COMMAND, etc.
#      from causing set -u failures. Unset all zsh/bash prompt-related variables.
export LC_ALL=C
export LANG=C
export TZ=UTC
unset RPROMPT 2>/dev/null || true
unset PROMPT_COMMAND 2>/dev/null || true
unset PROMPT 2>/dev/null || true
unset PS1 2>/dev/null || true
unset RPS1 2>/dev/null || true
unset ZDOTDIR 2>/dev/null || true
unset BASH_ENV 2>/dev/null || true
unset ENV 2>/dev/null || true
unset SHELLOPTS 2>/dev/null || true

# Get repo root
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$REPO_ROOT"

# Diagnostic header (for future troubleshooting)
echo "=== PUSH PREFLIGHT CHECK (isolated bash environment) ==="
echo ""
echo "--- Diagnostic Header ---"
date -u
whoami
uname -a
echo "SHELL=${SHELL:-<unset>}"
[ -n "${ZSH_VERSION:-}" ] && echo "ZSH_VERSION=${ZSH_VERSION}" || echo "ZSH_VERSION=<not zsh>"
echo "TERM_PROGRAM=${TERM_PROGRAM:-<unset>}"
[ -n "${VSCODE_GIT_ASKPASS:-}" ] && echo "VSCODE_GIT_ASKPASS=${VSCODE_GIT_ASKPASS}" || echo "VSCODE_GIT_ASKPASS=<unset>"
git --version
command -v swift >/dev/null && swift --version || echo "swift: not found"
command -v xcodebuild >/dev/null && xcodebuild -version 2>/dev/null || echo "xcodebuild: not found"
git config --get core.hooksPath 2>/dev/null || echo "core.hooksPath: <not set or error>"
echo "--- End Diagnostic Header ---"
echo ""

# Step 0: SSOT declaration check
echo "[0/3] SSOT declaration check"
bash scripts/ci/ssot_declaration_check.sh || {
    echo "❌ SSOT declaration check FAILED"
    exit 1
}
echo "✅ SSOT declaration check passed"
echo ""

# Step 1: YAML static parsing
echo "[1/3] YAML static parsing"
python3 <<'PY'
import yaml
import sys
files = [
    ".github/workflows/ci.yml",
    ".github/workflows/ci-gate.yml",
    ".github/workflows/quality_precheck.yml"
]
for p in files:
    try:
        yaml.safe_load(open(p, "r", encoding="utf-8"))
        print(f"✅ YAML parse OK: {p}")
    except Exception as e:
        print(f"❌ YAML parse FAIL: {p}: {e}", file=sys.stderr)
        sys.exit(1)
PY
echo ""

# Step 2: SwiftPM checks
echo "[2/3] SwiftPM: package resolve"
swift package resolve
echo "✅ swift package resolve passed"
echo ""

# Retired steps (previously [3/6] build, [4/6] test, [5/6] PIZ gate):
# - `swift build`: the Aether3DCore Swift package cannot compile on any
#   platform. Since the initial commit a500df5, Core/Pipeline/PipelineRunner.swift
#   has referenced types that are defined nowhere in the repository history
#   (WhiteboxFileDescriptor, WhiteboxArtifactManifest, ...), and the target
#   has never excluded that file. On macOS it additionally fails on ARKit
#   and Firebase PhoneAuthProvider, and MetalSplatter 1.0.1 requires
#   macOS 15 while Package.swift declares macOS 13. The product now ships
#   through aether_cpp; `swift package resolve` above still guards the
#   .deps submodules and vendor patches.
# - `swift test --filter PIZ` (x2) and scripts/ci/piz_local_gate.sh: commit
#   d5f5646 (2026-04-01) deleted the PIZ subsystem they check (Core/PIZ/,
#   Core/Evidence/PIZ/, Core/Constants/PIZ*.swift) along with its
#   Package.swift targets: the only remaining test target
#   (Tests/Aether3DCoreTests) has no PIZ tests, and PIZFixtureDumper /
#   PIZSealingEvidence are no longer SwiftPM products.

# Step 3: SSOT integrity verification
echo "[3/3] SSOT integrity verification"
bash scripts/ci/ssot_integrity_verify.sh || {
    echo "❌ SSOT integrity check FAILED"
    exit 1
}
echo "✅ SSOT integrity check passed"
echo ""

# Step 7: actionlint (optional)
echo "[Optional] actionlint check"
if command -v actionlint >/dev/null 2>&1; then
    actionlint -color || {
        echo "⚠️  actionlint found issues (non-blocking)"
    }
else
    echo "⚠️  actionlint not found, skipping (non-blocking)"
fi
echo ""

# Step 5: Git status summary
echo "=== Git Status Summary ==="
git status -sb
echo ""
git diff --stat || echo "(no changes)"
echo ""

echo "✅ ALL PREFLIGHT CHECKS PASSED"
exit 0
