# P2-T03: Signed Tree Head (STH) with Exact Signing Format

**Phase**: 2 - Merkle Audit Tree  
**Dependencies**: P2-T02 (MerkleTree), P1-T04 (TripleTimeAnchor for timestamping)  
**Estimated Duration**: 2-3 days

## Goal

Implement Signed Tree Head (STH) with exact signing input format (48 bytes: [8 bytes BE treeSize][8 bytes BE timestampNanos][32 bytes rootHash]), Ed25519 signature, logId derivation (SHA256 of public key), and logParamsHash.

## Non-Goals

- Implementing STH distribution protocol (local signing only)
- Supporting multiple signer keys simultaneously (single key per log)
- Implementing STH monitoring/auditing (external concern)

## Inputs / Outputs

**Inputs**:
- Tree size: UInt64
- Root hash: 32 bytes (SHA-256)
- Timestamp: UInt64 (nanoseconds since Unix epoch)
- Private key: Curve25519.Signing.PrivateKey (Ed25519)

**Outputs**:
- SignedTreeHead: STH with signature, logId, logParamsHash
- Verification result: Boolean

## Public Interfaces

**SignedTreeHead** (struct, Codable, Sendable):
- `treeSize: UInt64`
- `rootHash: Data` (32 bytes)
- `timestampNanos: UInt64`
- `signature: Data` (64 bytes, Ed25519)
- `logId: Data` (32 bytes, SHA256(publicKey))
- `logParamsHash: Data` (32 bytes, SHA256("SHA256:Ed25519:0x00:0x01"))
- `sign(treeSize: UInt64, rootHash: Data, timestampNanos: UInt64, privateKey: Curve25519.Signing.PrivateKey) throws -> SignedTreeHead`
- `verify(publicKey: Curve25519.Signing.PublicKey) -> Bool`

**MerkleTreeError** (enum, Error, Sendable):
- `invalidHashLength(expected: Int, actual: Int)`
- `signingFailed(reason: String)`

## Acceptance Criteria

1. **Signing Input Format**: Exact 48-byte format: [0:8] treeSize (UInt64 BE), [8:16] timestampNanos (UInt64 BE), [16:48] rootHash (32 bytes). Total: 48 bytes.
2. **Ed25519 Signing**: Sign signing input with Ed25519 private key. Output: 64-byte signature.
3. **logId Derivation**: logId = SHA256(Ed25519 public key raw bytes). Public key extracted from private key.
4. **logParamsHash Derivation**: logParamsHash = SHA256("SHA256:Ed25519:0x00:0x01"). Fixed string, deterministic.
5. **Signature Verification**: Verify signature using Ed25519 public key. Reconstruct signing input, verify signature matches.
6. **Hash Validation**: Root hash must be exactly 32 bytes. If not, throw `MerkleTreeError.invalidHashLength`.
7. **Cross-Platform**: Signing input format identical on macOS and Linux (Big-Endian encoding).
8. **Determinism**: Same inputs produce identical STH (deterministic signing input, deterministic logId/logParamsHash).
9. **Golden Vectors**: Test with known inputs, verify signature and logId match expected values.

## Failure Modes & Error Taxonomy

**Validation Errors**:
- `MerkleTreeError.invalidHashLength`: Root hash not 32 bytes

**Signing Errors**:
- `MerkleTreeError.signingFailed`: Ed25519 signing failed (underlying error wrapped)

## Determinism & Cross-Platform Notes

- **Signing Input**: Big-Endian encoding for all numeric fields (cross-platform compatibility).
- **logId**: SHA256 of public key is deterministic (same key = same logId).
- **logParamsHash**: Fixed string hash is deterministic (platform-independent).

## Security Considerations

**Abuse Cases**:
- Signature forgery: Ed25519 provides cryptographic security (no practical forgery attacks)
- Key compromise: logId changes when key rotates (detectable)

**Parsing Limits**:
- Signing input: Exactly 48 bytes (fail-closed if not)
- Signature: Exactly 64 bytes Ed25519 (fail-closed if not)
- logId: Exactly 32 bytes SHA-256 (fail-closed if not)

**Replay Protection**:
- Timestamp in signing input prevents replay (old STHs have old timestamps)

**Key Pinning**:
- logId pins signer public key (logId = SHA256(publicKey))
- Key rotation: New key produces new logId (old STHs remain valid with old logId)

## Rollback Plan

1. Delete `Core/MerkleTree/SignedTreeHead.swift`
2. Delete `Tests/MerkleTree/SignedTreeHeadTests.swift`
3. No database schema changes
4. No impact on existing code

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
- [x] Exact signing input format specified (48 bytes)
