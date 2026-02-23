# Phase 08 Runbook - CT-VIO + Noise + FrameGate

## Objective
Start mobile-first offload with hard compliance and quality admission while preserving cloud final render path, and enforce first-scan success as top KPI.

## Entry Criteria
- Prerequisite phases passed: 7
- Track: X

## Required Contracts
- `C-TRACK-X-FEATURE-ISOLATION` [active] - Track X feature flags must not pollute Track P
- `C-CORE-SYSTEM-BOUNDARY-PIXEL` [blocked] - Pixel analysis remains in System layer unless explicitly re-scoped
- `C-MOBILE-FIRST-OFFLOAD-EXECUTION` [active] - Mobile-first offload migration executes in governed batches and minimizes non-final cloud workload
- `C-BATCH-FULL-GATE-ENFORCEMENT` [active] - Every migration batch must pass full gate sweep before the next batch starts

## Required Gates
- `G-CONTRACT-VALIDATOR` (error) - Governance registry and contract validation
- `G-FLAG-DEFAULT-OFF` (error) - Track X defaults OFF policy
- `G-PURE-VISION-RUNTIME-FIXTURE` (error) - Pure vision runtime hard gates (fixture replay, fail-closed)
- `G-FIRST-SCAN-SUCCESS-KPI` (error) - First-scan KPI contract (2-3min target, 15min hard cap)
- `G-FULL-GATE-SWEEP` (error) - Full gate sweep (warning+error) before next migration batch

## Cursor Steps
1. Batch 8A: implement on-device compliance/OOD/temporal vote/rule engine path with fail-closed behavior.
2. Immediately run required gates and full sweep (G-FULL-GATE-SWEEP) after Batch 8A; block progression on any failure.
3. Batch 8B: implement S5 precheck admission, keyframe selection, dedup, and blur/exposure admission metrics.
4. 双通道上传策略-在线通道: 仅 S5素材 触发云端最终渲染队列优先上云，非S5留在本地继续采集.
5. Immediately run required gates and full sweep (G-FULL-GATE-SWEEP) after Batch 8B; archive diagnostics and thermal traces.
6. Tag integration checkpoint phase-8-pass.

## Gate Commands
### G-CONTRACT-VALIDATOR
Governance registry and contract validation

```bash
python3 governance/scripts/validate_governance.py --strict --report governance/generated/governance_diagnostics.json
```

Expected artifacts:
- `governance/generated/governance_diagnostics.json`

### G-FLAG-DEFAULT-OFF
Track X defaults OFF policy

```bash
python3 governance/scripts/validate_governance.py --strict --only flags
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
- `on-device compliance admission pipeline`
- `S5 precheck + keyframe admission pipeline`
- `batch gate evidence logs for phase 8`

## Exit Criteria
- All required gates pass.
- Governance strict validation returns zero errors.
- Tag checkpoint `phase-8-pass` on `codex/protocol-governance-integration`.
