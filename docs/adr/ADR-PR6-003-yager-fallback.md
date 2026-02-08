# ADR-PR6-003: Yager Fallback for D-S Conflict

## Status
Accepted

## Context
Dempster-Shafer combination rule can produce numerical instability when conflict K approaches 1.0. Normalization factor 1/(1-K) explodes, leading to NaN/Inf values.

## Decision
Use **Yager's combination rule** as fallback when conflict K >= `dsConflictSwitch` (0.85). Yager assigns conflict mass to the "unknown" hypothesis, avoiding numerical explosion:

- If K < 0.85: Use Dempster's rule (normal combination)
- If K >= 0.85: Use Yager's rule (conflict → unknown)

## Consequences
**Positive:**
- Prevents numerical instability
- Graceful degradation under high conflict
- Preserves mass function invariants (O+F+U=1.0)

**Negative:**
- Loss of information (high conflict scenarios lose specificity)
- Threshold selection (`dsConflictSwitch`) requires tuning
- May mask underlying data quality issues
