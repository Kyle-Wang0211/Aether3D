# ADR-PR6-001: Composition Layer Architecture

## Status
Accepted

## Context
PR6 Evidence Grid System needs to extend the existing evidence engine (PR1-PR5) without breaking backward compatibility or replacing existing components. The existing system has proven stable and is in production use.

## Decision
Implement PR6 as a **composition layer** that extends existing components rather than replacing them. PR6 components wrap and enhance existing functionality:

- `MultiLedger` wraps `SplitLedger` and adds `provenanceLedger` and `advancedLedger`
- `EvidenceGrid` operates alongside existing `PatchEvidenceMap` structures
- `CoverageEstimator` uses existing `EvidenceConfidenceLevel` enum (extended with L4-L6)
- `PIZGridAnalyzer` uses existing `PIZRegion` type from `Core/PIZ/PIZRegion.swift`

## Consequences
**Positive:**
- Zero breaking changes to existing code
- Existing tests continue to pass
- Gradual migration path possible
- Clear separation of concerns

**Negative:**
- Some code duplication (e.g., ledger structures)
- Additional complexity in understanding system architecture
- Requires careful coordination between old and new systems
