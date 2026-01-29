# Contributing to Aether3D

**Version:** 1.0.0  
**Status:** Binding  
**Owner:** @kaidongwang

All contributions are subject to governance in docs/constitution/.

Constitutional documents supersede this file in case of conflict.

Priority order: Per GATES_POLICY.md "Priority Order" section.

## Location Context

**File Location:** Repository root

**Directory Hierarchy Note:**

Files in docs/constitution/ are not inherently Binding.

Binding status determined by Status field in each document.

GATES_POLICY.md is Binding; GOVERNANCE_SPEC.md is Informational.

## Governance PR Classification

**Automatic Classification:**

PR is governance PR if it modifies any file in:
- CODEOWNERS
- CONTRIBUTING.md
- SECURITY.md
- docs/constitution/**
- docs/rfcs/**

Classification determined by file paths only.

PR title, labels, or description do not affect classification.

**Governance Language in Non-Governance Paths:**

Any normative governance language (rules using must/required/forbidden/mandatory) outside governance paths is forbidden.

Such PRs must be rejected.

Governance rules must reside in governance paths only.

## Atomic Governance PRs

**File Restriction:**

Governance PRs must modify ONLY files in governance paths listed above.

Modifying other files triggers rejection.

**Exception - Emergency:**

PRs with EMERGENCY commit message (per GATES_POLICY.md "Emergency Commit Format" section) permitted to modify files per GATES_POLICY.md "Emergency File Allowlist" section.

**Non-Governance PRs:**

PRs not touching governance paths are not subject to file restrictions.

Non-governance PRs must not introduce governance language (rules) outside governance paths.

## RFC Requirement

**When RFC Required:**

Governance PRs making substantive changes require RFC reference per GATES_POLICY.md "RFC Reference Format" section.

**When RFC Not Required:**

Governance PRs limited to GATES_POLICY.md "Non-Substantive Changes" section allowlist do not require RFC.

**Substantive Determination:**

Owner classifies changes as substantive or non-substantive.

Classification must align with allowlist boundaries.

Changes affecting enumerated RFC triggers are substantive by definition.

Ambiguous cases default to RFC-required.

## Pre-Commit Checks (Conditional)

**If scripts/preflight.sh Exists:**

Running preflight before commit helps identify issues early.

Execution is informational (not enforced).

```bash
bash scripts/preflight.sh
```

**If scripts/preflight.sh Does Not Exist:**

Skip without error.

No validation failure if script absent.

**Authority:**

CI verdict is authoritative (implementation begins PR#12).

Preflight is advisory tool when available.

scripts/preflight.sh becomes governance-protected once created (requires RFC to modify).

## PR1 PIZ Gate Discipline

**Applicability:**

PR1 branches (branch names containing `pr1`) require local pre-push gate checks.

**Policy:**

**Skipped equals failure.** CI does not allow skipped/cancelled checks. Local gate must pass before push.

**Installation:**

Install Git hooks before first push on PR1 branches:

```bash
bash scripts/dev/install-githooks.sh
```

**Gate Checks:**

The pre-push hook runs four checks sequentially:

1. Lint PIZ thresholds (`bash scripts/ci/lint_piz_thresholds.sh`)
2. Run PIZ tests (`swift test --filter PIZ`)
3. Generate canonical JSON (`swift run PIZFixtureDumper`)
4. Generate sealing evidence (`swift run PIZSealingEvidence`)

**Manual Execution:**

Run gate manually:

```bash
bash scripts/ci/piz_local_gate.sh
```

**Push Behavior:**

- Push is blocked if any check fails
- Error message: "Skipped=Failure policy. Fix locally first."
- Use `git push --no-verify` to bypass (not recommended)
- All checks must pass before push proceeds

**Authority:**

Local gate is advisory; CI verdict is authoritative.

Local gate prevents pushing code that would fail CI checks.

**CI Behavior:**

- CI does not cancel in-progress runs when new commits are pushed (prevents macOS job cancellation)
- Matrix jobs use `fail-fast: false` to prevent one platform failure from cancelling others
- macOS jobs use retry (3 attempts) for flaky steps (swift test, PIZFixtureDumper)
- Skipped checks are treated as failures (no-skip policy)

## Branch Naming

**Required Formats:**
- `phase1/<topic>`
- `feat/<topic>`
- `hotfix/<topic>`
- `feat/rfc-NNNN-<topic>` (RFC implementation)

Non-conforming names result in PR rejection.

## Commit Messages

**General Rules:**
- Imperative mood ("Add feature" not "Added feature")
- No trailing punctuation
- First line under 72 characters (guideline)

**Governance Commits:**

RFC implementation: Per GATES_POLICY.md "RFC Reference Format" section (title and body).

Emergency: Per GATES_POLICY.md "Emergency Commit Format" section.

**Examples:**
```
Add rate limiting to API
Update documentation for clarity
[RFC-0005] Update gate policy
EMERGENCY: API_KEY_LEAK / Gate1 / INC-20260107-001
```

## Pull Request Requirements

**Merge Prerequisites:**

1. All CI checks pass (blocking gates per GATES_POLICY.md "Gate Set" section), OR
   Valid RFC bypass (GATES_POLICY.md "RFC Bypass Mechanism" sections), OR
   EMERGENCY override (GATES_POLICY.md "Emergency Override" sections)

2. Required reviewers approve (GitHub "Approve" action)

3. RFC reference present if governance PR with substantive changes

4. Cross-references valid (all referenced files and sections exist)

## Violation Handling

**Detection:**

Non-emergency violations detected before merge.

**Response:**

Violations must be corrected before merge.

Intent is irrelevant for detection and correction requirement.

**Emergency Exception:**

EMERGENCY commits (per GATES_POLICY.md "Emergency Commit Format" section) exempt during 24h window.

Follow-up required per GATES_POLICY.md "Emergency Override" section.

**Bad Faith:**

Formally compliant actions defeating governance intent constitute violations.

Owner adjudicates bad faith cases.

Intent relevant for severity and response, not for detection.

