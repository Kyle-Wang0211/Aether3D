# P1.5-T01: Write-Ahead Log (WAL) for Crash Consistency

**Phase**: 1.5 - Crash Consistency Infrastructure  
**Dependencies**: None (foundation for Phase 2)  
**Estimated Duration**: 3-5 days

## Goal

Implement Write-Ahead Log (WAL) for atomic dual-write to SignedAuditLog and MerkleTree, with crash recovery and iOS durability level support (or SQLite transactional storage alternative).

## Non-Goals

- Implementing full database transaction system (WAL only, not ACID database)
- Supporting multiple concurrent writers (single writer per WAL file)
- Implementing WAL checkpoint/truncation (future work)

## Inputs / Outputs

**Inputs**:
- Entry hash: 32 bytes (SHA-256)
- Signed audit entry bytes: Variable length (JSON-encoded)
- Merkle tree state: Variable length (serialized tree state or incremental update)

**Outputs**:
- WAL entry written and committed (fsync'd)
- Recovery result: Rebuilt MerkleTree state from WAL entries

## Public Interfaces

**WriteAheadLog** (actor):
- `init(walFileURL: URL, durabilityLevel: DurabilityLevel)`
- `appendEntry(hash: Data, signedEntryBytes: Data, merkleState: Data) async throws`
- `commitEntry(_ entryId: EntryId) async throws`
- `recover() async throws -> [WALEntry]`
- `getUncommittedEntries() async throws -> [WALEntry]`

**WALEntry** (struct, Codable, Sendable):
- `entryId: EntryId`
- `hash: Data` (32 bytes)
- `signedEntryBytes: Data`
- `merkleState: Data`
- `committed: Bool`
- `timestamp: Date`

**EntryId** (typealias): UInt64

**DurabilityLevel** (enum, Codable, Sendable):
- `dataProtectionComplete` (iOS: DataProtectionComplete, Linux: fsync)
- `dataProtectionCompleteUnlessOpen` (iOS: DataProtectionCompleteUnlessOpen, Linux: fsync)
- `dataProtectionCompleteUntilFirstUserAuthentication` (iOS: DataProtectionCompleteUntilFirstUserAuthentication, Linux: fsync)
- `transactional` (SQLite WAL mode, cross-platform)

**WALError** (enum, Error, Sendable):
- `ioError(underlying: Error)`
- `corruptedEntry(entryId: EntryId, reason: String)`
- `recoveryFailed(reason: String)`
- `durabilityLevelNotSupported(level: DurabilityLevel)`
- `entryNotFound(entryId: EntryId)`

**WALStorage** (protocol):
- `writeEntry(_ entry: WALEntry) async throws`
- `readEntries() async throws -> [WALEntry]`
- `fsync() async throws`
- `close() async throws`

**FileWALStorage** (struct, WALStorage):
- `init(fileURL: URL, durabilityLevel: DurabilityLevel)`

**SQLiteWALStorage** (struct, WALStorage):
- `init(databaseURL: URL)`

## Acceptance Criteria

1. **WAL File Format**: Binary format: [8 bytes entryId BE][1 byte committed][8 bytes timestamp BE][4 bytes hash length BE][hash bytes][4 bytes signedEntry length BE][signedEntry bytes][4 bytes merkleState length BE][merkleState bytes].
2. **Entry Writing**: Write entry to WAL file, do NOT fsync yet (performance optimization).
3. **Group Commit**: Support batch fsync (group commit) for multiple entries. Flush all pending entries to disk atomically.
4. **Durability Levels**: Support iOS DataProtection durability levels (DataProtectionComplete, etc.) and Linux fsync. If level not supported, throw `WALError.durabilityLevelNotSupported`.
5. **Commit Marking**: Mark entry as committed (set committed byte = 1) after dual-write succeeds. Fsync committed entries.
6. **Crash Recovery**: On startup, read all WAL entries, replay committed entries to rebuild MerkleTree, verify SignedAuditLog matches WAL entries.
7. **Uncommitted Entries**: Detect uncommitted entries (committed = 0), do not replay them (they were not applied to SignedAuditLog).
8. **Corruption Detection**: Detect corrupted WAL entries (invalid length, checksum mismatch). If corruption detected, throw `WALError.corruptedEntry`.
9. **Mismatch Detection**: If SignedAuditLog doesn't match WAL entries, throw `WALError.recoveryFailed("SignedAuditLog mismatch")`.
10. **SQLite Alternative**: If durability level is `transactional`, use SQLite WAL mode for atomic writes. SQLiteWALStorage implements WALStorage protocol.
11. **Cross-Platform**: WAL file format is identical on macOS and Linux (byte-for-byte compatibility).
12. **Determinism**: WAL entry serialization is deterministic (same inputs = same WAL file bytes).

## Failure Modes & Error Taxonomy

**I/O Errors**:
- `WALError.ioError`: File I/O error (underlying error wrapped)
- `WALError.durabilityLevelNotSupported`: Requested durability level not supported on platform

**Recovery Errors**:
- `WALError.corruptedEntry`: WAL entry is corrupted (invalid format, checksum mismatch)
- `WALError.recoveryFailed`: Recovery process failed (SignedAuditLog mismatch, unrecoverable corruption)
- `WALError.entryNotFound`: Entry ID not found in WAL (should not occur in normal operation)

## Determinism & Cross-Platform Notes

- **WAL File Format**: Binary format with Big-Endian encoding for all numeric fields (cross-platform compatibility).
- **Durability Levels**: iOS-specific levels mapped to equivalent Linux behavior (DataProtectionComplete → fsync).
- **SQLite WAL**: SQLite WAL mode provides transactional guarantees cross-platform (alternative to file-based WAL).
- **Entry Serialization**: All Data fields serialized with length prefix (deterministic encoding).

## Security Considerations

**Abuse Cases**:
- WAL file tampering: Checksum verification detects tampering (fail-closed)
- Disk corruption: Corruption detection prevents replay of invalid entries
- Race conditions: Single writer per WAL file (no concurrent writes)

**Parsing Limits**:
- WAL entry size: Max 1MB per entry (reject larger entries)
- WAL file size: No hard limit (grows unbounded, requires periodic checkpoint/truncation in future)
- Entry count: No hard limit (UInt64 entryId allows 2^64 entries)

**Replay Protection**:
- Committed flag: Only replay committed entries (uncommitted entries were not applied)
- Entry ID: Monotonic counter prevents replay of old entries

**Key Pinning**:
- Not applicable (WAL is local storage, not network protocol)

## Rollback Plan

1. Delete `Core/TimeAnchoring/WriteAheadLog.swift`
2. Delete `Core/TimeAnchoring/WALEntry.swift`
3. Delete `Core/TimeAnchoring/WALError.swift`
4. Delete `Core/TimeAnchoring/WALStorage.swift`
5. Delete `Core/TimeAnchoring/FileWALStorage.swift`
6. Delete `Core/TimeAnchoring/SQLiteWALStorage.swift` (if created)
7. Delete WAL file (if persistent)
8. No impact on existing SignedAuditLog (revert to single-write model, lose atomicity guarantee)

## Open Questions

- **ADR Required**: Should we use file-based WAL with iOS durability levels, or SQLite WAL mode? Document as ADR-009.

---

**Implementation Not Started: Verified**

**Checklist**:
- [x] No Swift code implementations included
- [x] No test code included
- [x] Only interface names and signatures provided
- [x] Acceptance criteria are testable and fail-closed
- [x] Error taxonomy is complete
- [x] Security considerations addressed
- [x] Durability level alternatives documented
