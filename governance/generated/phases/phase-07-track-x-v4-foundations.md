# Phase 07 Runbook - Track X V4 Foundations

## Objective
Integrate V4 clusters with isolated flags and schema version discipline.

## Entry Criteria
- Prerequisite phases passed: 6
- Track: X

## Required Contracts
- `C-TRACK-X-FEATURE-ISOLATION` [active] - Track X feature flags must not pollute Track P
- `C-FEATURE-FLAG-DEFAULTS` [active] - Track X feature flags default OFF

## Required Gates
- `G-FLAG-DEFAULT-OFF` (error) - Track X defaults OFF policy
- `G-CONTRACT-VALIDATOR` (error) - Governance registry and contract validation

## Cursor Steps
1. Implement V4 cluster modules behind flags.
2. Run Track P regression and V4 fixtures.
3. Record schema bumps and migration notes.
4. Tag integration checkpoint phase-7-pass.

## Gate Commands
### G-FLAG-DEFAULT-OFF
Track X defaults OFF policy

```bash
python3 governance/scripts/validate_governance.py --strict --only flags
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
- `V4 feature implementations`
- `schema version changelog entries`

## Exit Criteria
- All required gates pass.
- Governance strict validation returns zero errors.
- Tag checkpoint `phase-7-pass` on `codex/protocol-governance-integration`.
