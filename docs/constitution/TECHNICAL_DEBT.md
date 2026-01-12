# Technical Debt Ledger

> Known limitations and deferred improvements for the SSOT system.
> Each item should be addressed in a future PR.

---

<!-- SSOT:DEBT:BEGIN -->
## Active Debt Items

| ID | Category | Description | Severity | Target |
|----|----------|-------------|----------|--------|
| DEBT-001 | Scanner | pow(2,10) not detected as magic | Low | PR#5+ |
| DEBT-002 | Scanner | String interpolation magic undetected | Low | PR#5+ |
| DEBT-003 | Types | AnyConstantSpec loses type info | Medium | PR#3+ |
| DEBT-004 | Platform | Linux path resolution untested | Medium | PR#2 |
| DEBT-005 | Platform | Xcode working directory untested | Low | PR#2 |
<!-- SSOT:DEBT:END -->

---

## Debt Categories

| Category | Description |
|----------|-------------|
| Scanner | Magic number/pattern detection gaps |
| Types | Type system modeling limitations |
| Platform | Cross-platform compatibility issues |
| Performance | Runtime performance limitations |
| Validation | Validation coverage gaps |

## Resolution Process

1. Create PR addressing debt item
2. Update this file to mark resolved
3. Move to CHANGELOG section below

---

<!-- SSOT:DEBT_RESOLVED:BEGIN -->
## Resolved Debt

| ID | Resolved In | Date |
|----|-------------|------|
| — | — | — |
<!-- SSOT:DEBT_RESOLVED:END -->
