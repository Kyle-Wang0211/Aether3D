# Branch & Commit Plan for Aether3D v6.1.1

**Status**: Pre-Implementation  
**Last Updated**: 2026-02-06

---

## Branch Strategy

### Phase Branches

One branch per phase, branched from `main`:

1. `phase1/time-anchoring` - Phase 1: Time Anchoring (RFC 3161, Roughtime, OpenTimestamps, Triple Fusion)
2. `phase1_5/crash-consistency` - Phase 1.5: Crash Consistency Infrastructure (WAL)
3. `phase2/merkle-tree` - Phase 2: Merkle Audit Tree (RFC 9162)
4. `phase3/device-attestation` - Phase 3: Device Attestation (Apple App Attest)
5. `phase4/deterministic-replay` - Phase 4: Deterministic Replay Engine (DST)
6. `phase5/format-provenance` - Phase 5: Format Bridge + Provenance Bundle

### Branch Rules

- All branches start from `main` (no branch dependencies)
- One PR per branch (phase-level PRs)
- Squash merge to `main` (per project workflow)
- Delete branch after merge

---

## Commit Plan

### Phase 1: Time Anchoring

**Branch**: `phase1/time-anchoring`

#### Commit 1: P1-T01 - TSAClient
```
[PR1] feat(phase-1): implement TSAClient with full CMS verification

Implements RFC 3161 Time-Stamp Protocol client with complete CMS
signature verification, certificate chain validation, and policy OID
checking. Provides legal-grade timestamping for S5-level evidence.

Key features:
- ASN.1 DER encoding/decoding for TimeStampReq/TimeStampResp
- CMS signature verification with certificate chain validation
- Policy OID checking (Sigstore: 1.3.6.1.4.1.57264.2)
- Nonce verification for replay protection
- Message imprint verification (hash matching)

Files created:
- Core/TimeAnchoring/TSAClient.swift
- Core/TimeAnchoring/TimeStampToken.swift
- Core/TimeAnchoring/TSAError.swift
- Core/TimeAnchoring/ASN1Builder.swift
- Tests/TimeAnchoring/TSAClientTests.swift

Invariants: INV-C1 (SHA-256), INV-C2 (BE encoding), INV-A1 (actor isolation)
Intelligence-Ref: RFC-3161, RFC-5816, Sigstore-TSA
SSOT-Change: no
Breaking: no
```

#### Commit 2: P1-T02 - RoughtimeClient
```
[PR1] feat(phase-1): implement RoughtimeClient with UDP transport

Implements IETF Roughtime protocol client using UDP transport with
tagged-message format (NONC/SREP), Ed25519 signature verification,
and public key pinning with rotation support.

Key features:
- UDP socket client (NWConnection on Apple, socket on Linux)
- Tagged message parsing (NONC request, SREP response)
- Ed25519 signature verification with pinned public keys
- Key rotation support (multiple keys with validity periods)
- Exponential backoff retry on UDP timeout

Files created:
- Core/TimeAnchoring/RoughtimeClient.swift
- Core/TimeAnchoring/RoughtimeResponse.swift
- Core/TimeAnchoring/RoughtimeError.swift
- Core/TimeAnchoring/PublicKeyInfo.swift
- Tests/TimeAnchoring/RoughtimeClientTests.swift

Invariants: INV-C4 (Ed25519), INV-C2 (BE encoding), INV-A1 (actor isolation)
Intelligence-Ref: IETF-Roughtime, Cloudflare-Roughtime
SSOT-Change: no
Breaking: no
```

#### Commit 3: P1-T03 - OpenTimestampsAnchor
```
[PR1] feat(phase-1): implement OpenTimestampsAnchor with idempotent submission

Implements OpenTimestamps blockchain anchor client with idempotent
hash submission, exponential backoff upgrade polling, and deterministic
receipt handling.

Key features:
- Idempotent hash submission (local cache prevents duplicates)
- Exponential backoff upgrade polling (2s base, max 10 attempts)
- OTS proof parsing and Bitcoin block confirmation detection
- Receipt status tracking (pending → confirmed)

Files created:
- Core/TimeAnchoring/OpenTimestampsAnchor.swift
- Core/TimeAnchoring/BlockchainReceipt.swift
- Core/TimeAnchoring/BlockchainAnchorError.swift
- Tests/TimeAnchoring/OpenTimestampsAnchorTests.swift

Invariants: INV-C1 (SHA-256), INV-A1 (actor isolation)
Intelligence-Ref: OpenTimestamps-Protocol
SSOT-Change: no
Breaking: no
```

