# Phase 09 Runbook - Burst + Uncertainty + Photometric

## Objective
Integrate burst capture control with uncertainty and photometric normalization.

## Entry Criteria
- Prerequisite phases passed: 8
- Track: X

## Required Contracts
- `C-TRACK-X-FEATURE-ISOLATION` [active] - Track X feature flags must not pollute Track P

## Required Gates
- `G-CONTRACT-VALIDATOR` (error) - Governance registry and contract validation

## Cursor Steps
1. Implement three module set with thermal tier linkage.
2. Run quality/uncertainty acceptance checks.
3. Persist diagnostics in governance reports.
4. Tag integration checkpoint phase-9-pass.

## Gate Commands
### G-CONTRACT-VALIDATOR
Governance registry and contract validation

```bash
python3 governance/scripts/validate_governance.py --strict --report governance/generated/governance_diagnostics.json
```

Expected artifacts:
- `governance/generated/governance_diagnostics.json`

## Deliverables
- `aether/capture/burst_controller*`
- `aether/quality/patch_uncertainty*`
- `aether/quality/photometric_normalizer*`

## Exit Criteria
- All required gates pass.
- Governance strict validation returns zero errors.
- Tag checkpoint `phase-9-pass` on `codex/protocol-governance-integration`.
