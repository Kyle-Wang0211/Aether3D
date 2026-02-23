# P3-T02: AttestationVerifier with Persistent Counter Store

**Phase**: 3 - Device Attestation  
**Dependencies**: P3-T01 (AppAttestClient)  
**Estimated Duration**: 3-4 days

## Goal

Implement server-side verification of App Attest attestation objects (CBOR parsing, certificate chain verification, signature verification) with persistent counter tracking for replay protection.

## Non-Goals

- Implementing CBOR parser from scratch (use established library)
- Supporting multiple counter storage backends (single storage implementation)
- Implementing certificate revocation checking (OCSP/CRL)

## Inputs / Outputs

**Inputs**:
- Attestation object: Data (CBOR format)
- clientDataHash: 32 bytes (SHA-256)
- Expected challenge: Data (for verification)

**Outputs**:
- AttestationResult: Verified result with keyId, riskMetric, counter, certificate chain
- Counter update: Persistent counter storage updated

## Public Interfaces

**AttestationVerifier** (struct):
- `init(counterStore: CounterStore)`
- `verify(attestationObject: Data, clientDataHash: Data, expectedChallenge: Data) throws -> AttestationResult`

**AttestationResult** (struct, Codable, Sendable):
- `attestationObject: Data`
- `certificateChain: [Data]`
- `keyId: String`
- `riskMetric: UInt8` (0-3)
- `counter: UInt32`
- `verificationStatus: VerificationStatus`

**CounterStore** (protocol):
- `getCounter(keyId: String) async throws -> UInt32?`
- `setCounter(keyId: String, counter: UInt32) async throws`
- `registerKey(keyId: String, deviceBinding: String, firstSeen: Date) async throws`

**InMemoryCounterStore** (actor, CounterStore):
- `init()`
- `getCounter(keyId: String) async throws -> UInt32?`
- `setCounter(keyId: String, counter: UInt32) async throws`
- `registerKey(keyId: String, deviceBinding: String, firstSeen: Date) async throws`

**SQLiteCounterStore** (actor, CounterStore):
- `init(databaseURL: URL)`
- `getCounter(keyId: String) async throws -> UInt32?`
- `setCounter(keyId: String, counter: UInt32) async throws`
- `registerKey(keyId: String, deviceBinding: String, firstSeen: Date) async throws`

**AttestationVerifierError** (enum, Error, Sendable):
- `invalidCBOR(reason: String)`
- `certificateChainInvalid(reason: String)`
- `signatureInvalid(reason: String)`
- `counterRollback(keyId: String, expected: UInt32, actual: UInt32)`
- `keyNotRegistered(keyId: String)`
- `invalidChallenge`

## Acceptance Criteria

1. **CBOR Parsing**: Parse attestation object (CBOR format). Extract keyId, riskMetric, counter, certificate chain.
2. **Certificate Chain Verification**: Verify certificate chain (Apple root CA, intermediate certificates, leaf certificate). Check validity period, signature chain.
3. **Signature Verification**: Verify signature in attestation object using certificate chain public key.
4. **Challenge Verification**: Verify clientDataHash matches expected challenge. If mismatch, throw `AttestationVerifierError.invalidChallenge`.
5. **Counter Validation**: Retrieve stored counter for keyId. Verify new counter > stored counter (strictly increasing). If rollback detected, throw `AttestationVerifierError.counterRollback`.
6. **Counter Update**: Update stored counter to new counter value. Persist to CounterStore.
7. **Key Registration**: On first attestation, register keyId with deviceBinding and firstSeen timestamp.
8. **Risk Metric Extraction**: Extract riskMetric (0-3) from attestation object. 0 = low risk, 3 = high risk.
9. **Cross-Platform**: CBOR parsing produces identical results on macOS and Linux (use established library).
10. **Determinism**: Verification is deterministic (same inputs = same verification result). Counter updates are persistent (non-deterministic storage, but deterministic validation).

## Failure Modes & Error Taxonomy

**Parsing Errors**:
- `AttestationVerifierError.invalidCBOR`: CBOR parsing failed (invalid format, missing fields)

**Verification Errors**:
- `AttestationVerifierError.certificateChainInvalid`: Certificate chain verification failed
- `AttestationVerifierError.signatureInvalid`: Signature verification failed
- `AttestationVerifierError.invalidChallenge`: clientDataHash doesn't match expected challenge

**Counter Errors**:
- `AttestationVerifierError.counterRollback`: Counter rollback detected (new counter <= stored counter)
- `AttestationVerifierError.keyNotRegistered`: KeyId not found in CounterStore (should register first)

## Determinism & Cross-Platform Notes

- **CBOR Parsing**: Use established library (SwiftCBOR or equivalent) for cross-platform compatibility.
- **Counter Storage**: Persistent storage (SQLite or in-memory for tests). Counter updates are persistent (non-deterministic, but validation is deterministic).
- **Verification**: Deterministic (same inputs = same verification result).

## Security Considerations

**Abuse Cases**:
- Replay attacks: Counter validation prevents replay (counter must be strictly increasing)
- Counter manipulation: Persistent counter storage prevents counter reset
- Key reuse: Key registration prevents keyId reuse across devices

**Parsing Limits**:
- Attestation object size: Max 8KB (reject larger objects)
- Certificate chain length: Max 10 certificates (reject longer chains)
- CBOR nested depth: Max 10 levels (reject deeper nesting)

**Replay Protection**:
- Counter: Must be strictly increasing (reject rollbacks)
- Challenge: clientDataHash must match expected challenge (prevents replay)

**Key Pinning**:
- Apple root CA: Pin Apple App Attest root CA certificate
- Certificate chain: Must chain to pinned root

## Rollback Plan

1. Delete `Core/DeviceAttestation/AttestationVerifier.swift`
2. Delete `Core/DeviceAttestation/AttestationResult.swift`
3. Delete `Core/DeviceAttestation/AttestationVerifierError.swift`
4. Delete `Core/DeviceAttestation/CounterStore.swift`
5. Delete `Core/DeviceAttestation/InMemoryCounterStore.swift`
6. Delete `Core/DeviceAttestation/SQLiteCounterStore.swift` (if created)
7. Delete counter storage database (if persistent)
8. No impact on AppAttestClient (client remains functional)

## Open Questions

- **Counter Storage Backend**: Should we use SQLite or file-based storage? Document as implementation decision (SQLite recommended for ACID guarantees).

---

**Implementation Not Started: Verified**

**Checklist**:
- [x] No Swift code implementations included
- [x] No test code included
- [x] Only interface names and signatures provided
- [x] Acceptance criteria are testable and fail-closed
- [x] Error taxonomy is complete
- [x] Security considerations addressed
- [x] Counter storage abstraction specified