#### Commit 4: P1-T04 - TripleTimeAnchor
```
[PR1] feat(phase-1): implement TripleTimeAnchor with interval intersection fusion

Implements triple time anchor fusion using interval intersection algorithm,
requiring at least 2 independently verified sources with non-empty
intersection. Output fused time interval [lowerNs, upperNs].

Key features:
- Parallel requests to all three sources (async let)
- Individual verification (CMS for TSA, Ed25519 for Roughtime, OTS for blockchain)
- Interval conversion (point estimates → intervals with uncertainty)
- Interval intersection computation (fused interval = intersection of all intervals)
- Fail-closed if < 2 sources or intersection empty

Files created:
- Core/TimeAnchoring/TripleTimeAnchor.swift
- Core/TimeAnchoring/TripleTimeProof.swift
- Core/TimeAnchoring/TripleTimeAnchorError.swift
- Core/TimeAnchoring/TimeEvidence.swift
- Core/TimeAnchoring/TimeIntervalNs.swift
- Core/TimeAnchoring/ExcludedEvidence.swift
- Tests/TimeAnchoring/TripleTimeAnchorTests.swift

Invariants: INV-C1 (SHA-256), INV-C2 (BE encoding), INV-A1 (actor isolation), INV-A4 (no ordering assumptions)
Intelligence-Ref: eIDAS-2.0, GB/T-43580-2023
SSOT-Change: no
Breaking: no
```

### Phase 1.5: Crash Consistency

**Branch**: `phase1_5/crash-consistency`

#### Commit 5: P1.5-T01 - Write-Ahead Log
```
[PR1.5] feat(phase-1.5): implement Write-Ahead Log for crash consistency

Implements Write-Ahead Log (WAL) for atomic dual-write to SignedAuditLog
and MerkleTree, with crash recovery and iOS durability level support
(or SQLite transactional storage alternative).

Key features:
- WAL file format with binary encoding (Big-Endian)
- Group commit/batch fsync for performance
- iOS DataProtection durability levels (DataProtectionComplete, etc.)
- SQLite WAL mode alternative (transactional storage)
- Crash recovery with WAL replay and SignedAuditLog verification

Files created:
- Core/TimeAnchoring/WriteAheadLog.swift
- Core/TimeAnchoring/WALEntry.swift
- Core/TimeAnchoring/DurabilityLevel.swift
- Core/TimeAnchoring/WALError.swift
- Core/TimeAnchoring/WALStorage.swift
- Core/TimeAnchoring/FileWALStorage.swift
- Core/TimeAnchoring/SQLiteWALStorage.swift
- Tests/TimeAnchoring/WriteAheadLogTests.swift

Invariants: INV-C2 (BE encoding), INV-A1 (actor isolation)
Intelligence-Ref: ADR-009 (WAL vs SQLite decision)
SSOT-Change: no
Breaking: no
```

### Phase 2: Merkle Tree

**Branch**: `phase2/merkle-tree`

#### Commit 6: P2-T01 - RFC 9162 MTH Primitives
```
[PR2] feat(phase-2): implement RFC 9162 Merkle Tree Hash primitives

Implements RFC 9162 Merkle Tree Hash (MTH) primitives with correct
empty tree handling (MTH(empty) = HASH() of empty string), domain
separation (0x00=leaf, 0x01=node), and separation from tile-based
storage concerns.

Key features:
- Leaf hashing: SHA256(0x00 || leaf_bytes)
- Node hashing: SHA256(0x01 || left_hash || right_hash)
- Empty tree: SHA256("") (no prefix, e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855)
- Domain separation constants (0x00, 0x01)

Files created:
- Core/MerkleTree/MerkleTreeHash.swift
- Core/MerkleTree/MerkleTreeError.swift
- Tests/MerkleTree/MerkleTreeHashTests.swift

Invariants: INV-C1 (SHA-256), INV-C6 (RFC 9162 domain separation)
Intelligence-Ref: RFC-9162, Sigstore-Rekor-v2
SSOT-Change: no
Breaking: no
```

