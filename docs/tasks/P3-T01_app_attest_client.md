# P3-T01: AppAttestClient with Protocol Abstraction

**Phase**: 3 - Device Attestation  
**Dependencies**: None  
**Estimated Duration**: 2-3 days

## Goal

Implement Apple App Attest client using DeviceCheck.DCAppAttestService with protocol abstraction for testability, input validation (32-byte clientDataHash), and graceful degradation on unsupported platforms.

## Non-Goals

- Implementing server-side verification (handled in P3-T02)
- Supporting Android Play Integrity (Apple platforms only)
- Implementing key rotation (single key per app instance)

## Inputs / Outputs

**Inputs**:
- clientDataHash: 32 bytes (SHA-256, fail-closed if not 32 bytes)
- Key ID: String (for assertion generation)

**Outputs**:
- Key ID: String (for attestation)
- Attestation object: Data (CBOR format)
- Assertion: Data (CBOR format)

## Public Interfaces

**AppAttestClient** (actor):
- `init(service: DCAppAttestServiceProtocol)`
- `isSupported: Bool`
- `generateKey() async throws -> String`
- `attestKey(keyId: String, clientDataHash: Data) async throws -> Data`
- `generateAssertion(keyId: String, clientDataHash: Data) async throws -> Data`

**DCAppAttestServiceProtocol** (protocol):
- `var isSupported: Bool`
- `func generateKey(completionHandler: @escaping (String?, Error?) -> Void)`
- `func attestKey(_ keyId: String, clientDataHash: Data, completionHandler: @escaping (Data?, Error?) -> Void)`
- `func generateAssertion(_ keyId: String, clientDataHash: Data, completionHandler: @escaping (Data?, Error?) -> Void)`

**DCAppAttestServiceWrapper** (struct, DCAppAttestServiceProtocol):
- `init(service: DCAppAttestService)`

**AppAttestError** (enum, Error, Sendable):
- `notSupported`
- `keyGeneration(Error)`
- `attestation(Error)`
- `assertion(Error)`
- `invalidClientDataHash`
- `unknownError`

## Acceptance Criteria

1. **Platform Support Check**: Check isSupported property. If false, throw `AppAttestError.notSupported` (graceful degradation).
2. **Hash Validation**: clientDataHash must be exactly 32 bytes. If not, throw `AppAttestError.invalidClientDataHash`.
3. **Key Generation**: Generate key in Secure Enclave (P-256). Return keyId string.
4. **Key Attestation**: Attest key with Apple servers. Return attestation object (CBOR format).
5. **Assertion Generation**: Generate assertion for authenticated requests. Return assertion (CBOR format).
6. **Protocol Abstraction**: Use DCAppAttestServiceProtocol for testability. Real implementation wraps DCAppAttestService, mock implementation for tests.
7. **Error Handling**: Wrap all DCAppAttestService errors in AppAttestError enum (keyGeneration, attestation, assertion).
8. **Cross-Platform**: Graceful degradation on unsupported platforms (iOS < 14.0, macOS < 11.0). Return notSupported error.
9. **Determinism**: Key generation and attestation are non-deterministic (hardware-backed, expected behavior). Assertion generation is deterministic for same inputs (if keyId and clientDataHash are same).

## Failure Modes & Error Taxonomy

**Platform Errors**:
- `AppAttestError.notSupported`: Platform doesn't support App Attest (iOS < 14.0, macOS < 11.0)

**Validation Errors**:
- `AppAttestError.invalidClientDataHash`: clientDataHash not 32 bytes

**Service Errors**:
- `AppAttestError.keyGeneration`: Key generation failed (underlying error wrapped)
- `AppAttestError.attestation`: Attestation failed (underlying error wrapped)
- `AppAttestError.assertion`: Assertion generation failed (underlying error wrapped)
- `AppAttestError.unknownError`: Unknown error (should not occur)

## Determinism & Cross-Platform Notes

- **Platform Support**: iOS 14.0+, macOS 11.0+ only. Graceful degradation on older platforms.
- **Key Generation**: Non-deterministic (hardware-backed Secure Enclave).
- **Attestation**: Non-deterministic (Apple server response).
- **Assertion**: Deterministic for same keyId and clientDataHash (if implementation is deterministic).

## Security Considerations

**Abuse Cases**:
- Key compromise: Secure Enclave protects keys (hardware-backed security)
- Replay attacks: clientDataHash includes nonce and timestamp (replay protection)
- Device emulation: App Attest detects emulated devices (riskMetric indicates risk)

**Parsing Limits**:
- clientDataHash: Exactly 32 bytes (fail-closed if not)
- Attestation object: Max 8KB (reject larger objects)
- Assertion: Max 2KB (reject larger assertions)

**Replay Protection**:
- clientDataHash: Must include nonce and timestamp (prevents replay)
- Counter: Assertion includes counter (monotonic, handled in P3-T02)

**Key Pinning**:
- Not applicable (App Attest uses Apple's certificate chain)

## Rollback Plan

1. Delete `Core/DeviceAttestation/AppAttestClient.swift`
2. Delete `Core/DeviceAttestation/AppAttestError.swift`
3. Delete `Core/DeviceAttestation/DCAppAttestServiceProtocol.swift`
4. Delete `Core/DeviceAttestation/DCAppAttestServiceWrapper.swift`
5. Delete `Tests/DeviceAttestation/AppAttestClientTests.swift`
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
- [x] Protocol abstraction specified
