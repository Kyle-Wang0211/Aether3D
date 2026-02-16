# Protocol Governance Engineering (Extreme Edition)

This directory is the machine-executable governance layer for the Aether3D pipeline.
It converts architectural rules into deterministic artifacts that Cursor and CI can execute.

## Goals

1. Single source of truth for contracts, constants, flags, gates, and phase sequencing.
2. Deterministic runbooks for every phase (0-13) generated from SSOT data.
3. Drift detection between contracts and implementation (`Core/`, `App/`, `server/`, docs).
4. Release safety: blocked contracts are visible, auditable, and gate-enforced.

## Governance Assets

- `contract_registry.json`: canonical contract and constant registry.
- `phase_plan.json`: executable phase plan (0-13) with prerequisites and deliverables.
- `ci_gate_matrix.json`: gate IDs, commands, and required evidence artifacts.
- `code_bindings.json`: regex-based value bindings from contracts/constants to source files.
- `structural_checks.json`: required/forbidden code patterns for contract compliance.
- `schema/*.schema.json`: explicit schemas for all governance files.
- `scripts/validate_governance.py`: validation engine + diagnostics report generator.
- `scripts/generate_cursor_runbooks.py`: deterministic phase runbook generator.

## Long-lived Integration Branch Strategy

Branch model is intentionally single-stream:

- Integration branch: `codex/protocol-governance-integration`
- Stable branch: `main`
- No per-phase branch split.
- Each phase closure is represented by a signed tag (`phase-0-pass` ... `phase-13-pass`).

This keeps cross-phase dependency resolution linear and prevents branch fanout drift.

## Cursor Execution Contract

Cursor must execute governance in this exact order:

1. `python3 governance/scripts/validate_governance.py --report governance/generated/governance_diagnostics.json`
2. `python3 governance/scripts/generate_cursor_runbooks.py --output governance/generated/phases`
3. Open the relevant phase runbook from `governance/generated/phases/`.
4. Execute phase tasks in listed order.
5. Execute all required gates from `ci_gate_matrix.json` for that phase.
6. Save evidence artifacts listed in the gate definitions.
7. Re-run strict validation:
   - `python3 governance/scripts/validate_governance.py --strict --report governance/generated/governance_diagnostics.json`
8. Create phase checkpoint tag only when strict mode has zero errors.

## Blocked Contract Policy

A blocked contract means release is prohibited for any phase that requires that contract.
Blocked contracts are not hidden debt; they are first-class work items with explicit diagnostics.

## Determinism Requirements

- Runbook generation must be deterministic (`--check` mode must pass).
- Contract IDs (`C-*`), constants (`K-*`), gates (`G-*`) are immutable identifiers.
- Numeric values used by runtime code must be bound through `code_bindings.json` checks.

## CI Integration

Use `.github/workflows/protocol-governance.yml` to run:

- contract validation,
- runbook determinism check,
- gate-critical checks (constants, flags, section ordering).

CI is allowed to fail while contracts are blocked; failure is intentional visibility.
