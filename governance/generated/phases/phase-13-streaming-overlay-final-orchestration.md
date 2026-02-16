# Phase 13 Runbook - Streaming + Overlay + Final Orchestration

## Objective
Complete E2E orchestration and certify contract closure for full pipeline.

## Entry Criteria
- Prerequisite phases passed: 12
- Track: X

## Required Contracts
- `C-TRACK-X-FEATURE-ISOLATION` [active] - Track X feature flags must not pollute Track P
- `C-CURSOR-RUNBOOK-DETERMINISM` [active] - Each phase has deterministic Cursor runbook generated from SSOT
- `C-DOC-SECTION-ORDER-MONOTONIC` [active] - Section numbering for §6.x remains monotonic in normative layers

## Required Gates
- `G-PHASE13-E2E-SMOKE` (error) - Phase 13 end-to-end smoke gate
- `G-CONTRACT-VALIDATOR` (error) - Governance registry and contract validation
- `G-DOC-SECTION-ORDER` (error) - §6.x section monotonicity

## Cursor Steps
1. Integrate streaming engine, evidence overlay, and orchestrator.
2. Run scenario A/B/C/D and capture reports.
3. Close all blocked contracts before release tag.
4. Tag integration checkpoint phase-13-pass.

## Gate Commands
### G-PHASE13-E2E-SMOKE
Phase 13 end-to-end smoke gate

```bash
swift test --filter ScanGuidanceIntegrationTests
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

## Deliverables
- `pipeline_orchestrator`
- `phase13 scenario test report`
- `final governance closure report`

## Exit Criteria
- All required gates pass.
- Governance strict validation returns zero errors.
- Tag checkpoint `phase-13-pass` on `codex/protocol-governance-integration`.
