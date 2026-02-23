# P1-T02: RoughtimeClient (IETF Roughtime UDP) with Tagged Messages

**Phase**: 1 - Time Anchoring  
**Dependencies**: None  
**Estimated Duration**: 2-3 days

## Goal

Implement IETF Roughtime protocol client using UDP transport with tagged-message format (NONC/SREP), Ed25519 signature verification, and public key pinning with rotation support.

## Non-Goals

- Implementing Roughtime server (client only)
- Supporting multiple Roughtime servers simultaneously (single server per client instance)
- Implementing Roughtime chain verification (single server response only)

## Inputs / Outputs

**Inputs**:
- Server host: String (e.g., "roughtime.cloudflare.com")
- Server port: UInt16 (default: 2003)
- Server public keys: Array of PublicKeyInfo (for rotation support)
- Timeout: TimeInterval (default: 5 seconds)

**Outputs**:
- RoughtimeResponse: Verified response with midpoint time, radius, signature, server public key ID, verification status

## Public Interfaces

**RoughtimeClient** (actor):
- `init(serverHost: String, serverPort: UInt16, serverPublicKeys: [PublicKeyInfo], timeout: TimeInterval)`
- `requestTime() async throws -> RoughtimeResponse`

**PublicKeyInfo** (struct, Codable, Sendable):
- `keyId: String`
- `publicKey: Data` (32 bytes, Ed25519)
- `validFrom: Date`
- `validUntil: Date?`

**RoughtimeResponse** (struct, Codable, Sendable):
- `midpointTimeNs: UInt64`
- `radiusNs: UInt32`
- `nonce: Data` (32 bytes)
- `signature: Data` (64 bytes, Ed25519)
- `serverPublicKeyId: String`
- `verificationStatus: VerificationStatus`
- `timeInterval: (lower: UInt64, upper: UInt64)`

**RoughtimeError** (enum, Error, Sendable):
- `invalidPublicKey`
- `signatureVerificationFailed`
- `invalidResponse(reason: String)`
- `networkError(underlying: Error)`
- `timeout`
- `radiusTooLarge(radius: UInt32)`
- `unknownKeyId(keyId: String)`
- `keyExpired(keyId: String)`

## Acceptance Criteria

1. **UDP Socket**: Create UDP socket connection to serverHost:serverPort using NWConnection (Apple) or socket() (Linux).
2. **Request Packet**: Generate 32-byte random nonce, construct NONC tagged message per IETF Roughtime spec, send UDP packet.
3. **Response Packet**: Receive UDP packet, parse SREP tagged message, extract midpoint time (8 bytes BE), radius (4 bytes BE), nonce (32 bytes), signature (64 bytes Ed25519).
4. **Key Selection**: Match response keyId to serverPublicKeys array, select valid key (validFrom <= now <= validUntil).
5. **Signature Verification**: Verify Ed25519 signature over response message using selected public key. If verification fails, throw `RoughtimeError.signatureVerificationFailed`.
6. **Nonce Verification**: Verify nonce in response matches nonce in request. If mismatch, throw `RoughtimeError.invalidResponse("nonce mismatch")`.
7. **Radius Validation**: Verify radius <= 1 second (1_000_000_000 nanoseconds). If larger, throw `RoughtimeError.radiusTooLarge`.
8. **Time Interval**: Compute time interval as [midpointTimeNs - radiusNs, midpointTimeNs + radiusNs].
9. **Packet Loss Handling**: Retry on UDP timeout with exponential backoff (1s, 2s, 4s), max 3 retries.
10. **Key Rotation**: Support multiple public keys with validity periods. During grace period, accept responses signed with either old or new key.
11. **Cross-Platform**: UDP socket implementation works on both macOS (NWConnection) and Linux (socket/recvfrom/sendto).
12. **Determinism**: Nonce generation uses secure random in production, seeded PRNG in tests (for deterministic test fixtures).

## Failure Modes & Error Taxonomy

**Network Errors**:
- `RoughtimeError.timeout`: UDP request exceeds timeout (5s) after max retries
- `RoughtimeError.networkError`: UDP socket error (underlying error wrapped)

**Protocol Errors**:
- `RoughtimeError.invalidResponse`: Malformed SREP message (invalid tag, wrong packet size, invalid structure)
- `RoughtimeError.signatureVerificationFailed`: Ed25519 signature verification failed
- `RoughtimeError.unknownKeyId`: Response keyId not found in serverPublicKeys array
- `RoughtimeError.keyExpired`: Selected key is expired (validUntil < now)

**Validation Errors**:
- `RoughtimeError.radiusTooLarge`: Radius exceeds 1 second threshold
- `RoughtimeError.invalidPublicKey`: Public key format invalid (not 32 bytes)

## Determinism & Cross-Platform Notes

- **UDP Socket**: Use platform-specific APIs (NWConnection on Apple, socket/recvfrom/sendto on Linux). Abstract behind protocol for testability.
- **Nonce Generation**: Use secure random in production (non-deterministic), seeded PRNG in tests (deterministic for fixtures).
- **Packet Format**: Tagged messages (NONC/SREP) must be parsed identically on macOS and Linux (byte-for-byte compatibility).
- **Time Handling**: All timestamps in nanoseconds since Unix epoch, Big-Endian encoding in packets.

## Security Considerations

**Abuse Cases**:
- Malicious Roughtime server: Public key pinning prevents MITM attacks
- Replay attacks: Nonce verification prevents replay
- DoS via packet flood: Rate limiting (1 request/second per client)
- Key compromise: Key rotation with grace period allows migration

**Parsing Limits**:
- UDP packet size: Max 512 bytes (reject larger packets per IETF Roughtime spec)
- Tagged message depth: Max 2 levels (NONC/SREP only, reject deeper nesting)
- Nonce length: Exactly 32 bytes (reject other lengths)
- Signature length: Exactly 64 bytes Ed25519 (reject other lengths)

**Replay Protection**:
- Nonce in request must match nonce in response
- Nonce must be cryptographically random (not predictable)

**Key Pinning & Rotation**:
- Pin server public keys in PublicKeyInfo array
- Support key rotation: multiple keys with validity periods
- Grace period: During transition, accept responses signed with either old or new key
- Key expiration: Reject responses signed with expired keys
- Key ID: Each key has unique keyId for identification

**Key Rotation Policy**:
- New key validFrom: Set to rotation start time
- Old key validUntil: Set to rotation end time (grace period)
- Grace period: 7 days (configurable)
- After grace period: Only new key accepted

## Rollback Plan

1. Delete `Core/TimeAnchoring/RoughtimeClient.swift`
2. Delete `Core/TimeAnchoring/RoughtimeResponse.swift`
3. Delete `Core/TimeAnchoring/RoughtimeError.swift`
4. Delete `Core/TimeAnchoring/PublicKeyInfo.swift`
5. Delete `Tests/TimeAnchoring/RoughtimeClientTests.swift`
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
- [x] Key rotation policy specified
