# Merge Contract

**Document Version:** 1.0.0  
**Status:** IMMUTABLE  
**Purpose:** Explicit contract defining which CI checks must pass for merge to be allowed

---

## Overview

This document defines the **merge contract**: the set of CI checks that must pass for a Pull Request to be mergeable. A green CI status MUST imply mergeability. This contract prevents "green CI but merge blocked" scenarios.

**Current Mode:** WHITEBOX (temporary, see Whitebox Merge Contract section below)

---

## Closed-World Merge Contract Modes

**Status:** IMMUTABLE  
**Purpose:** Explicit, closed-world enumeration of merge contract modes

### Mode Enumeration

The merge contract operates in exactly one of two modes (closed-world enum):

1. **WHITEBOX** (default)
   - **Purpose:** Restore merge connectivity during Whitebox stage
   - **Default:** Yes (if `SSOT_MERGE_CONTRACT_MODE` is unset)
   - **Required Jobs:**
     - `gate_0_workflow_lint`
     - `gate_linux_preflight_only`
     - `gate_1_constitutional` (macOS)
     - `gate_2_determinism_trust` (macOS)
     - `golden_vector_governance`
   - **Forbidden Required Jobs:**
     - `gate_2_determinism_trust_linux_self_hosted` (must NOT be required)
   - **Telemetry Jobs (Non-Blocking):**
     - `gate_2_determinism_trust_linux_telemetry` (must have `continue-on-error: true`)
     - `gate_2_linux_hosted_telemetry` (legacy, non-blocking)
     - `gate_2_linux_native_crypto_experiment` (experimental, non-blocking)

2. **PRODUCTION**
   - **Purpose:** Full production merge contract with stable runner infrastructure
   - **Default:** No (must be explicitly set via `SSOT_MERGE_CONTRACT_MODE=PRODUCTION`)
   - **Required Jobs:**
     - `gate_0_workflow_lint`
     - `gate_linux_preflight_only`
     - `gate_1_constitutional` (macOS)
     - `gate_2_determinism_trust` (macOS)
     - `gate_2_determinism_trust_linux_self_hosted` (Linux, self-hosted runner)
     - `golden_vector_governance`
   - **Forbidden Required Jobs:**
     - `gate_2_determinism_trust_linux_telemetry` (must NOT be required)
   - **Telemetry Jobs:**
     - None (all jobs are blocking in PRODUCTION mode)

### Mode Validation

- Any value other than `WHITEBOX` or `PRODUCTION` for `SSOT_MERGE_CONTRACT_MODE` will cause validation to hard fail immediately.
- Mode is validated by `scripts/ci/validate_merge_contract.sh` (SSOT-blocking).

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
   - **Linux execution:** Uses self-hosted runner with deterministic baseline CPU (`[self-hosted, linux, x86_64, ssot-gate2]`)
   - **macOS execution:** Uses GitHub-hosted runner (`macos-14`)

6. **`golden_vector_governance`**
   - **Purpose:** Golden vector change detection
   - **Must run on:** `pull_request` events
   - **Must pass:** Yes (blocking)

#### Explicitly Non-Blocking Jobs

1. **`gate_2_linux_hosted_telemetry`**
   - **Purpose:** Telemetry (GitHub-hosted runner drift and SIGILL frequency monitoring)
   - **Must run on:** `pull_request` events (but non-blocking)
   - **Must pass:** No (non-blocking, `continue-on-error: true`)
   - **Permissions:** Read-only
   - **Status:** Does NOT appear in merge contract (telemetry only)

2. **`gate_2_linux_native_crypto_experiment`**
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

### Required Checks (Production Mode)

For a PR to be mergeable in Production mode, ALL of the following must be true:

1. ✅ `gate_0_workflow_lint` job exists and passes
2. ✅ `gate_linux_preflight_only` job exists and passes (Linux matrix entries)
3. ✅ `gate_1_constitutional` job exists and passes
4. ✅ `gate_2_determinism_trust` job exists and passes (macOS)
5. ✅ `gate_2_determinism_trust_linux_self_hosted` job exists and passes (Linux, deterministic executor)
6. ✅ `golden_vector_governance` job exists and passes
7. ✅ All required jobs are reachable on `pull_request` events
8. ✅ No required job is gated behind `workflow_dispatch` or `schedule` only

**Note:** In Whitebox mode, Linux Gate 2 is non-blocking. See "Whitebox Merge Contract" section above.

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

---

## Whitebox Merge Contract (Temporary)

**Status:** ACTIVE (temporary during Whitebox stage)  
**Purpose:** Restore merge connectivity while preserving telemetry and guardrails  
**Rationale:** GitHub-hosted Linux runner environmental drift (SIGILL) is not controllable without self-hosted runner infrastructure. During Whitebox, we preserve full telemetry and all guardrails but do not block merge on environmental failures.

### Required Jobs for Merge (Whitebox Mode)

During Whitebox, the following jobs MUST exist and pass for merge:

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
   - **Note:** Runs on macOS (Linux portion not required for merge in Whitebox)

4. **`gate_2_determinism_trust`**
   - **Purpose:** Determinism, reproducibility, user trust (macOS cross-platform consistency)
   - **Must run on:** `pull_request` events
   - **Must pass:** Yes (blocking)
   - **Execution:** macOS only (`macos-14`)

5. **`golden_vector_governance`**
   - **Purpose:** Golden vector change detection
   - **Must run on:** `pull_request` events
   - **Must pass:** Yes (blocking)

### Explicitly Non-Required Jobs (Whitebox Mode)

The following jobs run but do NOT block merge during Whitebox:

1. **`gate_2_determinism_trust_linux_telemetry`** (or `gate_2_linux_hosted_telemetry`)
   - **Purpose:** Linux Gate 2 telemetry (environmental drift and SIGILL monitoring)
   - **Must run on:** `pull_request` events (but non-blocking)
   - **Must pass:** No (non-blocking, `continue-on-error: true`)
   - **Status:** Telemetry only - preserves full hardening, policy tests, SIGILL classification
   - **Rationale:** GitHub-hosted Linux runner CPU micro-architecture drift causes SIGILL that we cannot control. Telemetry preserves diagnostic value without blocking merge.

2. **`gate_2_linux_native_crypto_experiment`**
   - **Purpose:** Experimental telemetry (native crypto backend stability monitoring)
   - **Must run on:** `workflow_dispatch` or `schedule` ONLY (never `pull_request`)
   - **Must pass:** No (non-blocking, `continue-on-error: true`)
   - **Status:** Already non-blocking

### Re-enable as Required Checklist (Production Mode)

When stable runner infrastructure is available, re-enable Linux Gate 2 as blocking by:

1. ✅ Set `SSOT_MERGE_CONTRACT_MODE=PRODUCTION` (or remove WHITEBOX mode)
2. ✅ Update `validate_merge_contract.sh` to require Linux Gate 2 blocking job
3. ✅ Update GitHub branch protection rules to require Linux Gate 2 job
4. ✅ Update this document to reflect Production merge contract
5. ✅ Verify self-hosted runner or stable GitHub-hosted baseline is available
6. ✅ Test merge connectivity with Linux Gate 2 blocking

**Note:** This is NOT a freeze. It is a staged governance approach that:
- Preserves all telemetry and diagnostics
- Maintains all guardrails and policy tests
- Keeps SIGILL classification exclusive
- Allows merge connectivity during Whitebox
- Provides clear path to re-enable blocking Linux Gate 2

---

**Last Updated:** 2026-01-24  
**Contract Version:** 1.0.0  
**Current Mode:** WHITEBOX
