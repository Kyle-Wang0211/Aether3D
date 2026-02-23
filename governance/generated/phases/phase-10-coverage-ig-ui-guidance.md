# Phase 10 Runbook - Coverage + IG + UI Guidance

## Objective
Complete on-device mesh/instance graph loop and evidence-only UI feedback while maintaining user intent neutrality.

## Entry Criteria
- Prerequisite phases passed: 9
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
1. Batch 10A: implement MC33 extraction, closure ratio pre-estimate, and coverage stopper/info-gain feedback loop.
2. Immediately run required gates and full sweep (G-FULL-GATE-SWEEP) after Batch 10A.
3. Batch 10B: implement TAIS instance separation, incremental graph updates, and evidence-only UI rendering contract.
4. Immediately run required gates and full sweep (G-FULL-GATE-SWEEP) after Batch 10B; store integration report.
5. Tag integration checkpoint phase-10-pass.

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
- `on-device MC33 coarse mesh + closure pre-estimate`
- `TAIS instance split + incremental instance graph updates`
- `evidence UI (black/gray/white + reveal-original-color) linkage`

## Exit Criteria
- All required gates pass.
- Governance strict validation returns zero errors.
- Tag checkpoint `phase-10-pass` on `codex/protocol-governance-integration`.
