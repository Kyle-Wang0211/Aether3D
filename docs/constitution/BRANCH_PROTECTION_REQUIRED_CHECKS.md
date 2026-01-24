# Branch Protection Required Checks

**Document Version:** 1.0.0  
**Status:** IMMUTABLE  
**Purpose:** Explicit documentation of required checks for GitHub branch protection rules

---

## Overview

This document defines the exact job names that must be configured as "required" in GitHub branch protection settings. This prevents "merge blocked by GitHub UI drift" scenarios where branch protection rules diverge from repository merge contract logic.

**Validation:** This document is validated against `MERGE_CONTRACT.md` by `scripts/ci/validate_required_checks_doc_matches_merge_contract.sh` (SSOT-blocking).

---

## WHITEBOX Mode Required Checks

**Mode:** `SSOT_MERGE_CONTRACT_MODE=WHITEBOX` (default)

### Required Checks (Exact Job Names)

The following job names **MUST** be configured as required in GitHub branch protection:

1. `gate_0_workflow_lint`
2. `gate_linux_preflight_only`
3. `gate_1_constitutional`
4. `gate_2_determinism_trust`
5. `golden_vector_governance`

### Forbidden Required Checks

The following job names **MUST NOT** be configured as required in GitHub branch protection (they are telemetry/non-blocking):

- `gate_2_determinism_trust_linux_telemetry` (telemetry, non-blocking)
- `gate_2_linux_hosted_telemetry` (legacy telemetry, non-blocking)
- `gate_2_linux_native_crypto_experiment` (experimental, non-blocking)

---

## PRODUCTION Mode Required Checks

**Mode:** `SSOT_MERGE_CONTRACT_MODE=PRODUCTION`

### Required Checks (Exact Job Names)

The following job names **MUST** be configured as required in GitHub branch protection:

1. `gate_0_workflow_lint`
2. `gate_linux_preflight_only`
3. `gate_1_constitutional`
4. `gate_2_determinism_trust`
5. `gate_2_determinism_trust_linux_self_hosted`
6. `golden_vector_governance`

### Forbidden Required Checks

The following job names **MUST NOT** be configured as required in GitHub branch protection:

- `gate_2_determinism_trust_linux_telemetry` (telemetry, not used in PRODUCTION)
- `gate_2_linux_hosted_telemetry` (legacy telemetry, not used in PRODUCTION)
- `gate_2_linux_native_crypto_experiment` (experimental, non-blocking)

---

## Validation

This document is automatically validated against `MERGE_CONTRACT.md` by:

- `scripts/ci/validate_required_checks_doc_matches_merge_contract.sh`
- Integrated into `scripts/ci/lint_workflows.sh` (SSOT-blocking)
- Integrated into `scripts/ci/preflight_ssot_foundation.sh` (SSOT-blocking)

If this document diverges from the merge contract, validation will fail.

---

**Last Updated:** 2026-01-24  
**Document Version:** 1.0.0
