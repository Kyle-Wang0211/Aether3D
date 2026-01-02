# Document Scope Boundaries

## Purpose

This document defines what content is allowed and forbidden in each document type.

## Document Scope Matrix

| Document | Allowed Content | Forbidden Content |
|----------|----------------|-------------------|
| `README.md` | Project one-line description<br>Navigation links<br>Start here pointer | Any rules<br>Policy definitions<br>Thresholds<br>Gates<br>Strategy details |
| `docs/WHITEBOX.md` | Technical specifications<br>Whitebox requirements<br>Implementation details | Policy rules<br>Decision hashes<br>Audit schemas |
| `docs/ACCEPTANCE.md` | Acceptance criteria<br>Test requirements<br>Validation rules | Policy enforcement<br>Determinism rules |
| `docs/WORKFLOW.md` | Workflow procedures<br>Branch strategy<br>Merge rules | Policy hashes<br>Decision hashes |
| `docs/ROLLBACK.md` | Rollback procedures<br>Emergency steps | Policy definitions |
| `docs/constitution/**` | All rules<br>All policies<br>All specifications<br>All constraints | N/A (this is the SSOT) |
| `docs/rfcs/**` | RFC proposals<br>Change proposals | Final rules (must be in constitution) |

## Enforcement

- `preflight.sh` includes a "Rules Spill Check" that validates these boundaries
- Any violation will cause the preflight check to fail
- Violations must be corrected before merging

