# P4-T02: Async TimeSource Protocol Migration

**Phase**: 4 - Deterministic Replay Engine  
**Dependencies**: P4-T01 (DeterministicScheduler)  
**Estimated Duration**: 2-3 days

## Goal

Migrate TimeSource protocol to async, implement MockTimeSource compatible with DeterministicScheduler, and ensure Swift 6.2 strict concurrency compliance without @unchecked Sendable unless explicitly justified.

## Non-Goals

- Migrating all existing TimeSource call sites (migration handled incrementally)
- Supporting sync TimeSource compatibility (async only)
- Implementing time source abstraction for production (MockTimeSource for tests only)

## Inputs / Outputs

**Inputs**:
- DeterministicScheduler: Actor instance
- Current time request: Async call

**Outputs**:
- Time in milliseconds: Int64 (async)

## Public Interfaces

**TimeSource** (protocol):
- `func nowMs() async -> Int64`

**MockTimeSource** (struct, TimeSource, Sendable):
- `init(scheduler: DeterministicScheduler)`
- `nowMs() async -> Int64`

**SystemTimeSource** (struct, TimeSource, Sendable):
- `init()`
- `nowMs() async -> Int64`

**TimeSourceError** (enum, Error, Sendable):
- `schedulerNotAvailable`
- `timeRetrievalFailed`

## Acceptance Criteria

1. **Protocol Definition**: TimeSource protocol requires async nowMs() method (no sync variant).
2. **MockTimeSource Implementation**: MockTimeSource wraps DeterministicScheduler, returns scheduler.currentTimeNs / 1_000_000 (async access to actor property).
3. **SystemTimeSource Implementation**: SystemTimeSource uses MonotonicClock.nowMs() (sync call wrapped in async function).
4. **Swift 6.2 Compliance**: No @unchecked Sendable unless explicitly justified in ADR. MockTimeSource uses actor isolation correctly (async access to actor property).
5. **Cross-Platform**: MockTimeSource works identically on macOS and Linux (actor isolation is platform-independent).
6. **Determinism**: MockTimeSource returns deterministic time (from DeterministicScheduler). SystemTimeSource returns non-deterministic time (expected for production).

## Failure Modes & Error Taxonomy

**Initialization Errors**:
- `TimeSourceError.schedulerNotAvailable`: DeterministicScheduler not available (should not occur in normal operation)

**Retrieval Errors**:
- `TimeSourceError.timeRetrievalFailed`: Time retrieval failed (underlying error wrapped)

## Determinism & Cross-Platform Notes

- **Actor Isolation**: Async access to actor properties ensures thread safety (Swift 6.2 compliant).
- **MockTimeSource**: Deterministic (returns scheduler time). SystemTimeSource: Non-deterministic (returns MonotonicClock time, expected for production).

## Security Considerations

**Abuse Cases**:
- Time manipulation: MockTimeSource uses scheduler time (controlled in tests). SystemTimeSource uses MonotonicClock (protected from manipulation).

**Parsing Limits**:
- Not applicable (no parsing involved)

**Replay Protection**:
- Not applicable (time source is read-only)

**Key Pinning**:
- Not applicable (no keys involved)

## Rollback Plan

1. Delete `Core/Replay/MockTimeSource.swift`
2. Delete `Core/Replay/SystemTimeSource.swift`
3. Revert TimeSource protocol changes (if protocol was modified)
4. No impact on existing code (if protocol migration is incremental)

## Open Questions

- **ADR Required**: If @unchecked Sendable is needed for MockTimeSource, document justification in ADR-010 with containment boundary analysis.

---

**Implementation Not Started: Verified**

**Checklist**:
- [x] No Swift code implementations included
- [x] No test code included
- [x] Only interface names and signatures provided
- [x] Acceptance criteria are testable and fail-closed
- [x] Error taxonomy is complete
- [x] Security considerations addressed
- [x] Swift 6.2 concurrency compliance specified
- [x] @unchecked Sendable justification noted if needed
