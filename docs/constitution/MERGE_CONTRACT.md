# Merge Contract

**Document Version:** 1.0.0  
**Status:** IMMUTABLE  
**Purpose:** Explicit contract defining which CI checks must pass for merge to be allowed

---

## Overview

This document defines the **merge contract**: the set of CI checks that must pass for a Pull Request to be mergeable. A green CI status MUST imply mergeability. This contract prevents "green CI but merge blocked" scenarios.

---

## Merge-Blocking Workflows

### Required Workflow: `ssot-foundation-ci.yml`

**Status:** REQUIRED (merge-blocking)  
**Trigger:** `pull_request` events  
**Purpose:** SSOT Foundation validation (constitutional gates, determinism, trust)

#### Required Jobs (Must Exist and Pass)

1. **`gate_0_workflow_lint`**
   - **Purpose:** Workflow structure and syntax validation
   - **Must run on:** `pull_request` events
   - **Must pass:** Yes (blocking)

2. **`gate_linux_preflight_only`**
   - **Purpose:** Linux-specific preflight checks
   - **Must run on:** `pull_request` events (Linux matrix entries)
   - **Must pass:** Yes (blocking)

3. **`gate_1_constitutional`**
   - **Purpose:** Constitutional invariants (enum order, catalog schema, golden vectors)
   - **Must run on:** `pull_request` events
   - **Must pass:** Yes (blocking)

4. **`gate_2_determinism_trust`**
   - **Purpose:** Determinism, reproducibility, user trust (cross-platform consistency)
   - **Must run on:** `pull_request` events
   - **Must pass:** Yes (blocking)

5. **`golden_vector_governance`**
   - **Purpose:** Golden vector change detection
   - **Must run on:** `pull_request` events
   - **Must pass:** Yes (blocking)

#### Explicitly Non-Blocking Jobs

1. **`gate_2_linux_native_crypto_experiment`**
   - **Purpose:** Experimental telemetry (native crypto backend stability monitoring)
   - **Must run on:** `workflow_dispatch` or `schedule` ONLY (never `pull_request`)
   - **Must pass:** No (non-blocking, `continue-on-error: true`)
   - **Permissions:** Read-only
   - **Status:** Does NOT appear in merge contract

---

## Non-SSOT Workflows (Not Merge-Blocking)

The following workflows exist but are NOT part of the merge contract:

- `ci.yml` - General CI (non-blocking)
- `ci-gate.yml` - CI gate (non-blocking)
- `quality_precheck.yml` - Quality checks (non-blocking)

These workflows may run but their failure does not block merge.

---

## Contract Enforcement

### Required Checks

For a PR to be mergeable, ALL of the following must be true:

1. ✅ `gate_0_workflow_lint` job exists and passes
2. ✅ `gate_linux_preflight_only` job exists and passes (Linux matrix entries)
3. ✅ `gate_1_constitutional` job exists and passes
4. ✅ `gate_2_determinism_trust` job exists and passes
5. ✅ `golden_vector_governance` job exists and passes
6. ✅ All required jobs are reachable on `pull_request` events
7. ✅ No required job is gated behind `workflow_dispatch` or `schedule` only

### Validation

The merge contract is enforced by:
- `scripts/ci/validate_merge_contract.sh` - Validates contract compliance
- Integrated into `lint_workflows.sh` (SSOT blocking)
- Integrated into `preflight_ssot_foundation.sh`

---

## Job Name Stability

Required job names MUST remain stable. Renaming a required job breaks the merge contract and must be:
1. Documented in this contract
2. Coordinated with branch protection rules
3. Validated by `validate_merge_contract.sh`

---

## Event Triggers

Required jobs MUST be triggered by `pull_request` events. If a required job has an `if:` condition that prevents it from running on `pull_request`, the contract is violated.

---

## Experimental Jobs

Experimental jobs (e.g., `gate_2_linux_native_crypto_experiment`) are explicitly excluded from the merge contract. They:
- Must NOT run on `pull_request` by default
- Must have `continue-on-error: true`
- Must have read-only permissions
- Must be clearly labeled "NON-BLOCKING TELEMETRY"

---

## Contract Changes

To modify this contract:
1. Update this document
2. Update `validate_merge_contract.sh` to reflect new requirements
3. Ensure branch protection rules align with the contract
4. Document the change in `CHANGELOG.md`

---

**Last Updated:** 2026-01-24  
**Contract Version:** 1.0.0
