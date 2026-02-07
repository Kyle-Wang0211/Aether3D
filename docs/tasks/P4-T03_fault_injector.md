# P4-T03: FaultInjector with Deterministic Faults

**Phase**: 4 - Deterministic Replay Engine  
**Dependencies**: P4-T01 (DeterministicScheduler)  
**Estimated Duration**: 2-3 days

## Goal

Implement fault injection for chaos testing in DST using seeded PRNG for deterministic fault generation. Support network partition, disk error injection, and clock skew.

## Non-Goals

- Implementing real network/disk faults (simulation only)
- Supporting fault recovery (faults are deterministic, no recovery needed)
- Implementing fault scheduling (faults are immediate, not scheduled)

## Inputs / Outputs

**Inputs**:
- DeterministicScheduler: Actor instance (for PRNG)
- Fault configuration: Network partition, disk error probability, clock skew

**Outputs**:
- Fault injection events: Network partition status, disk error status, clock skew offset

## Public Interfaces

**FaultInjector** (actor):
- `init(scheduler: DeterministicScheduler)`
- `injectNetworkPartition(between nodeA: String, and nodeB: String, durationNs: UInt64)`
- `canCommunicate(_ nodeA: String, _ nodeB: String) -> Bool`
- `setDiskErrorProbability(_ probability: Double)`
- `shouldDiskOperationFail() async -> Bool`
- `setClockSkew(ns: Int64)`
- `getSkewedTimeNs() async -> UInt64`

**FaultInjectorError** (enum, Error, Sendable):
- `invalidProbability`
- `invalidDuration`

## Acceptance Criteria

1. **Network Partition**: Inject partition between two nodes. Partition is symmetric (A↔B blocked implies B↔A blocked). Partition heals after duration.
2. **Partition Key**: Partition key = sorted([nodeA, nodeB]).joined(separator: "<->") for deterministic identification.
3. **Communication Check**: Check if two nodes can communicate (not partitioned). Return boolean.
4. **Disk Error Probability**: Set disk error probability [0.0, 1.0]. Use seeded PRNG to determine if operation should fail.
5. **Disk Error Check**: Check if disk operation should fail using PRNG. Probability-based, deterministic (same seed = same failures).
6. **Clock Skew**: Set clock skew offset (nanoseconds). Apply offset to scheduler time.
7. **Skewed Time**: Get skewed time (scheduler time + skew offset). Used for time-dependent fault injection.
8. **Deterministic Faults**: All faults derived from seeded PRNG (same seed = same faults).
9. **Cross-Platform**: PRNG-based faults produce identical results on macOS and Linux (deterministic).

## Failure Modes & Error Taxonomy

**Configuration Errors**:
- `FaultInjectorError.invalidProbability`: Probability not in [0.0, 1.0]
- `FaultInjectorError.invalidDuration`: Duration is invalid (negative or too large)

## Determinism & Cross-Platform Notes

- **PRNG-Based Faults**: All faults use seeded PRNG from DeterministicScheduler (deterministic).
- **Partition Symmetry**: Partition is symmetric (deterministic key generation).
- **Probability**: Probability-based faults use PRNG (deterministic for same seed).

## Security Considerations

**Abuse Cases**:
- Fault injection in production: FaultInjector is for testing only (not used in production code)

**Parsing Limits**:
- Probability: [0.0, 1.0] range (clamp to range if out of bounds)
- Duration: UInt64 range (no overflow checks needed for reasonable durations)

**Replay Protection**:
- Not applicable (faults are deterministic for testing)

**Key Pinning**:
- Not applicable (no keys involved)

## Rollback Plan

1. Delete `Core/Replay/FaultInjector.swift`
2. Delete `Core/Replay/FaultInjectorError.swift`
3. Delete `Tests/Replay/FaultInjectorTests.swift`
4. No impact on DeterministicScheduler

## Open Questions

None.

---

**Implementation Not Started: Verified**

**Checklist**:
- [x] No Swift code implementations included
- [x] No test code included
- [x] Only interface names and signatures provided
- [x] Acceptance criteria are testable and fail-closed
- [x] Error taxonomy is complete
- [x] Security considerations addressed
