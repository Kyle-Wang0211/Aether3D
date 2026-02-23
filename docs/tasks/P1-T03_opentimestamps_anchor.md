# P1-T03: OpenTimestampsAnchor with Idempotent Submission

**Phase**: 1 - Time Anchoring  
**Dependencies**: None  
**Estimated Duration**: 2-3 days

## Goal

Implement OpenTimestamps blockchain anchor client with idempotent hash submission, exponential backoff upgrade polling, and deterministic receipt handling.

## Non-Goals

- Implementing OpenTimestamps calendar server (client only)
- Bitcoin block verification (rely on calendar server for confirmation)
- Supporting multiple blockchain networks (Bitcoin only)

## Inputs / Outputs

**Inputs**:
- SHA-256 hash: 32 bytes (fixed length, fail-closed if not 32 bytes)
- Calendar server URL: HTTPS endpoint (e.g., https://a.pool.opentimestamps.org)
- Timeout: TimeInterval (default: 30 seconds)
- Max upgrade attempts: Int (default: 10)
- Upgrade backoff base: TimeInterval (default: 2.0 seconds)

**Outputs**:
- BlockchainReceipt: Receipt with hash, OTS proof, submission timestamp, status (pending/confirmed), Bitcoin block height (if confirmed), transaction ID (if confirmed)

## Public Interfaces

**OpenTimestampsAnchor** (actor):
- `init(calendarURL: URL, timeout: TimeInterval, maxUpgradeAttempts: Int, upgradeBackoffBase: TimeInterval)`
- `submitHash(_ hash: Data) async throws -> BlockchainReceipt`
- `upgradeReceipt(_ receipt: BlockchainReceipt) async throws -> BlockchainReceipt`

**BlockchainReceipt** (struct, Codable, Sendable):
- `hash: Data` (32 bytes)
- `otsProof: Data` (OpenTimestamps proof binary)
- `submittedAt: Date`
- `status: AnchorStatus`
- `bitcoinBlockHeight: UInt64?`
- `bitcoinTxId: String?`
- `verificationStatus: VerificationStatus`

**AnchorStatus** (enum, Codable, Sendable):
- `pending`
- `confirmed`
- `failed`

**BlockchainAnchorError** (enum, Error, Sendable):
- `invalidHashLength`
- `submissionFailed(reason: String)`
- `upgradeTimeout`
- `invalidReceipt(reason: String)`
- `networkError(underlying: Error)`
- `idempotencyConflict(hash: Data)`

## Acceptance Criteria

1. **Hash Validation**: Input hash must be exactly 32 bytes. If not, throw `BlockchainAnchorError.invalidHashLength`.
2. **Idempotent Submission**: Check local cache (hash → receipt mapping) before submitting. If hash already submitted, return cached receipt.
3. **Submission Request**: POST hash to calendar server `/digest` endpoint, receive OTS proof (pending status).
4. **Receipt Creation**: Create BlockchainReceipt with hash, otsProof, submittedAt (current time), status=pending.
5. **Cache Storage**: Store receipt in local cache (hash → receipt mapping) for idempotency.
6. **Upgrade Polling**: Poll calendar server for receipt upgrade with exponential backoff (base=2.0s, max attempts=10).
7. **Upgrade Detection**: Parse OTS proof, detect Bitcoin block confirmation, extract block height and transaction ID.
8. **Status Transition**: Update receipt status from pending → confirmed when Bitcoin block confirmation detected.
9. **Timeout Handling**: If upgrade not confirmed after max attempts, throw `BlockchainAnchorError.upgradeTimeout`.
10. **Error Recovery**: Handle network errors gracefully, retry with exponential backoff.
11. **Cross-Platform**: HTTP client works on both macOS and Linux (URLSession or equivalent).
12. **Determinism**: Same hash always produces same receipt (idempotency guarantee).

## Failure Modes & Error Taxonomy

**Network Errors**:
- `BlockchainAnchorError.networkError`: HTTP request failed (underlying error wrapped)
- `BlockchainAnchorError.submissionFailed`: Calendar server rejected submission (HTTP error or invalid response)
- `BlockchainAnchorError.upgradeTimeout`: Receipt not confirmed after max upgrade attempts

**Protocol Errors**:
- `BlockchainAnchorError.invalidHashLength`: Input hash not 32 bytes
- `BlockchainAnchorError.invalidReceipt`: OTS proof parsing failed or invalid format

**Idempotency Errors**:
- `BlockchainAnchorError.idempotencyConflict`: Hash already submitted but receipt mismatch (should not occur in normal operation)

## Determinism & Cross-Platform Notes

- **HTTP Client**: Use URLSession (Apple) or equivalent Linux HTTP client. Abstract behind protocol for testability.
- **Idempotency**: Same hash always returns same receipt (deterministic cache lookup).
- **Time Handling**: submittedAt uses Date() (wall-clock time, not deterministic, but acceptable for blockchain anchoring).
- **Backoff**: Exponential backoff must be deterministic in tests (use seeded PRNG for delay calculation).

## Security Considerations

**Abuse Cases**:
- Calendar server compromise: OTS proof verification prevents tampering (verify Bitcoin block inclusion)
- Replay attacks: Idempotency cache prevents duplicate submissions
- DoS via submission flood: Rate limiting (5 submissions/minute per hash)

**Parsing Limits**:
- OTS proof size: Max 64KB (reject larger proofs)
- HTTP response size: Max 1MB (reject larger responses)
- Upgrade polling duration: Max 10 minutes total (maxAttempts * maxBackoff)

**Replay Protection**:
- Idempotency cache: Same hash returns same receipt (no duplicate submissions)
- Deterministic nonce: Use hash as seed for nonce generation (if needed)

**Key Pinning**:
- Calendar server certificate: Pin HTTPS certificate (or use system trust store)
- No key rotation support (calendar server certificate assumed stable)

## Rollback Plan

1. Delete `Core/TimeAnchoring/OpenTimestampsAnchor.swift`
2. Delete `Core/TimeAnchoring/BlockchainReceipt.swift`
3. Delete `Core/TimeAnchoring/BlockchainAnchorError.swift`
4. Delete idempotency cache storage (if persistent)
5. Delete `Tests/TimeAnchoring/OpenTimestampsAnchorTests.swift`
6. No database schema changes (if cache is in-memory only)

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
- [x] Idempotency guarantee specified
