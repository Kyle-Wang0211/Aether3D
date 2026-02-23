# Full Phase Automation Runbook

## Goal
Execute the whole phase pipeline (`phase_plan.json`) in strict sequence:
- phase-by-phase gate execution
- strict phase completion contract execution (`governance/phase_completion_contracts.json`)
- post-phase adaptation checks
- hard stop on failure
- phase report + global manifest outputs

## Entry Commands

### 1) Smoke (dry run)
```bash
cd /Users/kaidongwang/Documents/progecttwo/progect2/progect2
./scripts/run_full_phase_pipeline.sh --from-phase 0 --to-phase 15 --dry-run
```

### 2) Real execution (strict)
```bash
cd /Users/kaidongwang/Documents/progecttwo/progect2/progect2
./scripts/run_full_phase_pipeline.sh --fresh-state --from-phase 0 --to-phase 15 --enforce-deliverables
```

### 3) Continue after fix
```bash
cd /Users/kaidongwang/Documents/progecttwo/progect2/progect2
./scripts/run_full_phase_pipeline.sh --resume --to-phase 15 --enforce-deliverables
```

## Outputs

- Global manifest:
  - `governance/generated/phases/pipeline_manifest.json`
- Rolling state:
  - `governance/generated/phases/pipeline_state.json`
- Per-phase reports:
  - `governance/generated/phases/pipeline_reports/phase-XX-report.json`

## Phase Failure Loop (Required)

1. Open the failed report file: `phase-XX-report.json`.
2. Check:
   - `failed_reasons`
   - `gate_output`
   - `strict_completion_output`
   - `deliverables.missing`
   - `adaptation_reasons`
3. Fix code/config/contracts.
4. Re-run with `--resume`.
5. Do not manually skip failed phases.

## Hard Rules

- No phase skipping.
- Missing prerequisites block execution.
- Gate failure blocks forward progress.
- Strict phase completion check failure blocks forward progress.
- With `--enforce-deliverables`, missing path-like deliverables block phase pass.
- Adaptation checks (governance diagnostics / first-scan KPI where required) must pass before moving on.
- Emergency escape hatch only for diagnosis: `--skip-strict-completion` (must not be used for release sign-off).
