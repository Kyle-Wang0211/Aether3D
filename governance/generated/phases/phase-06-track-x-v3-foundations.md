# Phase 06 Runbook - Track X V3 Foundations

## Objective
Introduce V3 innovation set behind compile-time flags with default OFF.

## Entry Criteria
- Prerequisite phases passed: 5
- Track: X

## Required Contracts
- `C-TRACK-X-FEATURE-ISOLATION` [active] - Track X feature flags must not pollute Track P
- `C-FEATURE-FLAG-DEFAULTS` [active] - Track X feature flags default OFF
- `C-FEATURE-FLAG-NAMESPACE` [blocked] - Feature flag namespace strategy must be consistent and mapped

## Required Gates
- `G-FLAG-DEFAULT-OFF` (error) - Track X defaults OFF policy
- `G-FLAG-NAMESPACE` (warning) - Feature flag namespace consistency
- `G-CONTRACT-VALIDATOR` (error) - Governance registry and contract validation

## Cursor Steps
1. Implement V3 modules with explicit flag guards.
2. Keep Track P fixtures green.
3. Generate Track X-specific fixtures.
4. Tag integration checkpoint phase-6-pass.

## Gate Commands
### G-FLAG-DEFAULT-OFF
Track X defaults OFF policy

```bash
python3 governance/scripts/validate_governance.py --strict --only flags
```

Expected artifacts:
- `governance/generated/governance_diagnostics.json`

### G-FLAG-NAMESPACE
Feature flag namespace consistency

```bash
python3 governance/scripts/validate_governance.py --only flag-namespace --report governance/generated/governance_diagnostics.json
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
- `V3 feature-flagged modules`
- `Track X fixture set`

## Exit Criteria
- All required gates pass.
- Governance strict validation returns zero errors.
- Tag checkpoint `phase-6-pass` on `codex/protocol-governance-integration`.
