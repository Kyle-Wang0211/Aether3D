# P4-T01: DeterministicScheduler with SplitMix64 PRNG

**Phase**: 4 - Deterministic Replay Engine  
**Dependencies**: None  
**Estimated Duration**: 3-4 days

## Goal

Implement Deterministic Simulation Testing (DST) scheduler with SplitMix64 PRNG for cross-platform deterministic randomness, deterministic task ordering, and Swift 6.2 strict concurrency compliance.

## Non-Goals

- Implementing full DST framework (scheduler only, fault injection in P4-T03)
- Supporting real concurrency (single-threaded simulation semantics)
- Implementing task cancellation (tasks run to completion)

## Inputs / Outputs

**Inputs**:
- Seed: UInt64 (for PRNG initialization)
- Task: Async closure (task to schedule)
- Scheduled time: UInt64 (nanoseconds)

**Outputs**:
- Task execution: Deterministic execution trace
- Random numbers: UInt64 (deterministic PRNG output)

## Public Interfaces

**DeterministicScheduler** (actor):
- `init(seed: UInt64)`
- `currentTimeNs: UInt64` (property)
- `seed: UInt64` (property)
- `schedule(at timeNs: UInt64, task: @escaping () async -> Void) -> TaskHandle`
- `advance(by deltaNs: UInt64) async`
- `runUntilIdle() async`
- `random() -> UInt64`
- `random(in range: Range<UInt64>) -> UInt64`

**TaskHandle** (struct, Sendable):
- `id: UInt64`

**DeterministicSchedulerError** (enum, Error, Sendable):
- `invalidSeed`
- `taskExecutionFailed(underlying: Error)`

## Acceptance Criteria

1. **PRNG Initialization**: Initialize SplitMix64 PRNG with seed. If seed=0, remap to 1 (avoid zero state).
2. **SplitMix64 Algorithm**: Implement SplitMix64 algorithm with explicit overflow handling (all operations use & 0xFFFFFFFFFFFFFFFF for UInt64 overflow).
3. **Deterministic Randomness**: Same seed produces identical PRNG sequence on macOS and Linux (cross-platform determinism verified).
4. **Task Scheduling**: Schedule task at given time. Tasks stored in priority queue sorted by (scheduledTime, taskId).
5. **Task Ordering**: Stable sort: (scheduledTime, taskId). If two tasks have same scheduledTime, taskId breaks tie (monotonic counter).
6. **Time Advancement**: Advance virtual time by delta. Execute all tasks scheduled <= new time.
7. **Run Until Idle**: Execute all scheduled tasks until queue is empty.
8. **Random Number Generation**: Generate deterministic random UInt64 using SplitMix64.
9. **Random Range**: Generate random number in range [lower, upper) using modulo arithmetic (deterministic).
10. **Cross-Platform**: Same seed produces identical execution trace on macOS and Linux (verified with golden fixtures).
11. **Swift 6.2 Concurrency**: Actor isolation ensures thread safety. No @unchecked Sendable unless explicitly justified.

## Failure Modes & Error Taxonomy

**Initialization Errors**:
- `DeterministicSchedulerError.invalidSeed`: Seed validation failed (should not occur, seed=0 remapped to 1)

**Execution Errors**:
- `DeterministicSchedulerError.taskExecutionFailed`: Task execution threw error (underlying error wrapped)

## Determinism & Cross-Platform Notes

- **SplitMix64**: Explicit overflow handling ensures cross-platform determinism (all operations use & 0xFFFFFFFFFFFFFFFF).
- **Task Ordering**: Stable sort ensures deterministic execution order (same seed = same task execution order).
- **Time Advancement**: Deterministic time advancement (same seed = same time progression).

## Security Considerations

**Abuse Cases**:
- PRNG prediction: SplitMix64 provides cryptographic-quality randomness (sufficient for testing, not for production crypto)
- Task injection: Tasks are scheduled deterministically (no external injection)

**Parsing Limits**:
- Seed: UInt64 range (0 remapped to 1)
- Scheduled time: UInt64 range (no overflow checks needed for reasonable time values)
- Task count: No hard limit (UInt64 taskId allows 2^64 tasks)

**Replay Protection**:
- Not applicable (DST is for testing, not production security)

**Key Pinning**:
- Not applicable (no keys involved)

## Rollback Plan

1. Delete `Core/Replay/DeterministicScheduler.swift`
2. Delete `Core/Replay/TaskHandle.swift`
3. Delete `Core/Replay/DeterministicSchedulerError.swift`
4. Delete `Core/Replay/SplitMix64.swift` (if separate file)
5. Delete `Tests/Replay/DeterministicSchedulerTests.swift`
6. No database schema changes
7. No impact on existing code

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
- [x] SplitMix64 algorithm specified
- [x] Swift 6.2 concurrency compliance noted
