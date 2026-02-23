# P1-T01: TSAClient (RFC 3161) with Full CMS Verification

**Phase**: 1 - Time Anchoring  
**Dependencies**: None  
**Estimated Duration**: 3-4 days

## Goal

Implement RFC 3161 Time-Stamp Protocol client with complete CMS (Cryptographic Message Syntax) signature verification, certificate chain validation, and policy OID checking. Provide legal-grade timestamping for S5-level evidence.

## Non-Goals

- Implementing ASN.1 DER parser from scratch (use established library or minimal RFC 3161 subset parser)
- Supporting multiple TSA servers simultaneously (single server per client instance)
- Certificate revocation checking (OCSP/CRL) in initial version
- TSA key rotation handling (assume stable TSA certificate)

## Inputs / Outputs

**Inputs**:
- SHA-256 hash: 32 bytes (fixed length, fail-closed if not 32 bytes)
- TSA server URL: HTTPS endpoint (e.g., timestamp.sigstore.dev)
- Timeout: TimeInterval (default 30 seconds)

**Outputs**:
- TimeStampToken: Verified token with genTime, messageImprint, serialNumber, policyOID, nonce, certificate chain, verification status
- Verification result: Boolean (true if all verification steps pass)

## Public Interfaces

**TSAClient** (actor):
- `init(serverURL: URL, timeout: TimeInterval)`
- `requestTimestamp(hash: Data) async throws -> TimeStampToken`
- `verifyTimestamp(_ token: TimeStampToken, hash: Data) async throws -> Bool`

**TimeStampToken** (struct, Codable, Sendable):
- `genTime: Date`
- `messageImprint: MessageImprint`
- `serialNumber: Data`
- `tsaName: String?`
- `policyOID: String`
- `nonce: Data?`
- `derEncoded: Data`
- `certificateChain: [Data]`
- `verificationStatus: VerificationStatus`
- `verify(hash: Data) -> Bool`

**MessageImprint** (struct, Codable, Sendable):
- `algorithmOID: String`
- `digest: Data`
- `matches(hash: Data) -> Bool`

**VerificationStatus** (enum, Codable, Sendable):
- `verified`
- `unverified`
- `failed`

**TSAError** (enum, Error, Sendable):
- `invalidHashLength(expected: Int, actual: Int)`
- `httpError(statusCode: Int, responseBody: Data?)`
- `tsaRejected(status: Int, statusString: String?)`
- `invalidResponse(reason: String)`
- `verificationFailed(reason: String)`
- `timeout`
- `asn1Error(reason: String)`
- `certificateChainInvalid(reason: String)`
- `policyOIDMismatch(expected: String, actual: String)`
- `nonceMismatch`
- `signatureInvalid`

## Acceptance Criteria

1. **Hash Validation**: Input hash must be exactly 32 bytes. If not, throw `TSAError.invalidHashLength`.
2. **ASN.1 DER Encoding**: TimeStampReq must be correctly DER-encoded with version=1, MessageImprint (algorithm OID + hash), nonce (random 64-bit integer), certReq=true.
3. **HTTP Request**: POST to serverURL with Content-Type: application/timestamp-query, body=DER-encoded TimeStampReq, timeout=30s.
4. **ASN.1 DER Parsing**: Parse TimeStampResp, extract TimeStampToken (CMS structure), TSTInfo (genTime, serialNumber, policyOID, nonce, messageImprint).
5. **CMS Signature Verification**: Parse CMS SignedData structure, extract certificate chain, verify signature using TSA public key from certificate.
6. **Certificate Chain Validation**: Verify certificate chain against TSA root CA (Sigstore TSA: sigstore-timestamp-root.pem). Check certificate validity period, signature chain.
7. **Policy OID Check**: Verify policy OID matches expected value (Sigstore: 1.3.6.1.4.1.57264.2). If mismatch, throw `TSAError.policyOIDMismatch`.
8. **Nonce Verification**: Verify nonce in response matches nonce in request. If mismatch, throw `TSAError.nonceMismatch`.
9. **Message Imprint Verification**: Verify messageImprint.digest == input hash. If mismatch, throw `TSAError.verificationFailed("messageImprint mismatch")`.
10. **GenTime Validation**: Verify genTime is within acceptable window (not more than 1 hour in future, not more than 1 year in past).
11. **Cross-Platform**: Same hash produces identical TimeStampReq DER encoding on macOS and Linux (deterministic nonce generation for tests only).
12. **Error Handling**: All failure modes throw explicit errors (no silent failures).

## Failure Modes & Error Taxonomy

**Network Errors**:
- `TSAError.timeout`: HTTP request exceeds timeout (30s)
- `TSAError.httpError`: HTTP status code != 200

**Protocol Errors**:
- `TSAError.invalidHashLength`: Input hash not 32 bytes
- `TSAError.invalidResponse`: Malformed TimeStampResp (invalid ASN.1 structure)
- `TSAError.asn1Error`: ASN.1 parsing error (invalid tag, length overflow, indefinite length, trailing bytes, nested depth > 10)

**Verification Errors**:
- `TSAError.verificationFailed`: Generic verification failure (with reason string)
- `TSAError.certificateChainInvalid`: Certificate chain verification failed
- `TSAError.signatureInvalid`: CMS signature verification failed
- `TSAError.policyOIDMismatch`: Policy OID doesn't match expected value
- `TSAError.nonceMismatch`: Nonce in response doesn't match request

**TSA Rejection**:
- `TSAError.tsaRejected`: TSA rejected request (status field in response)

## Determinism & Cross-Platform Notes

- **ASN.1 DER Encoding**: Must be deterministic (same input = same output). Nonce generation: use seeded PRNG in tests, secure random in production.
- **Certificate Chain Parsing**: ASN.1 DER parsing must produce identical results on macOS and Linux (use established library or verify byte-for-byte compatibility).
- **Time Validation**: Use UTC timestamps, handle timezone differences deterministically.
- **Error Messages**: Error reason strings must be deterministic (no timestamps or random values in error messages).

## Security Considerations

**Abuse Cases**:
- Malicious TSA server: Pin TSA root CA, verify certificate chain strictly
- Replay attacks: Nonce verification prevents replay
- Man-in-the-middle: HTTPS with certificate pinning
- DoS via large requests: Limit request size (TimeStampReq < 1KB)

**Parsing Limits**:
- ASN.1 nested depth: Max 10 levels (reject deeper nesting)
- Certificate chain length: Max 10 certificates (reject longer chains)
- DER encoding length: Max 64KB (reject larger encodings)
- Indefinite length: Reject (fail-closed)
- Trailing bytes: Reject (fail-closed)

**Replay Protection**:
- Nonce in request must match nonce in response
- Nonce must be cryptographically random (not predictable)

**Key Pinning**:
- Pin TSA root CA certificate (Sigstore TSA: sigstore-timestamp-root.pem)
- Certificate chain must chain to pinned root
- No key rotation support in initial version (assume stable TSA certificate)

## Rollback Plan

1. Delete `Core/TimeAnchoring/TSAClient.swift`
2. Delete `Core/TimeAnchoring/TimeStampToken.swift`
3. Delete `Core/TimeAnchoring/TSAError.swift`
4. Delete `Core/TimeAnchoring/ASN1Builder.swift` (if created)
5. Delete `Tests/TimeAnchoring/TSAClientTests.swift`
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
