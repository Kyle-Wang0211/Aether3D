# Phase 12 Runbook - DGRUT + 8x8 Texels + Native Resolution

## Objective
Ship render architecture with memory-adaptive guarantees.

## Entry Criteria
- Prerequisite phases passed: 11
- Track: X

## Required Contracts
- `C-TRACK-X-FEATURE-ISOLATION` [active] - Track X feature flags must not pollute Track P
- `C-PIT1-TIMEWARP-PURITY` [active] - PresentLoop timewarp is pure reprojection with constant disocclusion fill

## Required Gates
- `G-CONTRACT-VALIDATOR` (error) - Governance registry and contract validation

## Cursor Steps
1. Integrate rendering path variants per device tier.
2. Validate fps/memory/thermal targets.
3. Record evidence outputs.
4. Tag integration checkpoint phase-12-pass.

## Gate Commands
### G-CONTRACT-VALIDATOR
Governance registry and contract validation

```bash
python3 governance/scripts/validate_governance.py --strict --report governance/generated/governance_diagnostics.json
```

Expected artifacts:
- `governance/generated/governance_diagnostics.json`

## Deliverables
- `render dgrut/texel/native-resolution modules`
- `memory and fps benchmark evidence`

## Exit Criteria
- All required gates pass.
- Governance strict validation returns zero errors.
- Tag checkpoint `phase-12-pass` on `codex/protocol-governance-integration`.