#### Commit 7: P2-T02 - Merkle Tree Storage Layer
```
[PR2] feat(phase-2): implement Merkle tree with tile-based storage layer

Implements RFC 9162 Merkle tree with tile-based architecture, TileStore
integration for persistence, inclusion proof generation, and consistency
proof generation (using checkpoints or tile history).

Key features:
- Tile-based architecture (256-entry tiles)
- TileStore protocol abstraction (InMemoryTileStore, FileTileStore)
- Inclusion proof generation (O(log n))
- Consistency proof generation (requires historical state)
- Empty tree handling (root = MTH(empty))

Files created:
- Core/MerkleTree/MerkleTree.swift
- Core/MerkleTree/TileAddress.swift
- Core/MerkleTree/TileStore.swift
- Core/MerkleTree/InMemoryTileStore.swift
- Core/MerkleTree/FileTileStore.swift
- Core/MerkleTree/InclusionProof.swift
- Core/MerkleTree/ConsistencyProof.swift
- Tests/MerkleTree/MerkleTreeTests.swift
- Tests/MerkleTree/InclusionProofTests.swift
- Tests/MerkleTree/ConsistencyProofTests.swift

Invariants: INV-C1 (SHA-256), INV-C6 (RFC 9162), INV-C2 (BE encoding), INV-A1 (actor isolation)
Intelligence-Ref: RFC-9162, Sigstore-Rekor-v2
SSOT-Change: no
Breaking: no
```

#### Commit 8: P2-T03 - Signed Tree Head
```
[PR2] feat(phase-2): implement Signed Tree Head with exact signing format

Implements Signed Tree Head (STH) with exact signing input format
(48 bytes: [8 bytes BE treeSize][8 bytes BE timestampNanos][32 bytes rootHash]),
Ed25519 signature, logId derivation (SHA256 of public key), and logParamsHash.

Key features:
- Exact signing input format (48 bytes total)
- Ed25519 signature over signing input
- logId = SHA256(Ed25519 public key raw bytes)
- logParamsHash = SHA256("SHA256:Ed25519:0x00:0x01")
- Signature verification

Files created:
- Core/MerkleTree/SignedTreeHead.swift
- Tests/MerkleTree/SignedTreeHeadTests.swift

Invariants: INV-C1 (SHA-256), INV-C4 (Ed25519), INV-C2 (BE encoding)
Intelligence-Ref: RFC-9162-Section-4.3
SSOT-Change: no
Breaking: no
```

#### Commit 9: P2-T04 - MerkleAuditLog Integration
```
[PR2] feat(phase-2): integrate MerkleAuditLog with WAL

Integrates MerkleAuditLog with SignedAuditLog using WAL for atomic
dual-write, generates inclusion proofs for audit entries, and timestamps
STH with TripleTimeAnchor.

Key features:
- Atomic dual-write via WAL (SignedAuditLog + MerkleTree)
- Entry hash computation (SHA256 of canonical JSON)
- Inclusion proof generation for audit entries
- STH generation with TripleTimeAnchor timestamping
- Crash recovery with WAL replay

Files created:
- Core/MerkleTree/MerkleAuditLog.swift
- Core/MerkleTree/MerkleAuditLogError.swift
- Tests/MerkleTree/MerkleAuditLogTests.swift

Files modified:
- Core/Audit/SignedAuditLog.swift (may need to expose entry hash method)

Invariants: INV-C1 (SHA-256), INV-C6 (RFC 9162), INV-A1 (actor isolation)
Intelligence-Ref: RFC-9162, WAL-Integration
SSOT-Change: no
Breaking: no
```

### Phase 3: Device Attestation

**Branch**: `phase3/device-attestation`

#### Commit 10: P3-T01 - AppAttestClient
```
[PR3] feat(phase-3): implement AppAttestClient with protocol abstraction

Implements Apple App Attest client using DeviceCheck.DCAppAttestService
with protocol abstraction for testability, input validation (32-byte
clientDataHash), and graceful degradation on unsupported platforms.

Key features:
- Protocol abstraction (DCAppAttestServiceProtocol)
- Key generation in Secure Enclave (P-256)
- Key attestation with Apple servers
- Assertion generation for authenticated requests
- Graceful degradation (iOS < 14.0, macOS < 11.0)

Files created:
- Core/DeviceAttestation/AppAttestClient.swift
- Core/DeviceAttestation/AppAttestError.swift
- Core/DeviceAttestation/DCAppAttestServiceProtocol.swift
- Core/DeviceAttestation/DCAppAttestServiceWrapper.swift
- Tests/DeviceAttestation/AppAttestClientTests.swift

Invariants: INV-C1 (SHA-256), INV-A1 (actor isolation)
Intelligence-Ref: Apple-App-Attest, WWDC-2025
SSOT-Change: no
Breaking: no
```

