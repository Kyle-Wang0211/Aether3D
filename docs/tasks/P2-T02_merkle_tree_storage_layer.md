# P2-T02: Merkle Tree with Tile-Based Storage Layer

**Phase**: 2 - Merkle Audit Tree  
**Dependencies**: P2-T01 (MTH primitives), P1.5-T01 (WAL)  
**Estimated Duration**: 4-5 days

## Goal

Implement RFC 9162 Merkle tree with tile-based architecture, TileStore integration for persistence, inclusion proof generation, and consistency proof generation (using checkpoints or tile history).

## Non-Goals

- Implementing tile serialization format (handled by TileStore protocol)
- Implementing full transparency log protocol (Merkle tree only, STH signing in P2-T03)
- Supporting RFC 6962 compatibility (RFC 9162 only)

## Inputs / Outputs

**Inputs**:
- Leaf data or leaf hash: Variable length Data or 32-byte hash
- Tile address: TileAddress(level, index)
- Historical tree state: For consistency proofs (checkpoints or tile history)

**Outputs**:
- Root hash: 32 bytes
- Inclusion proof: InclusionProof struct
- Consistency proof: ConsistencyProof struct
- Tree size: UInt64

## Public Interfaces

**MerkleTree** (actor):
- `init(tileStore: TileStore)`
- `append(_ leafData: Data) async throws`
- `appendHash(_ leafHash: Data) async throws`
- `generateInclusionProof(leafIndex: UInt64) async throws -> InclusionProof`
- `generateConsistencyProof(firstSize: UInt64, secondSize: UInt64) async throws -> ConsistencyProof`
- `rootHash: Data` (async property)
- `size: UInt64` (async property)

**TileAddress** (struct, Codable, Sendable, Hashable):
- `level: UInt8`
- `index: UInt64`

**TileStore** (protocol):
- `getTile(_ address: TileAddress) async throws -> Data?`
- `putTile(_ address: TileAddress, data: Data) async throws`

**InMemoryTileStore** (actor, TileStore):
- `init()`
- `getTile(_ address: TileAddress) async throws -> Data?`
- `putTile(_ address: TileAddress, data: Data) async throws`

**FileTileStore** (actor, TileStore):
- `init(baseDirectory: URL)`
- `getTile(_ address: TileAddress) async throws -> Data?`
- `putTile(_ address: TileAddress, data: Data) async throws`

**InclusionProof** (struct, Codable, Sendable):
- `treeSize: UInt64`
- `leafIndex: UInt64`
- `path: [Data]` (sibling hashes)
- `verify(leafHash: Data, rootHash: Data) -> Bool`

**ConsistencyProof** (struct, Codable, Sendable):
- `firstTreeSize: UInt64`
- `secondTreeSize: UInt64`
- `path: [Data]`
- `verify(firstRoot: Data, secondRoot: Data) -> Bool`

**MerkleTreeError** (enum, Error, Sendable):
- `invalidLeafIndex(index: UInt64, treeSize: UInt64)`
- `invalidTreeSize(first: UInt64, second: UInt64)`
- `proofVerificationFailed(reason: String)`
- `invalidHashLength(expected: Int, actual: Int)`
- `tileStoreError(underlying: Error)`

## Acceptance Criteria

1. **Leaf Appending**: Append leaf data or leaf hash to tree. Compute leaf hash using MTH(leaf), update root hash.
2. **Tile Management**: When tile fills (256 entries), compute tile root hash, persist tile to TileStore, create parent tile.
3. **Root Hash Computation**: Root hash computed from tile root hashes using MTH(node) recursively.
4. **Empty Tree**: Empty tree (size=0) has root hash = MTH(empty) = SHA256("").
5. **Inclusion Proof Generation**: Generate O(log n) inclusion proof for leaf at given index. Proof path contains sibling hashes from leaf to root.
6. **Inclusion Proof Verification**: Verify inclusion proof by recomputing root from leaf hash and proof path. Must match current root hash.
7. **Consistency Proof Generation**: Generate consistency proof between two tree sizes (firstSize <= secondSize). Requires historical state (checkpoints or tile history).
8. **Consistency Proof Verification**: Verify consistency proof by recomputing second root from first root and proof path. Must match second root hash.
9. **Tile Persistence**: Tiles persisted to TileStore when created or updated. Tiles loaded from TileStore on demand.
10. **Tile Address Calculation**: Tile address calculated from leaf index: level = log2(index / 256), index = leafIndex / (256^level).
11. **Cross-Platform**: Tile serialization format identical on macOS and Linux (Big-Endian encoding).
12. **Determinism**: Same leaf sequence produces identical root hash and proofs (deterministic tree construction).

## Failure Modes & Error Taxonomy

**Validation Errors**:
- `MerkleTreeError.invalidLeafIndex`: Leaf index >= tree size
- `MerkleTreeError.invalidTreeSize`: firstSize > secondSize or secondSize > current size
- `MerkleTreeError.invalidHashLength`: Leaf hash not 32 bytes

**Proof Errors**:
- `MerkleTreeError.proofVerificationFailed`: Proof verification failed (invalid path, wrong root)

**Storage Errors**:
- `MerkleTreeError.tileStoreError`: TileStore I/O error (underlying error wrapped)

## Determinism & Cross-Platform Notes

- **Tile Serialization**: Tile format uses Big-Endian encoding for all numeric fields (cross-platform compatibility).
- **Tree Construction**: Same leaf sequence produces identical tree structure and root hash (deterministic).
- **Proof Generation**: Same tree state produces identical proofs (deterministic).

## Security Considerations

**Abuse Cases**:
- Malformed leaf data: Leaf hashing accepts arbitrary data (no validation needed, hash handles it)
- Tile corruption: TileStore errors detected and propagated (fail-closed)
- Proof tampering: Proof verification detects tampered proofs (fail-closed)

**Parsing Limits**:
- Tree size: UInt64 max (2^64 leaves, theoretical limit)
- Tile size: 256 entries per tile (fixed, RFC 9162 standard)
- Proof path length: Max 64 entries (log2(2^64) = 64)

**Replay Protection**:
- Not applicable (Merkle tree is append-only, no replay concerns)

**Key Pinning**:
- Not applicable (no keys involved)

## Rollback Plan

1. Delete `Core/MerkleTree/MerkleTree.swift`
2. Delete `Core/MerkleTree/TileAddress.swift`
3. Delete `Core/MerkleTree/TileStore.swift`
4. Delete `Core/MerkleTree/InMemoryTileStore.swift`
5. Delete `Core/MerkleTree/FileTileStore.swift`
6. Delete `Core/MerkleTree/InclusionProof.swift`
7. Delete `Core/MerkleTree/ConsistencyProof.swift`
8. Delete tile storage files (if persistent)
9. No database schema changes

## Open Questions

- **Consistency Proof Storage**: How to store historical tree states for consistency proofs? Options: (1) Checkpoint snapshots, (2) Tile history, (3) Recompute from tiles. Document as implementation decision.

---

**Implementation Not Started: Verified**

**Checklist**:
- [x] No Swift code implementations included
- [x] No test code included
- [x] Only interface names and signatures provided
- [x] Acceptance criteria are testable and fail-closed
- [x] Error taxonomy is complete
- [x] Security considerations addressed
- [x] Tile storage abstraction specified
