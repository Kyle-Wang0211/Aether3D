# Phase 02 Runbook - Evidence Parity

## Objective
Port Evidence engine with byte-identical deterministic JSON and replay behavior.

## Entry Criteria
- Prerequisite phases passed: 1
- Track: P

## Required Contracts
- `C-TRACK-P-LEGAL-BASELINE` [active] - Track P parity is legal baseline
- `C-EXACT-PIPELINE-IO-CLOSED` [active] - EXACT-ONLY pipeline IO closed sets are inviolable

## Required Gates
- `G-CONTRACT-VALIDATOR` (error) - Governance registry and contract validation
- `G-SWIFT-BUILD` (error) - Swift build and target tests

## Cursor Steps
1. Migrate deterministic_json, ds_mass_function, admission_controller, replay_engine.
2. Replay Swift logs through C++ and compare hashes.
3. Archive report under governance/generated/reports/phase-2.
4. Tag integration checkpoint phase-2-pass.

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
- `aether/evidence/*`
- `Evidence parity diff reports`

## Exit Criteria
- All required gates pass.
- Governance strict validation returns zero errors.
- Tag checkpoint `phase-2-pass` on `codex/protocol-governance-integration`.
