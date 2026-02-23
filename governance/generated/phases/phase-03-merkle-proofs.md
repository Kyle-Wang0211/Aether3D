# Phase 03 Runbook - Merkle + Proofs

## Objective
Finish inclusion and consistency proof stack with boundary vectors.

## Entry Criteria
- Prerequisite phases passed: 2
- Track: P

## Required Contracts
- `C-TRACK-P-LEGAL-BASELINE` [active] - Track P parity is legal baseline

## Required Gates
- `G-CONTRACT-VALIDATOR` (error) - Governance registry and contract validation
- `G-SWIFT-BUILD` (error) - Swift build and target tests

## Cursor Steps
1. Implement inclusion and consistency proofs.
2. Run vector suites for tree-size boundaries.
3. Persist deterministic digest report.
4. Tag integration checkpoint phase-3-pass.

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
- `aether/merkle/*`
- `RFC vector parity logs`

## Exit Criteria
- All required gates pass.
- Governance strict validation returns zero errors.
- Tag checkpoint `phase-3-pass` on `codex/protocol-governance-integration`.
