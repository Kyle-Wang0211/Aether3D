# Actions Pinning Policy

**Document Version:** 1.0.0  
**Status:** IMMUTABLE  
**Purpose:** Supply-chain hardening through explicit action pinning with audit trail

---

## Overview

All GitHub Actions used in SSOT workflows MUST be pinned to full 40-character commit SHAs. Each pin MUST include an audit comment documenting the original tag, date, and release source.

**Validation:** Enforced by `scripts/ci/validate_actions_pinning_audit_comment.sh` (SSOT-blocking).

---

## Policy Requirements

### 1. Full SHA Pinning

- **Required:** Full 40-character commit SHA
- **Forbidden:** Tags (e.g., `@v1`, `@v2`)
- **Forbidden:** Branches (e.g., `@main`, `@master`)
- **Forbidden:** Partial SHAs

### 2. Audit Comment Format

Every `uses:` line with a SHA MUST have an audit comment on the previous line:

```yaml
# pinned from vX (YYYY-MM-DD)
uses: owner/repo@<full-40-char-sha>
```

**Required Fields:**
- Original tag (e.g., `v1`, `v2`, `v4`)
- Date in ISO format (YYYY-MM-DD)
- Release source (implicit: GitHub Actions releases)

**Example:**
```yaml
# pinned from v4 (2026-01-24)
uses: actions/checkout@34e114876b0b11c390a56381ad16ebd13914f8d5
```

### 3. Scope

- **SSOT Workflows:** Hard fail if audit comment missing
- **Non-SSOT Workflows:** Warning only (recommended but not required)

---

## Validation

The audit comment validator checks:

1. Every `uses:` line with a SHA has a preceding comment line
2. Comment matches pattern: `# pinned from vX (YYYY-MM-DD)`
3. Date is valid ISO format
4. Tag is non-empty

**Integration:**
- `scripts/ci/lint_workflows.sh` (SSOT-blocking)
- `scripts/ci/preflight_ssot_foundation.sh` (SSOT-blocking)

---

## Rationale

1. **Supply-Chain Security:** Full SHA pinning prevents tag hijacking
2. **Audit Trail:** Comments document when and from what version the pin was created
3. **Reproducibility:** Exact commit SHA ensures deterministic builds
4. **Maintenance:** Comments help identify when pins need updates

---

**Last Updated:** 2026-01-24  
**Document Version:** 1.0.0
