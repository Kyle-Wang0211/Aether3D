# Phase 11 Runbook - Noise-Aware Trainer + DA3

## Objective
Integrate noise-aware training and metric depth interface with bounded resource budgets.

## Entry Criteria
- Prerequisite phases passed: 10
- Track: X

## Required Contracts
- `C-TRACK-X-FEATURE-ISOLATION` [active] - Track X feature flags must not pollute Track P
- `C-CORE-SYSTEM-BOUNDARY-PIXEL` [blocked] - Pixel analysis remains in System layer unless explicitly re-scoped

## Required Gates
- `G-CONTRACT-VALIDATOR` (error) - Governance registry and contract validation

## Cursor Steps
1. Build trainer + depth interface + schedule pipeline.
2. Run noisy-sequence quality benchmarks.
3. Write release readiness report.
4. Tag integration checkpoint phase-11-pass.

## Gate Commands
### G-CONTRACT-VALIDATOR
Governance registry and contract validation

```bash
python3 governance/scripts/validate_governance.py --strict --report governance/generated/governance_diagnostics.json
```

Expected artifacts:
- `governance/generated/governance_diagnostics.json`

## Deliverables
- `noise_aware_loss/da3_interface/noise_schedule modules`
- `training delta metrics`

## Exit Criteria
- All required gates pass.
- Governance strict validation returns zero errors.
- Tag checkpoint `phase-11-pass` on `codex/protocol-governance-integration`.
