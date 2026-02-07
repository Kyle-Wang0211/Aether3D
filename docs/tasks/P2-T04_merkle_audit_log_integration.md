# P2-T04: MerkleAuditLog Integration with WAL

**Phase**: 2 - Merkle Audit Tree  
**Dependencies**: P2-T02 (MerkleTree), P2-T03 (SignedTreeHead), P1.5-T01 (WAL), P1-T04 (TripleTimeAnchor)  
**Estimated Duration**: 3-4 days

## Goal

Integrate MerkleAuditLog with SignedAuditLog using WAL for atomic dual-write, generate inclusion proofs for audit entries, and timestamp STH with TripleTimeAnchor.

## Non-Goals

- Modifying existing SignedAuditLog implementation (wrap it, don't modify)
- Implementing full transparency log monitoring (local log only)
- Supporting multiple Merkle trees simultaneously (single tree per log)

## Inputs / Outputs

**Inputs**:
- SignedAuditEntry: Existing audit entry structure
- Private key: Curve25519.Signing.PrivateKey (for STH signing)

**Outputs**:
- Entry appended to both SignedAuditLog and MerkleTree (atomically via WAL)
- Inclusion proof: InclusionProof for appended entry
- Signed Tree Head: STH with TripleTimeAnchor timestamp

## Public Interfaces

**MerkleAuditLog** (actor):
- `init(signedAuditLog: SignedAuditLog, merkleTree: MerkleTree, wal: WriteAheadLog, tripleTimeAnchor: TripleTimeAnchor)`
- `append(_ entry: SignedAuditEntry) async throws -> EntryId`
- `generateInclusionProof(entryIndex: UInt64) async throws -> InclusionProof`
- `getSignedTreeHead(privateKey: Curve25519.Signing.PrivateKey) async throws -> SignedTreeHead`
- `size: UInt64` (async property)
- `rootHash: Data` (async property)

**EntryId** (typealias): UInt64

**MerkleAuditLogError** (enum, Error, Sendable):
- `walWriteFailed(underlying: Error)`
- `signedLogAppendFailed(underlying: Error)`
- `merkleTreeAppendFailed(underlying: Error)`
- `recoveryFailed(reason: String)`
- `invalidEntryIndex(index: UInt64, treeSize: UInt64)`

## Acceptance Criteria

1. **WAL Entry Writing**: Write entry to WAL: entry hash (32 bytes), signed entry bytes (JSON), Merkle tree state (incremental update or full state).
2. **Dual-Write Atomicity**: Append to SignedAuditLog, then append to MerkleTree. If either fails, rollback WAL entry (mark as uncommitted).
3. **WAL Commit**: After both writes succeed, mark WAL entry as committed, fsync WAL.
4. **Entry Hash Computation**: Compute entry hash = SHA256(canonical JSON of SignedAuditEntry). Use existing SignedAuditEntry.hashPayload if available.
5. **Inclusion Proof Generation**: Generate inclusion proof for entry at given index. Proof verifies entry exists in Merkle tree.
6. **STH Generation**: Generate STH with current tree size, root hash, timestamp (MonotonicClock.nowNs()), sign with private key.
7. **STH Timestamping**: Timestamp STH with TripleTimeAnchor (optional, for legal validity). Store TripleTimeProof alongside STH.
8. **Crash Recovery**: On startup, recover MerkleTree from WAL entries. Verify SignedAuditLog matches WAL entries. If mismatch, throw error (fail-closed).
9. **Entry Index Mapping**: Map SignedAuditLog entry index to MerkleTree leaf index (1:1 mapping, both start at 0).
10. **Cross-Platform**: WAL format and Merkle tree state serialization identical on macOS and Linux.
11. **Determinism**: Same entry sequence produces identical Merkle tree root and proofs (deterministic).

## Failure Modes & Error Taxonomy

**WAL Errors**:
- `MerkleAuditLogError.walWriteFailed`: WAL write failed (underlying error wrapped)

**Dual-Write Errors**:
- `MerkleAuditLogError.signedLogAppendFailed`: SignedAuditLog append failed (rollback WAL entry)
- `MerkleAuditLogError.merkleTreeAppendFailed`: MerkleTree append failed (rollback WAL entry)

**Recovery Errors**:
- `MerkleAuditLogError.recoveryFailed`: Recovery process failed (SignedAuditLog mismatch, WAL corruption)

**Validation Errors**:
- `MerkleAuditLogError.invalidEntryIndex`: Entry index >= tree size

## Determinism & Cross-Platform Notes

- **WAL Format**: Binary format with Big-Endian encoding (cross-platform compatibility).
- **Entry Hash**: SHA256 of canonical JSON is deterministic (same entry = same hash).
- **Merkle Tree**: Deterministic tree construction (same entries = same root hash).

## Security Considerations

**Abuse Cases**:
- WAL tampering: WAL corruption detection prevents replay of invalid entries
- Entry tampering: Entry hash verification detects tampered entries
- Crash during dual-write: WAL recovery ensures atomicity (either both succeed or both fail)

**Parsing Limits**:
- Entry size: Max 1MB per entry (reject larger entries)
- Tree size: UInt64 max (2^64 entries, theoretical limit)

**Replay Protection**:
- Entry hash: Unique per entry (prevents duplicate entries)
- Merkle tree: Append-only (prevents entry deletion/modification)

**Key Pinning**:
- STH signing key: logId pins signer public key (logId = SHA256(publicKey))
- Key rotation: New key produces new logId (old STHs remain valid)

## Rollback Plan

1. Delete `Core/MerkleTree/MerkleAuditLog.swift`
2. Delete `Tests/MerkleTree/MerkleAuditLogTests.swift`
3. Revert WAL integration (if WAL was created for this purpose only)
4. Existing SignedAuditLog remains functional (no modifications made)

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
- [x] WAL integration specified