#### Commit 11: P3-T02 - AttestationVerifier
```
[PR3] feat(phase-3): implement AttestationVerifier with persistent counter store

Implements server-side verification of App Attest attestation objects
(CBOR parsing, certificate chain verification, signature verification)
with persistent counter tracking for replay protection.

Key features:
- CBOR attestation object parsing
- Certificate chain verification (Apple root CA)
- Signature verification
- Counter validation (strictly increasing, rollback detection)
- Persistent counter storage (SQLiteCounterStore or InMemoryCounterStore)

Files created:
- Core/DeviceAttestation/AttestationVerifier.swift
- Core/DeviceAttestation/AttestationResult.swift
- Core/DeviceAttestation/AttestationVerifierError.swift
- Core/DeviceAttestation/CounterStore.swift
- Core/DeviceAttestation/InMemoryCounterStore.swift
- Core/DeviceAttestation/SQLiteCounterStore.swift
- Tests/DeviceAttestation/AttestationVerifierTests.swift
- Tests/DeviceAttestation/CounterStoreTests.swift

Invariants: INV-C4 (Ed25519/ECDSA), INV-A1 (actor isolation)
Intelligence-Ref: Apple-App-Attest-Verification
SSOT-Change: no
Breaking: no
```

### Phase 4: Deterministic Replay

**Branch**: `phase4/deterministic-replay`

#### Commit 12: P4-T01 - DeterministicScheduler
```
[PR4] feat(phase-4): implement DeterministicScheduler with SplitMix64 PRNG

Implements Deterministic Simulation Testing (DST) scheduler with
SplitMix64 PRNG for cross-platform deterministic randomness, deterministic
task ordering, and Swift 6.2 strict concurrency compliance.

Key features:
- SplitMix64 PRNG with explicit overflow handling
- Deterministic task ordering (scheduledTime, taskId)
- Virtual time advancement
- Deterministic random number generation
- Swift 6.2 actor isolation (no @unchecked Sendable)

Files created:
- Core/Replay/DeterministicScheduler.swift
- Core/Replay/SplitMix64.swift
- Core/Replay/TaskHandle.swift
- Core/Replay/DeterministicSchedulerError.swift
- Tests/Replay/DeterministicSchedulerTests.swift

Invariants: INV-D8 (seeded PRNG), INV-A1 (actor isolation), INV-A2 (Swift Concurrency)
Intelligence-Ref: Antithesis-105M, FoundationDB-DST, TigerBeetle-DST
SSOT-Change: no
Breaking: no
```

#### Commit 13: P4-T02 - Async TimeSource Migration
```
[PR4] feat(phase-4): migrate TimeSource protocol to async

Migrates TimeSource protocol to async, implements MockTimeSource
compatible with DeterministicScheduler, and ensures Swift 6.2 strict
concurrency compliance without @unchecked Sendable unless explicitly
justified.

Key features:
- Async TimeSource protocol (nowMs() async -> Int64)
- MockTimeSource wraps DeterministicScheduler (deterministic time)
- SystemTimeSource uses MonotonicClock (production time)
- Swift 6.2 actor isolation compliance

Files created:
- Core/Replay/TimeSource.swift
- Core/Replay/MockTimeSource.swift
- Core/Replay/SystemTimeSource.swift
- Core/Replay/TimeSourceError.swift
- Tests/Replay/MockTimeSourceTests.swift

Files modified:
- Core/Infrastructure/TimeProvider.swift (if TimeSource protocol exists, migrate to async)

Invariants: INV-D1 (no Date()), INV-A1 (actor isolation), INV-A2 (Swift Concurrency)
Intelligence-Ref: Swift-6.2-Strict-Concurrency
SSOT-Change: no
Breaking: yes (TimeSource protocol change, but migration is incremental)
```

