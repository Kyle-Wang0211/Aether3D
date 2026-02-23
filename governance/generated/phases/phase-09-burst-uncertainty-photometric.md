# Phase 09 Runbook - Burst + Uncertainty + Photometric

## Objective
Shift geometric bootstrap to device side (VIO/local BA/scale/depth/uncertainty) to reduce cloud search space.

## Entry Criteria
- Prerequisite phases passed: 8
- Track: X

## Required Contracts
- `C-TRACK-X-FEATURE-ISOLATION` [active] - Track X feature flags must not pollute Track P
- `C-MOBILE-FIRST-OFFLOAD-EXECUTION` [active] - Mobile-first offload migration executes in governed batches and minimizes non-final cloud workload
- `C-BATCH-FULL-GATE-ENFORCEMENT` [active] - Every migration batch must pass full gate sweep before the next batch starts

## Required Gates
- `G-CONTRACT-VALIDATOR` (error) - Governance registry and contract validation
- `G-PURE-VISION-RUNTIME-FIXTURE` (error) - Pure vision runtime hard gates (fixture replay, fail-closed)
- `G-FIRST-SCAN-SUCCESS-KPI` (error) - First-scan KPI contract (2-3min target, 15min hard cap)
- `G-FULL-GATE-SWEEP` (error) - Full gate sweep (warning+error) before next migration batch

## Cursor Steps
1. Batch 9A: deliver burst controller, VIO bootstrap, and local BA window optimization with deterministic replay.
2. Immediately run required gates and full sweep (G-FULL-GATE-SWEEP) after Batch 9A.
3. Batch 9B: deliver scale anchor, monocular depth prior, uncertainty maps, and coarse TSDF/occupancy updates.
4. Immediately run required gates and full sweep (G-FULL-GATE-SWEEP) after Batch 9B; persist diagnostics in governance reports.
5. Tag integration checkpoint phase-9-pass.

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
- `on-device VIO/local BA bootstrap modules`
- `on-device semantic scale anchor + depth prior + uncertainty maps`
- `coarse TSDF/occupancy evidence for cloud warm start`

## Exit Criteria
- All required gates pass.
- Governance strict validation returns zero errors.
- Tag checkpoint `phase-9-pass` on `codex/protocol-governance-integration`.
