# Phase 08 Runbook - CT-VIO + Noise + FrameGate

## Objective
Enable active measurement capture path with deterministic contracts.

## Entry Criteria
- Prerequisite phases passed: 7
- Track: X

## Required Contracts
- `C-TRACK-X-FEATURE-ISOLATION` [active] - Track X feature flags must not pollute Track P
- `C-CORE-SYSTEM-BOUNDARY-PIXEL` [blocked] - Pixel analysis remains in System layer unless explicitly re-scoped

## Required Gates
- `G-CONTRACT-VALIDATOR` (error) - Governance registry and contract validation
- `G-FLAG-DEFAULT-OFF` (error) - Track X defaults OFF policy

## Cursor Steps
1. Deliver ct_state/ct_optimizer/noise_classifier/frame_gate modules.
2. Run noise and gate acceptance benchmarks.
3. Archive benchmark outputs.
4. Tag integration checkpoint phase-8-pass.

## Gate Commands
### G-CONTRACT-VALIDATOR
Governance registry and contract validation

```bash
python3 governance/scripts/validate_governance.py --strict --report governance/generated/governance_diagnostics.json
```

Expected artifacts:
- `governance/generated/governance_diagnostics.json`

### G-FLAG-DEFAULT-OFF
Track X defaults OFF policy

```bash
python3 governance/scripts/validate_governance.py --strict --only flags
```

Expected artifacts:
- `governance/generated/governance_diagnostics.json`

## Deliverables
- `aether/vio/*`
- `aether/quality/frame_gate*`

## Exit Criteria
- All required gates pass.
- Governance strict validation returns zero errors.
- Tag checkpoint `phase-8-pass` on `codex/protocol-governance-integration`.
