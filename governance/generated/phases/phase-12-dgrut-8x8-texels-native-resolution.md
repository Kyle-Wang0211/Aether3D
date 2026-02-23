# Phase 12 Runbook - DGRUT + 8x8 Texels + Native Resolution

## Objective
Ship device-tier render prep, scheduler, thermal and memory control loops for stable high throughput.

## Entry Criteria
- Prerequisite phases passed: 11
- Track: X

## Required Contracts
- `C-TRACK-X-FEATURE-ISOLATION` [active] - Track X feature flags must not pollute Track P
- `C-PIT1-TIMEWARP-PURITY` [active] - PresentLoop timewarp is pure reprojection with constant disocclusion fill
- `C-MOBILE-FIRST-OFFLOAD-EXECUTION` [active] - Mobile-first offload migration executes in governed batches and minimizes non-final cloud workload
- `C-BATCH-FULL-GATE-ENFORCEMENT` [active] - Every migration batch must pass full gate sweep before the next batch starts
- `C-CLOUD-FINAL-S5-RENDER-RESERVED` [active] - Cloud compute is reserved for final S5 optimization/render and legal archive closure

## Required Gates
- `G-CONTRACT-VALIDATOR` (error) - Governance registry and contract validation
- `G-PURE-VISION-RUNTIME-FIXTURE` (error) - Pure vision runtime hard gates (fixture replay, fail-closed)
- `G-FIRST-SCAN-SUCCESS-KPI` (error) - First-scan KPI contract (2-3min target, 15min hard cap)
- `G-FULL-GATE-SWEEP` (error) - Full gate sweep (warning+error) before next migration batch

## Cursor Steps
1. Batch 12A: integrate DGRUT/texel path, ROI hints, and per-tier render prep modules.
2. Immediately run required gates and full sweep (G-FULL-GATE-SWEEP) after Batch 12A.
3. Batch 12B: integrate thermal/memory/battery scheduler loops and adaptive fallback contracts.
4. Immediately run required gates and full sweep (G-FULL-GATE-SWEEP) after Batch 12B; record fps/memory/thermal evidence.
5. Tag integration checkpoint phase-12-pass.

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
- `device-tier render hint/ROI prep modules`
- `thermal + memory + battery scheduler control loops`
- `performance profile evidence across supported tiers`

## Exit Criteria
- All required gates pass.
- Governance strict validation returns zero errors.
- Tag checkpoint `phase-12-pass` on `codex/protocol-governance-integration`.
