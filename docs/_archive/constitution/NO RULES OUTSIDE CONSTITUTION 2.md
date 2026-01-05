> ARCHIVED — DO NOT USE AS SOURCE OF TRUTH.
> This document is historical and may be inconsistent with current specifications.
> Refer to docs/WHITEBOX.md and docs/ACCEPTANCE.md for the authoritative version.

# Rules Boundary Enforcement

## Purpose

This document enforces that **all rules, policies, and specifications MUST be written only in authorized locations**. Any rule written outside these locations is considered a violation.

## Authorized Locations

Rules, policies, and specifications are ONLY allowed in:
- `docs/constitution/**` - All constitution documents
- `docs/rfcs/**` - RFC documents (proposals, not final rules)

## Forbidden Locations

Rules MUST NOT be written in:
- `README.md` - Only navigation allowed
- `docs/WHITEBOX.md` - Only technical specifications allowed
- `docs/ACCEPTANCE.md` - Only acceptance criteria allowed
- `docs/WORKFLOW.md` - Only workflow procedures allowed
- `docs/ROLLBACK.md` - Only rollback procedures allowed
- Code comments - No policy rules in code
- Any other `docs/**` files (except `docs/constitution/**` and `docs/rfcs/**`)

## Keyword Blacklist

The following keywords indicate rule/policy content and MUST NOT appear outside authorized locations:
- Policy Hash
- Decision Hash
- Gate
- Determinism
- Audit Schema
- Invariant
- Signing
- Nonce
- Anchor
- Non-deterministic
- Policy enforcement
- Rule enforcement
- Specification requirement

## Violation Detection

The `preflight.sh` script includes a "Rules Spill Check" that scans for these keywords in forbidden locations. Any match will cause the preflight check to fail.

## Enforcement

Any rule found outside authorized locations must be:
1. Moved to the appropriate constitution document
2. Removed from the forbidden location
3. Documented in a constitution changelog entry

