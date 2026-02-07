# P5-T01: ProvenanceBundle Schema Definition

**Phase**: 5 - Format Bridge + Provenance Bundle  
**Dependencies**: P2-T03 (SignedTreeHead), P2-T04 (MerkleAuditLog), P1-T04 (TripleTimeAnchor), P3-T02 (AttestationVerifier)  
**Estimated Duration**: 2-3 days

## Goal

Define canonical ProvenanceBundle schema (RFC 8785 JCS) with Merkle proof, STH, time anchors, and device attestation status. Schema must be deterministically serializable for S5 reproducibility.

## Non-Goals

- Implementing format exporters (handled in P5-T02)
- Implementing validation logic (schema definition only)
- Supporting multiple schema versions (v1 only)

## Inputs / Outputs

**Inputs**:
- Export artifact metadata: Format, version, exported timestamp
- Signed Tree Head: STH from MerkleAuditLog
- Triple Time Proof: TimeProof from TripleTimeAnchor
- Merkle inclusion proof: InclusionProof from MerkleTree
- Device attestation status: AttestationResult from AttestationVerifier

**Outputs**:
- ProvenanceBundle: Canonical JSON (RFC 8785 JCS) with all provenance data

## Public Interfaces

**ProvenanceBundle** (struct, Codable, Sendable):
- `manifest: ProvenanceManifest`
- `sth: SignedTreeHead`
- `timeProof: TripleTimeProof`
- `merkleProof: InclusionProof`
- `deviceAttestation: DeviceAttestationStatus?`
- `encode() throws -> Data`
- `hash() throws -> Data`

**ProvenanceManifest** (struct, Codable, Sendable):
- `format: ExportFormat`
- `version: String`
- `exportedAt: String` (ISO 8601 UTC)
- `exporterVersion: String`

**ExportFormat** (enum, Codable, Sendable):
- `gltf`
- `usd`
- `tiles3d`
- `e57`
- `gltfGaussianSplatting`

**DeviceAttestationStatus** (struct, Codable, Sendable):
- `keyId: String`
- `riskMetric: UInt8`
- `counter: UInt32`
- `status: VerificationStatus`

**ProvenanceBundleError** (enum, Error, Sendable):
- `encodingFailed(reason: String)`
- `invalidSchema`
- `missingRequiredField(field: String)`

## Acceptance Criteria

1. **Schema Definition**: Define ProvenanceBundle struct with all required fields (manifest, sth, timeProof, merkleProof, deviceAttestation optional).
2. **Canonical JSON**: Serialize using RFC 8785 JCS (sorted keys, deterministic number formatting, no whitespace).
3. **Field Ordering**: Fixed field order: manifest, sth, timeProof, merkleProof, deviceAttestation (for deterministic hashing).
4. **Hex Encoding**: All binary fields (hashes, signatures) encoded as lowercase hex strings (64 chars for 32 bytes, 128 chars for 64 bytes).
5. **ISO 8601 Timestamps**: All timestamps in ISO 8601 UTC format (e.g., "2026-02-06T12:34:56Z").
6. **Bundle Hash**: Compute SHA256(canonical JSON) for bundle verification.
7. **Cross-Platform**: Same inputs produce identical canonical JSON on macOS and Linux (deterministic serialization).
8. **Validation**: Validate all required fields present, all hex strings valid, all timestamps valid ISO 8601.

## Failure Modes & Error Taxonomy

**Encoding Errors**:
- `ProvenanceBundleError.encodingFailed`: JSON encoding failed (underlying error wrapped)

**Validation Errors**:
- `ProvenanceBundleError.invalidSchema`: Schema validation failed (missing fields, invalid format)
- `ProvenanceBundleError.missingRequiredField`: Required field missing (manifest, sth, timeProof, merkleProof)

## Determinism & Cross-Platform Notes

- **RFC 8785 JCS**: Sorted keys, deterministic number formatting (6 decimal places for floats, no scientific notation).
- **Hex Encoding**: Lowercase hex strings (deterministic).
- **Field Ordering**: Fixed order ensures deterministic hashing.

## Security Considerations

**Abuse Cases**:
- Schema tampering: Bundle hash verification detects tampering
- Missing fields: Validation ensures all required fields present

**Parsing Limits**:
- Bundle size: Max 1MB (reject larger bundles)
- Hex string length: Validate length matches expected byte count (64 chars for 32 bytes, 128 chars for 64 bytes)

**Replay Protection**:
- Timestamp in manifest prevents replay (old bundles have old timestamps)
- STH timestamp prevents replay (old STHs have old timestamps)

**Key Pinning**:
- Not applicable (bundle contains proofs, not keys)

## Rollback Plan

1. Delete `Core/FormatBridge/ProvenanceBundle.swift`
2. Delete `Core/FormatBridge/ProvenanceManifest.swift`
3. Delete `Core/FormatBridge/ProvenanceBundleError.swift`
4. No database schema changes
5. No impact on existing code

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
- [x] RFC 8785 JCS canonicalization specified
