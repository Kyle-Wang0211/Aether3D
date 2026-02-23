# Phase 07 Runbook - Track X V4 Foundations

## Objective
Integrate V4 clusters and server-side cost governance enforcement (auth/rate/idempotency/runtime fuse).

## Entry Criteria
- Prerequisite phases passed: 6
- Track: X

## Required Contracts
- `C-TRACK-X-FEATURE-ISOLATION` [active] - Track X feature flags must not pollute Track P
- `C-FEATURE-FLAG-DEFAULTS` [active] - Track X feature flags default OFF
- `C-COSTSHIELD-SERVER-ENFORCEMENT` [active] - Auth, gateway rate limiting, idempotency, and runtime budget fuse are enforced server-side from Phase 7+

## Required Gates
- `G-FLAG-DEFAULT-OFF` (error) - Track X defaults OFF policy
- `G-CONTRACT-VALIDATOR` (error) - Governance registry and contract validation

## Cursor Steps
1. Implement V4 cluster modules behind flags.
2. Integrate three-gate server enforcement chain (Gateway + Scheduler/Worker) against shared policy contracts.
3. Run Track P regression and V4 fixtures.
4. Record schema bumps and migration notes.
5. Tag integration checkpoint phase-7-pass.

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
- `server gateway auth/rate-limit/idempotency enforcement path`
- `schema version changelog entries`

## Exit Criteria
- All required gates pass.
- Governance strict validation returns zero errors.
- Tag checkpoint `phase-7-pass` on `codex/protocol-governance-integration`.