#### Commit 14: P4-T03 - FaultInjector
```
[PR4] feat(phase-4): implement FaultInjector with deterministic faults

Implements fault injection for chaos testing in DST using seeded PRNG
for deterministic fault generation. Supports network partition, disk
error injection, and clock skew.

Key features:
- Network partition injection (symmetric partitions)
- Disk error probability (PRNG-based, deterministic)
- Clock skew injection (deterministic offset)
- Deterministic faults (same seed = same faults)

Files created:
- Core/Replay/FaultInjector.swift
- Core/Replay/FaultInjectorError.swift
- Tests/Replay/FaultInjectorTests.swift

Invariants: INV-D8 (seeded PRNG), INV-A1 (actor isolation)
Intelligence-Ref: Antithesis-DST, Jepsen-Chaos-Testing
SSOT-Change: no
Breaking: no
```

### Phase 5: Format Bridge

**Branch**: `phase5/format-provenance`

#### Commit 15: P5-T01 - ProvenanceBundle Schema
```
[PR5] feat(phase-5): define ProvenanceBundle schema with canonical JSON

Defines canonical ProvenanceBundle schema (RFC 8785 JCS) with Merkle
proof, STH, time anchors, and device attestation status. Schema must
be deterministically serializable for S5 reproducibility.

Key features:
- RFC 8785 JCS canonicalization (sorted keys, deterministic formatting)
- Fixed field ordering (manifest, sth, timeProof, merkleProof, deviceAttestation)
- Hex encoding for binary fields (lowercase)
- ISO 8601 UTC timestamps
- Bundle hash computation (SHA256 of canonical JSON)

Files created:
- Core/FormatBridge/ProvenanceBundle.swift
- Core/FormatBridge/ProvenanceManifest.swift
- Core/FormatBridge/ExportFormat.swift
- Core/FormatBridge/DeviceAttestationStatus.swift
- Core/FormatBridge/ProvenanceBundleError.swift
- Tests/FormatBridge/ProvenanceBundleTests.swift

Invariants: INV-C1 (SHA-256), INV-C2 (BE encoding), INV-D5 (deterministic JSON)
Intelligence-Ref: RFC-8785-JCS
SSOT-Change: no
Breaking: no
```

#### Commit 16: P5-T02 - GLTFExporter
```
[PR5] feat(phase-5): implement GLTFExporter with ProvenanceBundle embedding

Implements glTF 2.0 exporter with KHR_mesh_quantization extension and
embedded ProvenanceBundle in GLB metadata. Export must be deterministic
and pass gltf-validator.

Key features:
- GLB binary format generation
- KHR_mesh_quantization extension support
- ProvenanceBundle embedding in GLB metadata
- Deterministic JSON (RFC 8785 JCS)
- Deterministic binary chunk ordering

Files created:
- Core/FormatBridge/GLTFExporter.swift
- Core/FormatBridge/GLTFExportOptions.swift
- Core/FormatBridge/GLTFExporterError.swift
- Tests/FormatBridge/GLTFExporterTests.swift

Invariants: INV-C2 (BE encoding), INV-D5 (deterministic JSON)
Intelligence-Ref: Khronos-glTF-2.0, KHR-mesh-quantization
SSOT-Change: no
Breaking: no
```

#### Commit 17: P5-T03 - Validation Harness
```
[PR5] feat(phase-5): integrate format validation harness in CI

Integrates external format validators (gltf-validator, usd-checker,
3d-tiles-validator, e57validator) in CI. Fails build if validation fails.
Supports macOS and Linux CI.

Key features:
- External validator integration (Docker containers)
- GLB validation (gltf-validator)
- USD validation (usd-checker)
- 3D Tiles validation (3d-tiles-validator)
- E57 validation (e57validator)
- CI failure on validation errors

Files created:
- Core/FormatBridge/FormatValidator.swift
- Core/FormatBridge/ValidationResult.swift
- Core/FormatBridge/FormatValidatorError.swift
- Tests/FormatBridge/FormatValidatorTests.swift

Files modified:
- .github/workflows/ci.yml (add validation steps)

Invariants: None (validation is external)
Intelligence-Ref: gltf-validator, usd-checker, 3d-tiles-validator, e57validator
SSOT-Change: yes (CI workflow changes)
Breaking: no
```

