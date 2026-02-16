# Phase 04 Runbook - TimeAnchoring

## Objective
Complete pure-computation time anchoring rules without network IO in Core.

## Entry Criteria
- Prerequisite phases passed: 3
- Track: P

## Required Contracts
- `C-TRACK-P-LEGAL-BASELINE` [active] - Track P parity is legal baseline
- `C-CORE-NO-CONCURRENCY-PRIMITIVES` [active] - Core forbids mutex/thread/atomic primitives

## Required Gates
- `G-CONTRACT-VALIDATOR` (error) - Governance registry and contract validation
- `G-SWIFT-BUILD` (error) - Swift build and target tests

## Cursor Steps
1. Implement parser/fusion/error-classification/proof assembly.
2. Validate deterministic outputs across platforms.
3. Store phase evidence in governance generated report.
4. Tag integration checkpoint phase-4-pass.

## Gate Commands
### G-CONTRACT-VALIDATOR
Governance registry and contract validation

```bash
python3 governance/scripts/validate_governance.py --strict --report governance/generated/governance_diagnostics.json
```

Expected artifacts:
- `governance/generated/governance_diagnostics.json`

### G-SWIFT-BUILD
Swift build and target tests

```bash
swift build
```

Expected artifacts:
- `.build/`

## Deliverables
- `aether/time/*`
- `Marzullo fusion verification outputs`

## Exit Criteria
- All required gates pass.
- Governance strict validation returns zero errors.
- Tag checkpoint `phase-4-pass` on `codex/protocol-governance-integration`.
