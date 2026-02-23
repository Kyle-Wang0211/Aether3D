# ADR-PR6-004: Q15 LUT for Aging (Not Runtime exp())

## Status
Accepted

## Context
Evidence aging requires exponential decay calculations. Using `exp()` at runtime:
- Violates determinism (floating-point precision varies)
- Performance overhead (transcendental functions)
- Cross-platform differences possible

## Decision
Use **Q15 fixed-point LUT (Look-Up Table)** for aging factor calculations:
- Pre-computed table of aging factors (half-life based)
- Fixed-point arithmetic (Q15 format: 1 sign bit + 15 fractional bits)
- Deterministic lookup → deterministic result
- No runtime `exp()` calls

Implementation: Aging factors computed via LUT lookup based on time delta and confidence level.

## Consequences
**Positive:**
- Cross-platform deterministic results
- Better performance (LUT lookup vs. exp())
- Predictable precision (fixed-point)

**Negative:**
- Limited precision (Q15: ~0.00003 resolution)
- Table size trade-off (more bins = more memory, better precision)
- Requires careful LUT design and validation
