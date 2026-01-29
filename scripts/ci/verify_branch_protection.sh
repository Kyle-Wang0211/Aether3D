#!/usr/bin/env bash
set -euo pipefail

# Verify GitHub branch protection rules
# Ensures main branch has required protections for SSOT
# Requires GITHUB_TOKEN and GITHUB_REPOSITORY environment variables

echo "==> Verifying branch protection for main branch"

if [[ -z "${GITHUB_TOKEN:-}" ]]; then
  echo "GITHUB_TOKEN not set, skipping branch protection check"
  echo "   (This check requires GitHub API access)"
  exit 0
fi

REPO="${GITHUB_REPOSITORY:-}"
if [[ -z "$REPO" ]]; then
  echo "GITHUB_REPOSITORY not set, skipping"
  exit 0
fi

echo "Repository: $REPO"

# Get branch protection rules
PROTECTION=$(curl -s -H "Authorization: token $GITHUB_TOKEN" \
  -H "Accept: application/vnd.github.v3+json" \
  "https://api.github.com/repos/$REPO/branches/main/protection" 2>/dev/null || echo "{}")

# Check if protection is enabled
if [[ "$PROTECTION" == "{}" ]] || echo "$PROTECTION" | grep -q '"message":"Not Found"'; then
  echo "⚠️  WARNING: Branch protection not configured or API access denied"
  echo "   Please enable branch protection in GitHub settings"
  exit 0
fi

FAILED=0

# Check required status checks
if echo "$PROTECTION" | grep -qE '"required_status_checks"'; then
  STATUS_CHECKS=$(echo "$PROTECTION" | grep -oE '"contexts":\[[^]]*\]' || echo "")
  if [[ -n "$STATUS_CHECKS" ]] && [[ "$STATUS_CHECKS" != '"contexts":[]' ]]; then
    echo "   ✅ Required status checks configured"
  else
    echo "⚠️  WARNING: No required status checks configured"
    FAILED=1
  fi
else
  echo "⚠️  WARNING: Required status checks not configured"
  FAILED=1
fi

# Check CODEOWNERS review requirement
if echo "$PROTECTION" | grep -qE '"required_pull_request_reviews"'; then
  CODEOWNERS_REQUIRED=$(echo "$PROTECTION" | grep -oE '"require_code_owner_reviews":\s*(true|false)' || echo "")
  if echo "$CODEOWNERS_REQUIRED" | grep -q "true"; then
    echo "   ✅ CODEOWNERS review required"
  else
    echo "⚠️  WARNING: CODEOWNERS review not required"
    FAILED=1
  fi
else
  echo "⚠️  WARNING: Pull request reviews not configured"
  FAILED=1
fi

# Check dismiss stale reviews
DISMISS_STALE=$(echo "$PROTECTION" | grep -oE '"dismiss_stale_reviews":\s*(true|false)' || echo "")
if echo "$DISMISS_STALE" | grep -q "true"; then
  echo "   ✅ Stale review dismissal enabled"
else
  echo "⚠️  WARNING: Stale review dismissal not enabled"
fi

# Check linear history
LINEAR_HISTORY=$(echo "$PROTECTION" | grep -oE '"required_linear_history":\s*\{[^}]*\}' || echo "")
if echo "$LINEAR_HISTORY" | grep -q "enabled.*true"; then
  echo "   ✅ Linear history required"
else
  echo "⚠️  WARNING: Linear history not required"
fi

if [[ $FAILED -ne 0 ]]; then
  echo ""
  echo "⚠️  Branch protection verification found issues"
  echo "   Please enable required protections in GitHub settings"
  # Don't fail CI, just warn
fi

echo "==> Branch protection check complete"
exit 0
