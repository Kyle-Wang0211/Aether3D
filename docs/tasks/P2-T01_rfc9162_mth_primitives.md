# P2-T01: RFC 9162 Merkle Tree Hash (MTH) Primitives

**Phase**: 2 - Merkle Audit Tree  
**Dependencies**: None  
**Estimated Duration**: 2-3 days

## Goal

Implement RFC 9162 Merkle Tree Hash (MTH) primitives with correct empty tree handling (MTH(empty) = HASH() of empty string), domain separation (0x00=leaf, 0x01=node), and separation from tile-based storage concerns.

## Non-Goals

- Implementing tile-based storage (separate concern, handled in P2-T02)
- Implementing full Merkle tree (handled in P2-T02)
- Supporting RFC 6962 compatibility (RFC 9162 only)

## Inputs / Outputs

**Inputs**:
- Leaf data: Variable length Data
- Left child hash: 32 bytes (SHA-256)
- Right child hash: 32 bytes (SHA-256)

**Outputs**:
- Leaf hash: 32 bytes (SHA-256 with 0x00 prefix)
- Node hash: 32 bytes (SHA-256 with 0x01 prefix)
- Empty tree hash: 32 bytes (SHA-256 of empty string, no prefix)

## Public Interfaces

**MerkleTreeHash** (enum, no cases, static methods only):
- `hashLeaf(_ data: Data) -> Data`
- `hashNodes(_ left: Data, _ right: Data) -> Data`
- `hashEmpty() -> Data`

**Constants**:
- `leafPrefix: UInt8 = 0x00`
- `nodePrefix: UInt8 = 0x01`

**MerkleTreeError** (enum, Error, Sendable):
- `invalidHashLength(expected: Int, actual: Int)`

## Acceptance Criteria

1. **Leaf Hashing**: MTH(leaf) = SHA256(0x00 || leaf_bytes). Input: variable length Data. Output: 32 bytes.
2. **Node Hashing**: MTH(node) = SHA256(0x01 || left_hash || right_hash). Input: two 32-byte hashes. Output: 32 bytes.
3. **Empty Tree Hashing**: MTH(empty) = SHA256("") (empty string, NO prefix). Output: 32 bytes (e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855).
4. **Hash Length Validation**: Left and right hashes must be exactly 32 bytes. If not, throw `MerkleTreeError.invalidHashLength`.
5. **Domain Separation**: Leaf hash uses 0x00 prefix, node hash uses 0x01 prefix. Empty tree uses no prefix.
6. **Cross-Platform**: Same input produces identical hash on macOS and Linux (SHA-256 is deterministic).
7. **Golden Vectors**: Test vectors match RFC 9162 test cases (if available) or Sigstore Rekor v2 test vectors.
8. **Separation from Storage**: MTH primitives are pure functions, no storage/tile concerns. Tile storage is separate layer.

## Failure Modes & Error Taxonomy

**Validation Errors**:
- `MerkleTreeError.invalidHashLength`: Input hash not 32 bytes (for hashNodes function)

## Determinism & Cross-Platform Notes

- **SHA-256**: Deterministic hash function, same input = same output on all platforms.
- **Domain Separation**: Prefix bytes (0x00, 0x01) are platform-independent.
- **Empty String Hash**: SHA256("") is well-defined and platform-independent.

## Security Considerations

**Abuse Cases**:
- Hash collision: SHA-256 provides cryptographic security (no practical collision attacks)
- Malformed input: Hash length validation prevents invalid inputs

**Parsing Limits**:
- Leaf data size: No hard limit (SHA-256 accepts arbitrary length input)
- Hash inputs: Must be exactly 32 bytes (fail-closed if not)

**Replay Protection**:
- Not applicable (MTH is pure function, no state)

**Key Pinning**:
- Not applicable (no keys involved)

## Rollback Plan

1. Delete `Core/MerkleTree/MerkleTreeHash.swift`
2. Delete `Tests/MerkleTree/MerkleTreeHashTests.swift`
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
- [x] Empty tree hash correctly specified (HASH() of empty string)