---

## Gating Checklists

### Phase 1: Time Anchoring

**Before merging `phase1/time-anchoring`**:

- [ ] **Protocol Correctness**:
  - [ ] RFC 3161 CMS signature verification implemented (not just messageImprint check)
  - [ ] Certificate chain validation against TSA root CA
  - [ ] Policy OID checking
  - [ ] Nonce verification
  - [ ] Roughtime UDP transport (not HTTPS)
  - [ ] Tagged message format (NONC/SREP)
  - [ ] Public key pinning with rotation support
  - [ ] OpenTimestamps idempotent submission
  - [ ] TripleTimeAnchor interval intersection fusion (not point comparison)

- [ ] **Fail-Closed Behavior**:
  - [ ] All error cases throw explicit errors (no silent failures)
  - [ ] Hash length validation (32 bytes, fail-closed)
  - [ ] Signature verification failures throw errors
  - [ ] Interval intersection empty throws error
  - [ ] < 2 sources throws error

- [ ] **Parsing Limits**:
  - [ ] ASN.1 nested depth limit (max 10 levels)
  - [ ] Certificate chain length limit (max 10 certificates)
  - [ ] DER encoding size limit (max 64KB)
  - [ ] UDP packet size limit (max 512 bytes)
  - [ ] Reject indefinite length ASN.1
  - [ ] Reject trailing bytes in ASN.1

- [ ] **Determinism Tests**:
  - [ ] Same hash produces identical TimeStampReq DER on macOS and Linux
  - [ ] Same seed produces identical Roughtime nonce sequence
  - [ ] Same evidences produce identical fused interval
  - [ ] Golden fixtures with SHA256 hashes

- [ ] **Swift 6.2 Concurrency**:
  - [ ] All actors use proper isolation (no @unchecked Sendable unless justified)
  - [ ] No data races detected by Swift 6.2 compiler
  - [ ] Async/await used correctly (no blocking calls)

---

### Phase 1.5: Crash Consistency

**Before merging `phase1_5/crash-consistency`**:

- [ ] **Protocol Correctness**:
  - [ ] WAL file format specified (exact byte format)
  - [ ] Group commit/batch fsync implemented
  - [ ] iOS durability levels supported (or SQLite alternative)
  - [ ] Crash recovery implemented (WAL replay)

- [ ] **Fail-Closed Behavior**:
  - [ ] WAL corruption detection throws error
  - [ ] SignedAuditLog mismatch throws error (fail-closed)
  - [ ] Uncommitted entries not replayed

- [ ] **Parsing Limits**:
  - [ ] WAL entry size limit (max 1MB)
  - [ ] Entry ID range (UInt64, no overflow)

- [ ] **Determinism Tests**:
  - [ ] WAL file format identical on macOS and Linux
  - [ ] Recovery produces identical MerkleTree state

- [ ] **Swift 6.2 Concurrency**:
  - [ ] WriteAheadLog actor isolation correct
  - [ ] WALStorage protocol async methods

---

### Phase 2: Merkle Tree

**Before merging `phase2/merkle-tree`**:

- [ ] **Protocol Correctness**:
  - [ ] RFC 9162 MTH primitives (0x00=leaf, 0x01=node)
  - [ ] Empty tree: MTH(empty) = SHA256("") (not prefixed hash)
  - [ ] Tile-based architecture (256-entry tiles)
  - [ ] STH signing input: exact 48-byte format
  - [ ] logId = SHA256(publicKey)
  - [ ] logParamsHash = SHA256("SHA256:Ed25519:0x00:0x01")

- [ ] **Fail-Closed Behavior**:
  - [ ] Invalid leaf index throws error
  - [ ] Invalid tree size throws error
  - [ ] Proof verification failures throw errors
  - [ ] Tile size > 256 throws error

- [ ] **Parsing Limits**:
  - [ ] Tree size limit (UInt64 max, theoretical)
  - [ ] Tile size limit (256 entries, fixed)
  - [ ] Proof path length limit (max 64 entries)

- [ ] **Determinism Tests**:
  - [ ] Same leaf sequence produces identical root hash
  - [ ] Same tree state produces identical proofs
  - [ ] Tile serialization identical on macOS and Linux
  - [ ] Golden fixtures with SHA256 hashes

