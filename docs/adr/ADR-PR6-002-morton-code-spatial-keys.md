# ADR-PR6-002: Morton Code for Spatial Keys

## Status
Accepted

## Context
EvidenceGrid needs deterministic spatial hashing for 3D coordinates. Standard hash functions (e.g., Swift Dictionary) provide non-deterministic iteration order, which violates cross-platform determinism requirements.

## Decision
Use **Morton codes** (Z-order curves) for spatial key generation. Morton codes:
- Map 3D integer coordinates to a single UInt64 value
- Preserve spatial locality (nearby cells have similar codes)
- Provide deterministic ordering (same coordinates → same code)
- Support efficient range queries

Implementation: `SpatialQuantizer` converts world coordinates → integer grid coordinates → Morton code.

## Consequences
**Positive:**
- Deterministic iteration order (critical for cross-platform determinism)
- Efficient spatial queries
- Simple integer-based keys (no floating-point issues)

**Negative:**
- Limited to 21 bits per dimension (63 total bits in UInt64)
- Requires quantization step (world → grid coordinates)
- Morton code computation adds small overhead
