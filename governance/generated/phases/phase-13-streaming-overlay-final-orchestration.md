# Phase 13 Runbook - Streaming + Overlay + Final Orchestration

## Objective
Finalize mobile-heavy streaming/audit packaging and certify cloud final S5 render + legal archive closure.

## Entry Criteria
- Prerequisite phases passed: 12
- Track: X

## Required Contracts
- `C-TRACK-X-FEATURE-ISOLATION` [active] - Track X feature flags must not pollute Track P
- `C-CURSOR-RUNBOOK-DETERMINISM` [active] - Each phase has deterministic Cursor runbook generated from SSOT
- `C-DOC-SECTION-ORDER-MONOTONIC` [active] - Section numbering for §6.x remains monotonic in normative layers
- `C-AUDIT-ANCHOR-CLIENT-FIRST` [active] - RFC3161 audit anchoring is client-first with start/end mandatory and 60s periodic anchors
- `C-MOBILE-FIRST-OFFLOAD-EXECUTION` [active] - Mobile-first offload migration executes in governed batches and minimizes non-final cloud workload
- `C-BATCH-FULL-GATE-ENFORCEMENT` [active] - Every migration batch must pass full gate sweep before the next batch starts
- `C-CLOUD-FINAL-S5-RENDER-RESERVED` [active] - Cloud compute is reserved for final S5 optimization/render and legal archive closure

## Required Gates
- `G-PHASE13-E2E-SMOKE` (error) - Phase 13 end-to-end smoke gate
- `G-CONTRACT-VALIDATOR` (error) - Governance registry and contract validation
- `G-DOC-SECTION-ORDER` (error) - §6.x section monotonicity
- `G-AUDIT-ANCHOR-CLIENT-FIRST` (error) - RFC3161 client-first anchor policy (start/end mandatory + 60s periodic)
- `G-PURE-VISION-RUNTIME-FIXTURE` (error) - Pure vision runtime hard gates (fixture replay, fail-closed)
- `G-FIRST-SCAN-SUCCESS-KPI` (error) - First-scan KPI contract (2-3min target, 15min hard cap)
- `G-DUAL-LANE-UPLOAD-POLICY` (error) - Dual-lane upload policy (S5 pre-admission + final full acceptance)
- `G-FULL-GATE-SWEEP` (error) - Full gate sweep (warning+error) before next migration batch

## Cursor Steps
1. Batch 13A: integrate CAS chunking, dedup, delta upload, and transport adaptation on device.
2. Immediately run required gates and full sweep (G-FULL-GATE-SWEEP) after Batch 13A.
3. Batch 13B: integrate Merkle/hash/provenance package, signature chain, and session-start/end + periodic audit anchors.
4. Immediately run required gates and full sweep (G-FULL-GATE-SWEEP) after Batch 13B.
5. 双通道上传策略-终态通道: 最终会话提交时必须全量上传并对 S0-S5 素材全部接纳，不得因质量门禁拒绝剩余素材.
6. Batch 13C: integrate final orchestrator and enforce cloud final S5 render + legal archive closure path.
7. Immediately run required gates and full sweep (G-FULL-GATE-SWEEP) after Batch 13C; run scenario A/B/C/D and capture reports.
8. Close all blocked contracts before release tag.
9. Tag integration checkpoint phase-13-pass.

## Gate Commands
### G-PHASE13-E2E-SMOKE
Phase 13 end-to-end smoke gate

```bash
swift test -Xswiftc -strict-concurrency=minimal --filter 'ScanGuidanceTests\.ScanGuidanceIntegrationTests'
PYTHONPATH=server python3 -m pytest -q server/tests/test_upload_service.py
```

Expected artifacts:
- `phase13_e2e_smoke_report.md`

### G-CONTRACT-VALIDATOR
Governance registry and contract validation

```bash
python3 governance/scripts/validate_governance.py --strict --report governance/generated/governance_diagnostics.json
```

Expected artifacts:
- `governance/generated/governance_diagnostics.json`

### G-DOC-SECTION-ORDER
§6.x section monotonicity

```bash
python3 governance/scripts/validate_governance.py --strict --only section-order
```

Expected artifacts:
- `governance/generated/governance_diagnostics.json`

### G-AUDIT-ANCHOR-CLIENT-FIRST
RFC3161 client-first anchor policy (start/end mandatory + 60s periodic)

```bash
python3 governance/scripts/validate_governance.py --strict --only audit-anchor --report governance/generated/governance_diagnostics.json
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

### G-DUAL-LANE-UPLOAD-POLICY
Dual-lane upload policy (S5 pre-admission + final full acceptance)

```bash
python3 governance/scripts/validate_governance.py --strict --only dual-lane-upload --report governance/generated/governance_diagnostics.json
```

Expected artifacts:
- `governance/generated/governance_diagnostics.json`

### G-FULL-GATE-SWEEP
Full gate sweep (warning+error) before next migration batch

```bash
python3 governance/scripts/run_gate_matrix.py --full-sweep --min-severity warning --skip-gate-id G-FULL-GATE-SWEEP
```

Expected artifacts:
- `governance/generated/governance_diagnostics.json`
- `governance/generated/phases/index.md`

## Deliverables
- `on-device CAS/delta upload + provenance package stack`
- `cloud final S5 render/audit archive handshake`
- `phase13 scenario + full gate sweep reports`
- `final governance closure report`

## Exit Criteria
- All required gates pass.
- Governance strict validation returns zero errors.
- Tag checkpoint `phase-13-pass` on `codex/protocol-governance-integration`.

## Audit Trail (2026-02-17)
- `Stop`: stop treating sandbox cache permission failures as functional regressions for Phase-13.
- `Isolate`: run full gate sweep in cache-accessible execution path to remove false negatives from SwiftPM module-cache writes.
- `Closed`: `G-PHASE13-E2E-SMOKE` pass (Swift integration tests + server upload pytest), `G-FULL-GATE-SWEEP` pass (`executed=19, failed=0`), first-scan runtime KPI gate pass.

## Audit Trail (2026-02-17)
- `Stop`: stop treating sandbox cache permission failures as functional regressions for Phase-13.
- `Isolate`: run full gate sweep in cache-accessible execution path to remove false negatives from SwiftPM module-cache writes.
- `Closed`: `G-PHASE13-E2E-SMOKE` pass (Swift integration tests + server upload pytest), `G-FULL-GATE-SWEEP` pass (`executed=19, failed=0`), first-scan runtime KPI gate pass.