- [ ] **Swift 6.2 Concurrency**:
  - [ ] MerkleTree actor isolation correct
  - [ ] TileStore protocol async methods

---

### Phase 3: Device Attestation

**Before merging `phase3/device-attestation`**:

- [ ] **Protocol Correctness**:
  - [ ] CBOR attestation object parsing
  - [ ] Certificate chain verification (Apple root CA)
  - [ ] Signature verification
  - [ ] Counter validation (strictly increasing)

- [ ] **Fail-Closed Behavior**:
  - [ ] Invalid clientDataHash throws error (not 32 bytes)
  - [ ] Counter rollback throws error
  - [ ] Key not registered throws error
  - [ ] Platform not supported throws error (graceful degradation)

- [ ] **Parsing Limits**:
  - [ ] Attestation object size limit (max 8KB)
  - [ ] Certificate chain length limit (max 10 certificates)
  - [ ] CBOR nested depth limit (max 10 levels)

- [ ] **Determinism Tests**:
  - [ ] CBOR parsing identical on macOS and Linux
  - [ ] Counter validation deterministic

- [ ] **Swift 6.2 Concurrency**:
  - [ ] AppAttestClient actor isolation correct
  - [ ] CounterStore protocol async methods

---

### Phase 4: Deterministic Replay

**Before merging `phase4/deterministic-replay`**:

- [ ] **Protocol Correctness**:
  - [ ] SplitMix64 PRNG algorithm (explicit overflow handling)
  - [ ] Deterministic task ordering (scheduledTime, taskId)
  - [ ] Async TimeSource protocol
  - [ ] Deterministic fault injection (PRNG-based)

- [ ] **Fail-Closed Behavior**:
  - [ ] Invalid seed remapped (0 → 1)
  - [ ] Invalid probability clamped [0.0, 1.0]

- [ ] **Parsing Limits**:
  - [ ] Seed range (UInt64, 0 remapped to 1)
  - [ ] Task count (UInt64 max, theoretical)

- [ ] **Determinism Tests**:
  - [ ] Same seed produces identical execution trace on macOS and Linux
  - [ ] Same seed produces identical PRNG sequence
  - [ ] Same seed produces identical faults
  - [ ] Golden fixtures with execution traces

- [ ] **Swift 6.2 Concurrency**:
  - [ ] DeterministicScheduler actor isolation correct
  - [ ] MockTimeSource uses async TimeSource (no @unchecked Sendable unless justified in ADR)
  - [ ] No data races detected

---

### Phase 5: Format Bridge

**Before merging `phase5/format-provenance`**:

- [ ] **Protocol Correctness**:
  - [ ] RFC 8785 JCS canonicalization (sorted keys)
  - [ ] Fixed field ordering (deterministic hashing)
  - [ ] Hex encoding (lowercase)
  - [ ] ISO 8601 UTC timestamps
  - [ ] GLB format validation (gltf-validator)

- [ ] **Fail-Closed Behavior**:
  - [ ] Invalid mesh data throws error
  - [ ] Validation failures fail build
  - [ ] Missing required fields throws error

- [ ] **Parsing Limits**:
  - [ ] Bundle size limit (max 1MB)
  - [ ] GLB size limit (max 100MB)
  - [ ] Mesh vertex count limit (max 10M vertices)

- [ ] **Determinism Tests**:
  - [ ] Same inputs produce identical ProvenanceBundle JSON
  - [ ] Same inputs produce identical GLB bytes
  - [ ] Golden fixtures with SHA256 hashes

- [ ] **Swift 6.2 Concurrency**:
  - [ ] FormatValidator uses async where needed
  - [ ] No data races detected

---

## Final Verification

**Before merging any phase branch**:

- [ ] All tests pass on macOS
- [ ] All tests pass on Linux
- [ ] No Swift 6.2 concurrency warnings
- [ ] No @unchecked Sendable unless justified in ADR
- [ ] Golden fixtures committed with SHA256 hashes
- [ ] Documentation updated (if needed)
- [ ] Rollback plan documented

---

**Implementation Not Started: Verified**

**Checklist**:
- [x] No Swift code implementations included
- [x] No test code included
- [x] Only commit messages and checklists provided
- [x] All phases covered
- [x] Gating checklists complete
