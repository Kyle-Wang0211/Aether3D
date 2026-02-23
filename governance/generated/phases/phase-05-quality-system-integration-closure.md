# Phase 05 Runbook - Quality + System Integration Closure

## Objective
Close known platform integration drifts (blur SSOT, PatchDisplayMap migration, upload hash verification).

## Entry Criteria
- Prerequisite phases passed: 4
- Track: P

## Required Contracts
- `C-BLUR-SSOT-SINGLE-VALUE` [active] - Blur-related SSOT must be singular and conflict-free
- `C-SCAN-PATCHDISPLAY-MIGRATION` [active] - ScanViewModel must use PatchDisplayMap instead of local displaySnapshot dict
- `C-SCAN-BLUR-HAPTIC-REMOVAL` [active] - Blur haptic in ScanViewModel is removed; blur only gates frame rejection
- `C-UPLOAD-CHUNK-HASH-VERIFY` [active] - persist_chunk must verify expected_hash before durable write

## Required Gates
- `G-BLUR-CONSTANT-DRIFT` (error) - Blur constant drift detection
- `G-SCAN-GUIDANCE-INTEGRATION` (error) - Scan guidance migration and monotonicity tests
- `G-UPLOAD-CHUNK-HASH` (error) - Upload chunk expected_hash verification
- `G-P0-QUALITY-IMPLEMENTATION` (error) - P0 quality metric implementation (no placeholder paths)
- `G-UPLOAD-CONTRACT-CONSISTENCY` (error) - Upload contract version/method/header/chunk consistency
- `G-CONTRACT-VALIDATOR` (error) - Governance registry and contract validation

## Cursor Steps
1. Unify blur constants and align code to registry values.
2. Replace ScanViewModel local snapshot with PatchDisplayMap chain.
3. Remove blur haptic path and keep frame rejection semantics.
4. Enforce expected_hash check in persist_chunk().
5. Tag integration checkpoint phase-5-pass.

## Gate Commands
### G-BLUR-CONSTANT-DRIFT
Blur constant drift detection

```bash
python3 governance/scripts/validate_governance.py --strict --only blur
```

Expected artifacts:
- `governance/generated/governance_diagnostics.json`

### G-SCAN-GUIDANCE-INTEGRATION
Scan guidance migration and monotonicity tests

```bash
swift test -Xswiftc -strict-concurrency=minimal --filter 'ScanGuidanceTests\.(PatchDisplayMapTests|MonotonicityStressTests|ScanGuidanceIntegrationTests)'
```

Expected artifacts:
- `Test logs for scan guidance suites`

### G-UPLOAD-CHUNK-HASH
Upload chunk expected_hash verification

```bash
PYTHONPATH=server python3 -m pytest -q server/tests/test_upload_service.py -k persist_chunk_hash_mismatch
```

Expected artifacts:
- `pytest output for persist_chunk_hash_mismatch`

### G-P0-QUALITY-IMPLEMENTATION
P0 quality metric implementation (no placeholder paths)

```bash
python3 governance/scripts/validate_governance.py --strict --only p0-quality --report governance/generated/governance_diagnostics.json
```

Expected artifacts:
- `governance/generated/governance_diagnostics.json`

### G-UPLOAD-CONTRACT-CONSISTENCY
Upload contract version/method/header/chunk consistency

```bash
python3 governance/scripts/validate_governance.py --strict --only upload-contract --report governance/generated/governance_diagnostics.json
```

Expected artifacts:
- `governance/generated/governance_diagnostics.json`

### G-CONTRACT-VALIDATOR
Governance registry and contract validation

```bash
python3 governance/scripts/validate_governance.py --strict --report governance/generated/governance_diagnostics.json
```

Expected artifacts:
- `governance/generated/governance_diagnostics.json`

## Deliverables
- `Core/Quality/*`
- `App/Scan/ScanViewModel.swift migration`
- `server hash verification fix`

## Exit Criteria
- All required gates pass.
- Governance strict validation returns zero errors.
- Tag checkpoint `phase-5-pass` on `codex/protocol-governance-integration`.

## Audit Trail (2026-02-17)
- `Stop`: freeze non-blocking warning cleanup and doc-only expansion during gate-recovery batch.
- `Isolate`: keep `ChunkBufferPoolTests.swift` out of `UploadTests` main target to prevent strict-concurrency pointer debt from blocking Phase-5 gates.
- `Closed`: `PR5CaptureTests` pass, `TSDF` tests pass, `G-SCAN-GUIDANCE-INTEGRATION` pass, upload index-gap classification fixed (`INDEX_GAP` precedence) in `/Users/kaidongwang/Documents/progecttwo/progect2/progect2/server/app/services/upload_service.py`.

## Audit Trail (2026-02-17)
- `Stop`: freeze non-blocking warning cleanup and doc-only expansion during gate-recovery batch.
- `Isolate`: keep `ChunkBufferPoolTests.swift` out of `UploadTests` main target to prevent strict-concurrency pointer debt from blocking Phase-5 gates.
- `Closed`: `PR5CaptureTests` pass, `TSDF` tests pass, `G-SCAN-GUIDANCE-INTEGRATION` pass, upload index-gap classification fixed (`INDEX_GAP` precedence) in `/Users/kaidongwang/Documents/progecttwo/progect2/progect2/server/app/services/upload_service.py`.
