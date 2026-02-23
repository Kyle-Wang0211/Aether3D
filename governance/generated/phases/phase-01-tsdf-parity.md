# Phase 01 Runbook - TSDF Parity

## Objective
Complete Track P TSDF migration with deterministic behavior and no Core impurity.

## Entry Criteria
- Prerequisite phases passed: 0
- Track: P

## Required Contracts
- `C-TRACK-P-LEGAL-BASELINE` [active] - Track P parity is legal baseline
- `C-CORE-NO-CONCURRENCY-PRIMITIVES` [active] - Core forbids mutex/thread/atomic primitives
- `C-PIT2-VOLUME-GATING` [active] - Watertight result gates measured volume
- `C-EXACT-PIPELINE-IO-CLOSED` [active] - EXACT-ONLY pipeline IO closed sets are inviolable

## Required Gates
- `G-CONTRACT-VALIDATOR` (error) - Governance registry and contract validation
- `G-SWIFT-BUILD` (error) - Swift build and target tests

## Cursor Steps
1. Implement TSDF modules in delivery order.
2. Run parity fixtures and TSDF-specific tests.
3. Record benchmark and determinism evidence.
4. Tag integration checkpoint phase-1-pass.

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
- `aether/tsdf/*`
- `TSDF parity test logs`

## Exit Criteria
- All required gates pass.
- Governance strict validation returns zero errors.
- Tag checkpoint `phase-1-pass` on `codex/protocol-governance-integration`.
