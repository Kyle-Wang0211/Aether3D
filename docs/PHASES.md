# Phase Definitions and Guardrails

## Phase 0 (Frozen Baseline)
- **Definition**: Architecture and engineering baseline is frozen; used only as stable starting point.
- **Tag**: `phase0` (read-only, must never move).
- **Entry**: Baseline established and buildable; no further changes allowed.
- **Exit / Acceptance**: Tag `phase0` exists; build passes; no pending work.
- **Allowed**: Checkout `phase0` for inspection only.
- **Prohibited**: Modifying any Swift/Metal/Xcode engineering code; git reset/rebase to `phase0`; force push involving `phase0`.
- **Rollback Philosophy**: Revert-only. Any rollback must use `git revert`; history on `main` only appends forward.

## Phase 0.5 (Guardrails / Versioning)
- **Definition**: Establishes “revertable, history-safe” development guardrails; no feature work.
- **Entry**: Phase 0 complete; working from `main` or a branch derived from `main`.
- **Exit / Acceptance**: Guardrail docs and policies in place; Phase 0 tag respected; revert-only rule documented; no code changes to the baseline.
- **Allowed**: Add or update documentation under `docs`.
- **Prohibited**: Modifying any Swift/Metal/Xcode engineering files.
- **Rollback Philosophy**: Revert-only. Use `git revert` for any backward change; do not rewrite history.

## Phase 1 (Feature Development)
- **Definition**: Functional development stage.
- **Entry**: Must branch from `phase0.5` (or `main` after it contains Phase 0.5 guardrails).
- **Exit / Acceptance**: Feature work meets acceptance, is revertable, and follows guardrails.
- **Allowed**: Feature implementation on branches derived from `phase0.5`.
- **Prohibited**: Direct push to `main`; force push; reset/rebase to `phase0`; breaking the revert-only rule.
- **Rollback Philosophy**: Any breaking change is undone via `git revert`; `main` history must only grow forward.





