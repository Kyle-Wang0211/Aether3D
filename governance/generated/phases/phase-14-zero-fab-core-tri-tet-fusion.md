# Phase 14 Runbook - Zero-Fab Core + Tri/Tet Fusion

## Objective
Ship hardened zero-fabrication core policy, cross-validation fusion, fallback geometry correctness, and TRI/TET consistency layer as executable runtime contracts.

## Entry Criteria
- Prerequisite phases passed: 13
- Track: X

## Required Contracts
- `C-TRACK-X-FEATURE-ISOLATION` [active] - Track X feature flags must not pollute Track P
- `C-CURSOR-RUNBOOK-DETERMINISM` [active] - Each phase has deterministic Cursor runbook generated from SSOT
- `C-MOBILE-FIRST-OFFLOAD-EXECUTION` [active] - Mobile-first offload migration executes in governed batches and minimizes non-final cloud workload
- `C-BATCH-FULL-GATE-ENFORCEMENT` [active] - Every migration batch must pass full gate sweep before the next batch starts
- `C-CLOUD-FINAL-S5-RENDER-RESERVED` [active] - Cloud compute is reserved for final S5 optimization/render and legal archive closure

## Required Gates
- `G-CONTRACT-VALIDATOR` (error) - Governance registry and contract validation
- `G-PURE-VISION-RUNTIME-FIXTURE` (error) - Pure vision runtime hard gates (fixture replay, fail-closed)
- `G-FIRST-SCAN-SUCCESS-KPI` (error) - First-scan KPI contract (2-3min target, 15min hard cap)
- `G-FULL-GATE-SWEEP` (error) - Full gate sweep (warning+error) before next migration batch

## Cursor Steps
1. Batch 14A: replace all fallback placeholder camera transforms with validated rigid inverse + fail-closed behavior.
2. Immediately run required gates and full sweep (G-FULL-GATE-SWEEP) after Batch 14A.
3. Batch 14B: integrate zero-fabrication policy kernel and dual-lane cross-validation fusion rules into runtime path.
4. Immediately run required gates and full sweep (G-FULL-GATE-SWEEP) after Batch 14B.
5. Batch 14C: integrate TRI/TET consistency engine and expose measured/estimated/unknown bindings for audit output.
6. Immediately run required gates and full sweep (G-FULL-GATE-SWEEP) after Batch 14C; archive phase report and tag phase-14-pass.

## Gate Commands
### G-CONTRACT-VALIDATOR
Governance registry and contract validation

```bash
python3 governance/scripts/validate_governance.py --strict --report governance/generated/governance_diagnostics.json
```

Expected artifacts:
- `governance/generated/governance_diagnostics.json`

### G-PURE-VISION-RUNTIME-FIXTURE
Pure vision runtime hard gates (fixture replay, fail-closed)

```bash
python3 governance/scripts/eval_first_scan_runtime_kpi.py
```

Expected artifacts:
- `governance/generated/first_scan_runtime_metrics.json`

### G-FIRST-SCAN-SUCCESS-KPI
First-scan KPI contract (2-3min target, 15min hard cap)

```bash
python3 governance/scripts/eval_first_scan_runtime_kpi.py
python3 governance/scripts/validate_governance.py --strict --only first-scan-kpi --report governance/generated/governance_diagnostics.json
```

Expected artifacts:
- `governance/generated/governance_diagnostics.json`
- `governance/generated/first_scan_runtime_metrics.json`

### G-FULL-GATE-SWEEP
Full gate sweep (warning+error) before next migration batch

```bash
python3 governance/scripts/run_gate_matrix.py --full-sweep --min-severity warning --skip-gate-id G-FULL-GATE-SWEEP
```

Expected artifacts:
- `governance/generated/governance_diagnostics.json`
- `governance/generated/phases/index.md`

## Deliverables
- `P0-5 fallback geometry inverse hardening (no placeholder transform)`
- `zero-fabrication policy kernel + cross-validation fusion runtime`
- `TRI/TET consistency engine and deterministic Kuhn-5 decomposition`
- `phase14 diagnostics + governance closure report`

## Exit Criteria
- All required gates pass.
- Governance strict validation returns zero errors.
- Tag checkpoint `phase-14-pass` on `codex/protocol-governance-integration`.
