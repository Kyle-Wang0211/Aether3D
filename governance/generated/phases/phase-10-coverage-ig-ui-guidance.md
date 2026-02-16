# Phase 10 Runbook - Coverage + IG + UI Guidance

## Objective
Close active guidance loop from uncertainty to actionable UI direction.

## Entry Criteria
- Prerequisite phases passed: 9
- Track: X

## Required Contracts
- `C-TRACK-X-FEATURE-ISOLATION` [active] - Track X feature flags must not pollute Track P

## Required Gates
- `G-CONTRACT-VALIDATOR` (error) - Governance registry and contract validation

## Cursor Steps
1. Implement coverage stopper, information gain, UI guidance.
2. Validate completion and direction quality metrics.
3. Store integration report.
4. Tag integration checkpoint phase-10-pass.

## Gate Commands
### G-CONTRACT-VALIDATOR
Governance registry and contract validation

```bash
python3 governance/scripts/validate_governance.py --strict --report governance/generated/governance_diagnostics.json
```

Expected artifacts:
- `governance/generated/governance_diagnostics.json`

## Deliverables
- `coverage_stopper/info_gain/ui_guidance modules`
- `guidance angle benchmark outputs`

## Exit Criteria
- All required gates pass.
- Governance strict validation returns zero errors.
- Tag checkpoint `phase-10-pass` on `codex/protocol-governance-integration`.
