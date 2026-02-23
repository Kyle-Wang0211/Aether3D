# ADR-PR6-005: Open Addressing Index Map (Not Swift Dictionary)

## Status
Accepted

## Context
Swift `Dictionary` and `Set` provide non-deterministic iteration order, violating cross-platform determinism requirements. EvidenceGrid needs deterministic iteration for:
- Coverage calculation
- PIZ analysis
- State serialization

## Decision
Use **deterministic open-addressing index map** instead of Swift Dictionary:
- `stableKeyList`: Append-only array of `SpatialKey` (deterministic order)
- `indexMap`: `[SpatialKey: Int]` mapping key → list index
- Iteration uses `stableKeyList` (deterministic), not `indexMap.keys`

This ensures same insertion order → same iteration order across platforms.

## Consequences
**Positive:**
- Deterministic iteration order (critical requirement)
- Predictable performance (array iteration)
- No Set/Dictionary iteration in hot paths

**Negative:**
- More complex implementation (manual index management)
- Tombstone handling required for eviction
- Compaction needed to remove tombstones
