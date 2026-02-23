# Phase 11 Runbook - Noise-Aware Trainer + DA3

## Objective
Add on-device GS warm-start and bounded trainer handoff while reserving cloud for final S5 optimization/render.

## Entry Criteria
- Prerequisite phases passed: 10
- Track: X

## Required Contracts
- `C-TRACK-X-FEATURE-ISOLATION` [active] - Track X feature flags must not pollute Track P
- `C-CORE-SYSTEM-BOUNDARY-PIXEL` [blocked] - Pixel analysis remains in System layer unless explicitly re-scoped
- `C-MOBILE-FIRST-OFFLOAD-EXECUTION` [active] - Mobile-first offload migration executes in governed batches and minimizes non-final cloud workload
- `C-BATCH-FULL-GATE-ENFORCEMENT` [active] - Every migration batch must pass full gate sweep before the next batch starts
- `C-CLOUD-FINAL-S5-RENDER-RESERVED` [active] - Cloud compute is reserved for final S5 optimization/render and legal archive closure

## Required Gates
- `G-CONTRACT-VALIDATOR` (error) - Governance registry and contract validation
- `G-PURE-VISION-RUNTIME-FIXTURE` (error) - Pure vision runtime hard gates (fixture replay, fail-closed)
- `G-FIRST-SCAN-SUCCESS-KPI` (error) - First-scan KPI contract (2-3min target, 15min hard cap)
- `G-FULL-GATE-SWEEP` (error) - Full gate sweep (warning+error) before next migration batch

## Cursor Steps
1. Batch 11A: implement GS initialization, mini-splat warm-up, and DPC pre-statistics on device.
2. Immediately run required gates and full sweep (G-FULL-GATE-SWEEP) after Batch 11A.
3. Batch 11B: integrate noise-aware trainer handoff and enforce cloud-final-S5-only render contract.
4. Immediately run required gates and full sweep (G-FULL-GATE-SWEEP) after Batch 11B; write release readiness report.
5. Tag integration checkpoint phase-11-pass.

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
- `on-device GS init + mini warm-up + DPC pre-stats`
- `trainer handoff package with deterministic provenance`
- `cloud final render handshake contracts`

## Exit Criteria
- All required gates pass.
- Governance strict validation returns zero errors.
- Tag checkpoint `phase-11-pass` on `codex/protocol-governance-integration`.
