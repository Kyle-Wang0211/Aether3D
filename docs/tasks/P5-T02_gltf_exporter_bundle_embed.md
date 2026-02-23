# P5-T02: GLTFExporter with ProvenanceBundle Embedding

**Phase**: 5 - Format Bridge + Provenance Bundle  
**Dependencies**: P5-T01 (ProvenanceBundle), P2-T04 (MerkleAuditLog), P1-T04 (TripleTimeAnchor)  
**Estimated Duration**: 3-4 days

## Goal

Implement glTF 2.0 exporter with KHR_mesh_quantization extension and embedded ProvenanceBundle in GLB metadata. Export must be deterministic and pass gltf-validator.

## Non-Goals

- Implementing full glTF 2.0 spec (minimal implementation for Aether3D use case)
- Supporting all glTF extensions (KHR_mesh_quantization only)
- Implementing glTF import (export only)

## Inputs / Outputs

**Inputs**:
- Mesh data: AetherMesh structure (vertices, indices, normals, textures)
- Evidence state: EvidenceState for provenance
- Options: GLTFExportOptions (quantization, Draco compression, texture embedding)

**Outputs**:
- GLB binary: Binary glTF format with embedded ProvenanceBundle

## Public Interfaces

**GLTFExporter** (struct):
- `init()`
- `export(mesh: AetherMesh, evidence: EvidenceState, merkleProof: InclusionProof, sth: SignedTreeHead, timeProof: TripleTimeProof, options: GLTFExportOptions) throws -> Data`

**GLTFExportOptions** (struct):
- `enableQuantization: Bool` (KHR_mesh_quantization)
- `enableDraco: Bool` (KHR_draco_mesh_compression)
- `embedTextures: Bool`
- `quantizationBits: Int` (position/texcoord quantization bits)

**GLTFExporterError** (enum, Error, Sendable):
- `invalidMeshData(reason: String)`
- `encodingFailed(reason: String)`
- `validationFailed(reason: String)`
- `provenanceBundleError(underlying: Error)`

## Acceptance Criteria

1. **GLB Format**: Generate valid GLB binary format (12-byte header + JSON chunk + binary chunk).
2. **Mesh Export**: Export mesh data (vertices, indices, normals) to GLB binary chunk.
3. **Quantization Extension**: Add KHR_mesh_quantization extension if enabled. Quantize positions/texcoords to specified bit depth.
4. **ProvenanceBundle Embedding**: Embed ProvenanceBundle in GLB JSON metadata ("extras" field or custom extension).
5. **Deterministic JSON**: GLB JSON chunk uses RFC 8785 JCS (sorted keys, deterministic formatting).
6. **Deterministic Binary**: Binary chunk ordering is deterministic (same mesh = same GLB bytes).
7. **Validation**: Generated GLB passes gltf-validator (external validator, fail build if validation fails).
8. **Cross-Platform**: Same inputs produce identical GLB bytes on macOS and Linux (deterministic encoding).

## Failure Modes & Error Taxonomy

**Validation Errors**:
- `GLTFExporterError.invalidMeshData`: Mesh data invalid (missing vertices, invalid indices)
- `GLTFExporterError.validationFailed`: GLB validation failed (gltf-validator reported errors)

**Encoding Errors**:
- `GLTFExporterError.encodingFailed`: GLB encoding failed (underlying error wrapped)
- `GLTFExporterError.provenanceBundleError`: ProvenanceBundle encoding failed (underlying error wrapped)

## Determinism & Cross-Platform Notes

- **JSON Canonicalization**: RFC 8785 JCS ensures deterministic JSON (sorted keys, deterministic number formatting).
- **Binary Chunk Ordering**: Fixed ordering of binary data (deterministic).
- **Quantization**: Deterministic quantization (same input = same quantized output).

## Security Considerations

**Abuse Cases**:
- Malformed mesh data: Validation detects invalid mesh data (fail-closed)
- GLB tampering: ProvenanceBundle hash verification detects tampering

**Parsing Limits**:
- GLB size: Max 100MB (reject larger GLBs)
- Mesh vertex count: Max 10M vertices (reject larger meshes)
- Texture size: Max 16MB per texture (reject larger textures)

**Replay Protection**:
- ProvenanceBundle timestamp prevents replay (old exports have old timestamps)

**Key Pinning**:
- Not applicable (no keys in GLB export)

## Rollback Plan

1. Delete `Core/FormatBridge/GLTFExporter.swift`
2. Delete `Core/FormatBridge/GLTFExportOptions.swift`
3. Delete `Core/FormatBridge/GLTFExporterError.swift`
4. Delete `Tests/FormatBridge/GLTFExporterTests.swift`
5. No database schema changes
6. No impact on existing code

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
