# Protocol Governance Engineering (Extreme Edition)

This directory is the machine-executable governance layer for the Aether3D pipeline.
It converts architectural rules into deterministic artifacts that Cursor and CI can execute.

## Goals

1. Single source of truth for contracts, constants, flags, gates, and phase sequencing.
2. Deterministic runbooks for every phase (0-14) generated from SSOT data.
3. Drift detection between contracts and implementation (`Core/`, `App/`, `server/`, docs).
4. Release safety: blocked contracts are visible, auditable, and gate-enforced.

## Governance Assets

- `contract_registry.json`: canonical contract and constant registry.
- `phase_plan.json`: executable phase plan (0-14) with prerequisites and deliverables.
- `ci_gate_matrix.json`: gate IDs, commands, and required evidence artifacts.
- `plans/new_core_gate_matrix_v1.md`: plan-only blueprint for a strict new-core dedicated gate matrix decoupled from legacy PR test suites.
- `plans/new_core_gate_mapping_v1.md`: mapping from current `G-*` gates into new-core hard lane vs legacy soft lane.
- `plans/new_core_phase_gate_contract_v1.md`: phase-by-phase gate, quota, artifact, and sign-off contract for new core delivery.
- `plans/ci_gate_matrix_new_core_draft_structure.md`: draft JSON structure and field contract for `ci_gate_matrix_new_core.json` (design only).
- `plans/phase_plan_new_core_draft_structure.md`: draft JSON structure and field contract for `phase_plan_new_core.json` (design only).
- `plans/new_core_field_to_script_mapping_v1.md`: field-to-script mapping for the two new-core draft JSONs, including direct mappings and required adapters.
- `code_bindings.json`: regex-based value bindings from contracts/constants to source files.
- `scripts/generate_code_bindings.py`: deterministic generator for full K-* binding coverage.
- `structural_checks.json`: required/forbidden code patterns for contract compliance.
- `schema/*.schema.json`: explicit schemas for all governance files.
- `scripts/validate_governance.py`: validation engine + diagnostics report generator.
- `scripts/generate_cursor_runbooks.py`: deterministic phase runbook generator.
- `scripts/run_gate_matrix.py`: executable gate runner for per-phase and full-sweep enforcement.
- `scripts/eval_first_scan_runtime_kpi.py`: fixture-driven runtime evaluator for pure-vision hard gates + first-scan KPI report.
- `scripts/ci/validate_third_party_compliance.sh`: hard gate for lock/manifest/NOTICE/license-policy consistency.
- `scripts/run_gate_matrix.py`: executable gate runner for per-phase and full-sweep enforcement.
- `scripts/eval_first_scan_runtime_kpi.py`: fixture-driven runtime evaluator for pure-vision hard gates + first-scan KPI report.
- `scripts/ci/validate_third_party_compliance.sh`: hard gate for lock/manifest/NOTICE/license-policy consistency.
- `scripts/run_gate_matrix.py`: executable gate runner for per-phase and full-sweep enforcement.
- `scripts/eval_first_scan_runtime_kpi.py`: fixture-driven runtime evaluator for pure-vision hard gates + first-scan KPI report.

## Long-lived Integration Branch Strategy

Branch model is intentionally single-stream:

- Integration branch: `codex/protocol-governance-integration`
- Stable branch: `main`
- No per-phase branch split.
- Each phase closure is represented by a signed tag (`phase-0-pass` ... `phase-14-pass`).

This keeps cross-phase dependency resolution linear and prevents branch fanout drift.

## Cursor Execution Contract

Cursor must execute governance in this exact order:

1. `python3 governance/scripts/generate_code_bindings.py --output governance/code_bindings.json`
2. `python3 governance/scripts/validate_governance.py --report governance/generated/governance_diagnostics.json`
3. `python3 governance/scripts/generate_cursor_runbooks.py --output governance/generated/phases`
4. Open the relevant phase runbook from `governance/generated/phases/`.
5. Execute phase tasks in listed order.
6. For every migration batch inside a phase, run full gate sweep before the next batch:
   - `python3 governance/scripts/run_gate_matrix.py --full-sweep --min-severity warning --skip-gate-id G-FULL-GATE-SWEEP`
   - If any gate fails, stop immediately and do not start the next batch.
7. Execute all required gates from `ci_gate_matrix.json` for that phase.
   - For TimeAnchoring/audit-critical phases, include `G-AUDIT-ANCHOR-CLIENT-FIRST`:
     session-start mandatory anchor + every 60s + session-end mandatory anchor,
     with mobile client as primary RFC3161 requester and server as verifier/archive.
   - For pure-vision phases, include `G-PURE-VISION-RUNTIME-FIXTURE`:
     fixture replay must produce runtime metrics report and pass fail-closed thresholds.
   - For pure-vision phases, include `G-PURE-VISION-RUNTIME-FIXTURE`:
     fixture replay must produce runtime metrics report and pass fail-closed thresholds.
   - For pure-vision phases, include `G-PURE-VISION-RUNTIME-FIXTURE`:
     fixture replay must produce runtime metrics report and pass fail-closed thresholds.
8. Save evidence artifacts listed in the gate definitions.
9. Re-run strict validation:
   - `python3 governance/scripts/validate_governance.py --strict --report governance/generated/governance_diagnostics.json`
10. Create phase checkpoint tag only when strict mode has zero errors.

## Mobile-First Migration Policy (Phase 8-14)

- Cloud final S5 optimization/render remains mandatory; it is not downshifted to device.
- Device side owns compliance admission, S5 precheck, keyframe/dedup, geometry warm-start,
  packaging/hash/merkle, delta upload, and recovery snapshots.
- Migration proceeds in micro-batches; each batch must pass `G-FULL-GATE-SWEEP`.
- Batch order and gates are defined in `phase_plan.json` and materialized to runbooks.

## Blocked Contract Policy

A blocked contract means release is prohibited for any phase that requires that contract.
Blocked contracts are not hidden debt; they are first-class work items with explicit diagnostics.

## Determinism Requirements

- Runbook generation must be deterministic (`--check` mode must pass).
- Contract IDs (`C-*`), constants (`K-*`), gates (`G-*`) are immutable identifiers.
- Active numeric/boolean constants used by runtime code must be bound through `code_bindings.json` checks.
- Current binding policy: `coverage_policy.mode = all_active_constants` (full active K-* coverage).

## CI Integration

Use `.github/workflows/protocol-governance.yml` to run:

- contract validation,
- runbook determinism check,
- gate-critical checks (constants, flags, section ordering).

CI is allowed to fail while contracts are blocked; failure is intentional visibility.
