# Phase 00 Runbook - Golden Fixtures Baseline

## Objective
Generate and lock deterministic Swift golden fixtures before any C++ parity work.

## Entry Criteria
- Prerequisite phases passed: none
- Track: P

## Required Contracts
- `C-PHASE-ORDERING-LAW` [active] - Phase ordering is mandatory
- `C-FIXTURE-PHASE0-MANDATORY` [active] - Phase 0 golden fixtures must pass before any Track P migration
- `C-TRACK-P-LEGAL-BASELINE` [active] - Track P parity is legal baseline
- `C-LONG-LIVED-INTEGRATION-BRANCH` [active] - Single long-lived integration branch with phase tags

## Required Gates
- `G-LONG-LIVED-BRANCH` (error) - Long-lived integration branch is active
- `G-CONTRACT-VALIDATOR` (error) - Governance registry and contract validation
- `G-RUNBOOK-GENERATION` (error) - Cursor runbook generation is deterministic
- `G-FIXTURE-BASELINE` (error) - Golden fixture baseline present and reproducible

## Cursor Steps
1. Run governance validator and generation pipeline.
2. Generate fixture baselines from Swift tools.
3. Store and hash-lock fixture artifacts.
4. Tag integration branch checkpoint phase-0-pass.

## Gate Commands
### G-LONG-LIVED-BRANCH
Long-lived integration branch is active

```bash
python3 governance/scripts/validate_governance.py --check-branch
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

### G-RUNBOOK-GENERATION
Cursor runbook generation is deterministic

```bash
python3 governance/scripts/generate_cursor_runbooks.py --output governance/generated/phases
python3 governance/scripts/generate_cursor_runbooks.py --check --output governance/generated/phases
```

Expected artifacts:
- `governance/generated/phases/index.md`

### G-FIXTURE-BASELINE
Golden fixture baseline present and reproducible

```bash
swift run FixtureGen
swift run PR4MathFixtureExporter
```

Expected artifacts:
- `Tests/Fixtures/uuid_rfc4122_vectors_v1.txt`
- `Tests/Fixtures/decision_hash_v1.txt`
- `Tests/Fixtures/admission_decision_v1.txt`
- `Tests/Fixtures/PR4Math/pr4math_golden_v1.json`

## Deliverables
- `Tests/Fixtures/*.txt`
- `Tests/Fixtures/PR4Math/pr4math_golden_v1.json`
- `governance/generated/governance_diagnostics.json`

## Exit Criteria
- All required gates pass.
- Governance strict validation returns zero errors.
- Tag checkpoint `phase-0-pass` on `codex/protocol-governance-integration`.
