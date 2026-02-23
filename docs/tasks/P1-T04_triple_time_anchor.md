# P1-T04: TripleTimeAnchor with Interval Intersection Fusion

**Phase**: 1 - Time Anchoring  
**Dependencies**: P1-T01, P1-T02, P1-T03  
**Estimated Duration**: 2-3 days

## Goal

Implement triple time anchor fusion using interval intersection algorithm, requiring at least 2 independently verified sources with non-empty intersection. Output fused time interval [lowerNs, upperNs].

## Non-Goals

- Weighted fusion (all sources treated equally)
- Single-source fallback (require at least 2 sources)
- Time source priority (no preference ordering)

## Inputs / Outputs

**Inputs**:
- SHA-256 hash: 32 bytes (fixed length, fail-closed if not 32 bytes)
- TSAClient instance
- RoughtimeClient instance
- OpenTimestampsAnchor instance

**Outputs**:
- TripleTimeProof: Fused time interval, included evidences, excluded evidences with reasons, anchoring timestamp

## Public Interfaces

**TripleTimeAnchor** (actor):
- `init(tsaClient: TSAClient, roughtimeClient: RoughtimeClient, blockchainAnchor: OpenTimestampsAnchor)`
- `anchor(dataHash: Data) async throws -> TripleTimeProof`

**TripleTimeProof** (struct, Codable, Sendable):
- `dataHash: Data` (32 bytes)
- `fusedTimeInterval: TimeIntervalNs`
- `includedEvidences: [TimeEvidence]`
- `excludedEvidences: [ExcludedEvidence]`
- `anchoredAt: Date`
- `evidenceCount: Int`
- `isValid: Bool`

**TimeIntervalNs** (struct, Codable, Sendable):
- `lowerNs: UInt64`
- `upperNs: UInt64`

**TimeEvidence** (struct, Codable, Sendable):
- `source: Source`
- `timeNs: UInt64`
- `uncertaintyNs: UInt64?`
- `verificationStatus: VerificationStatus`
- `rawProof: Data`
- `timeInterval: (lower: UInt64, upper: UInt64)`
- `agrees(with other: TimeEvidence) -> Bool`

**Source** (enum, Codable, Sendable):
- `tsa`
- `roughtime`
- `opentimestamps`

**ExcludedEvidence** (struct, Codable, Sendable):
- `evidence: TimeEvidence`
- `reason: String`

**TripleTimeAnchorError** (enum, Error, Sendable):
- `insufficientSources(available: Int, required: Int)`
- `timeDisagreement(source1: Source, source2: Source, differenceNs: UInt64)`
- `allSourcesFailed`
- `intervalIntersectionEmpty`

## Acceptance Criteria

1. **Hash Validation**: Input hash must be exactly 32 bytes. If not, throw `TripleTimeAnchorError.insufficientSources(available: 0, required: 2)`.
2. **Parallel Requests**: Request all three sources in parallel (async let).
3. **Individual Verification**: Each source must pass its own verification (CMS for TSA, Ed25519 for Roughtime, OTS for blockchain) before inclusion.
4. **Interval Conversion**: Convert all verified evidences to time intervals:
   - TSA: Point estimate → [timeNs, timeNs] (no uncertainty)
   - Roughtime: [midpointTimeNs - radiusNs, midpointTimeNs + radiusNs]
   - OpenTimestamps: [submittedAtNs - 10min, submittedAtNs + 10min] (conservative estimate)
5. **Interval Intersection**: Compute intersection of all intervals: [max(lower bounds), min(upper bounds)].
6. **Non-Empty Intersection**: Require intersection is non-empty (upper >= lower). If empty, throw `TripleTimeAnchorError.intervalIntersectionEmpty`.
7. **Minimum Sources**: Require at least 2 verified evidences. If < 2, throw `TripleTimeAnchorError.insufficientSources`.
8. **Fused Interval**: Output fused interval as TimeIntervalNs(lowerNs: intersectionLower, upperNs: intersectionUpper).
9. **Excluded Evidences**: Track evidences that failed verification or were excluded due to disagreement, with explicit reasons.
10. **All Sources Failed**: If all three sources failed, throw `TripleTimeAnchorError.allSourcesFailed`.
11. **Cross-Platform**: Interval intersection algorithm produces identical results on macOS and Linux (deterministic arithmetic).
12. **Determinism**: Same hash with same source responses produces identical fused interval (deterministic fusion).

## Failure Modes & Error Taxonomy

**Insufficient Sources**:
- `TripleTimeAnchorError.insufficientSources`: Less than 2 sources succeeded (< 2 verified evidences)
- `TripleTimeAnchorError.allSourcesFailed`: All three sources failed

**Time Disagreement**:
- `TripleTimeAnchorError.timeDisagreement`: Two sources disagree (intervals don't overlap)
- `TripleTimeAnchorError.intervalIntersectionEmpty`: Intersection of all intervals is empty (upper < lower)

## Determinism & Cross-Platform Notes

- **Interval Arithmetic**: All interval calculations use deterministic arithmetic (no floating-point, no platform-specific behavior).
- **Time Conversion**: All timestamps converted to nanoseconds since Unix epoch, Big-Endian encoding for serialization.
- **Parallel Execution**: async let ensures parallel requests, but order of completion is non-deterministic (acceptable, as long as fusion is deterministic).
- **Fusion Algorithm**: Interval intersection is deterministic (same inputs = same output).

## Security Considerations

**Abuse Cases**:
- Compromised time source: Require at least 2 sources prevents single point of failure
- Time manipulation: Interval intersection detects disagreements (fail-closed)
- Replay attacks: Each source has its own replay protection (nonce, idempotency)

**Parsing Limits**:
- Evidence count: Max 3 evidences (hard limit, no dynamic allocation)
- Interval bounds: UInt64 range (no overflow checks needed for reasonable time values)

**Replay Protection**:
- Each source has its own replay protection (nonce for TSA/Roughtime, idempotency for OTS)
- Fused proof includes all source proofs (can verify independently)

**Key Pinning**:
- Each source has its own key pinning (TSA root CA, Roughtime public keys, OTS calendar certificate)
- No additional pinning needed at fusion layer

## Rollback Plan

1. Delete `Core/TimeAnchoring/TripleTimeAnchor.swift`
2. Delete `Core/TimeAnchoring/TripleTimeProof.swift`
3. Delete `Core/TimeAnchoring/TripleTimeAnchorError.swift`
4. Delete `Core/TimeAnchoring/TimeEvidence.swift`
5. Delete `Core/TimeAnchoring/TimeIntervalNs.swift`
6. Delete `Core/TimeAnchoring/ExcludedEvidence.swift`
7. Delete `Tests/TimeAnchoring/TripleTimeAnchorTests.swift`
8. Individual clients (TSA, Roughtime, OTS) remain functional independently

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
- [x] Interval intersection algorithm specified
