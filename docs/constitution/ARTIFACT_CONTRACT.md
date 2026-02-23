>Status: Binding
>Version: v1.0.0
>Authority: FP1 Constitution
>Change Control: RFC Required

# Artifact Contract Specification

This document defines the **Single Source of Truth (SSOT)** for artifact package output contracts. This specification is **constitutional grade** and **sealed**—all implementations must conform exactly.

## SSOT Declaration

This document is the **only authoritative source** for:
- Artifact manifest schema (v1)
- Canonical encoding rules
- Hash computation rules
- Validation rules
- Versioning policy

No other document may override these rules without an RFC and version bump.

## Schema v1

### Top-Level Fields

The `ArtifactManifest` structure contains the following fields in **exact order**:

1. **schemaVersion** (Int, required)
   - Must be `1` for this version
   - Future versions must increment and maintain backward compatibility rules

2. **artifactId** (String, required)
   - 32 lowercase hex characters (128-bit identifier)
   - Computed from canonical bytes (see Hash Computation)
   - Stable and deterministic (no random UUID)

3. **buildMeta** (BuildMetaMap, required)
   - Type: `[String: String]`
   - **Always present** in JSON encoding, even if empty
   - Empty map encodes as `"buildMeta":{}` (never omitted)
   - Keys and values must be NFC-normalized strings without null bytes

4. **coordinateSystem** (CoordinateSystem, required)
   - See CoordinateSystem specification below

5. **lods** (Array<LODDescriptor>, required)
   - Must contain at least one LOD
   - Sorted by `lodId` (UTF-8 lexicographic) in canonical encoding

6. **files** (Array<FileDescriptor>, required)
   - Must contain at least one file
   - Sorted by `path` (UTF-8 lexicographic) in canonical encoding
   - Paths must be unique case-insensitively

7. **fallbacks** (Fallbacks?, optional)
   - If `nil`: **OMIT key entirely** from JSON
   - If present with all fields `nil`: encode as `"fallbacks":{}`
   - If present with some fields: encode **ONLY present fields**, no null keys
   - **FORBIDDEN**: Encoding `"thumbnail": null` or `"previewVideo": null`

8. **policyHash** (String, required)
   - 64 lowercase hex characters (SHA256 format)
   - Represents the policy hash that governed artifact generation

9. **artifactHash** (String, required)
   - 64 lowercase hex characters (SHA256 format)
   - Computed from canonical bytes (see Hash Computation)
   - **NOT included** in canonical bytes for hashing

### CoordinateSystem

- **upAxis** (String, required)
  - Allowed values: `"X"`, `"-X"`, `"Y"`, `"-Y"`, `"Z"`, `"-Z"`
  - Must be NFC-normalized, no null bytes

- **unitScale** (Double, required)
  - Must be finite (`isFinite == true`)
  - Must NOT be NaN
  - Must NOT be ±Infinity
  - Must be strictly positive: `unitScale > 0`
  - Range: `0.001 <= unitScale <= 1000.0`
  - Encoded as fixed-point decimal (see Encoding Rules)

### LODDescriptor

- **lodId** (String, required)
  - ASCII format recommended (e.g., "lod0", "lod1")
  - Must be NFC-normalized, no null bytes

- **qualityTier** (String, required)
  - Allowed values: `"low"`, `"medium"`, `"high"`

- **approxSplatCount** (Int, required)
  - Must be `> 0`

- **entryFile** (String, required)
  - Must exist in `files[]` array
  - Must be NFC-normalized, no null bytes

### FileDescriptor

- **path** (String, required)
  - ASCII-only: bytes in `0x20...0x7E`
  - Must match regex: `^[A-Za-z0-9._/-]+$`
  - Must NOT contain: `..`, leading `/`, `\`, `//`, trailing `/`
  - Max length: 512 bytes
  - Must be NFC-normalized, no null bytes

- **sha256** (String, required)
  - 64 lowercase hex characters (no prefix)
  - SHA256 hash of file contents

- **bytes** (Int, required)
  - Range: `1 ... 5_000_000_000` (5GB max)

- **contentType** (String, required)
  - Whitelist: `application/octet-stream`, `application/x-aether-splat`, `application/x-aether-ply`, `model/gltf-binary`, `image/png`, `image/jpeg`, `video/mp4`
  - No `;` allowed (avoid charset parameters)

- **role** (String, required)
  - Whitelist: `lod_entry`, `asset`, `thumbnail`, `preview_video`, `metadata`

### Fallbacks

- **thumbnail** (String?, optional)
  - If present, must exist in `files[]` with `role == "thumbnail"`

- **previewVideo** (String?, optional)
  - If present, must exist in `files[]` with `role == "preview_video"`

## Canonical Encoding Law

### Forbidden Encoders

**FORBIDDEN** in canonical hashing path:
- `JSONEncoder`
- `JSONSerialization`
- Pretty-printed / whitespace formatting
- Locale-sensitive formatting
- `String(format:)`
- `NumberFormatter`

### Canonical JSON Encoding Rules

Canonical UTF-8 JSON bytes must have:
- **No whitespace** between tokens
- **Object keys strictly sorted** per rules below
- **Arrays sorted** per rules below
- **Strings JSON-escaped deterministically**:
  - Escape `"` and `\`
  - Escape control chars as `\u00XX` (pure Swift hex, no String(format:))
- **Optional fields**: If `nil`, omit key entirely (top-level `fallbacks` only)
- **Required fields**: Always present (even if empty objects like `buildMeta:{}`)

### Key Ordering Rules

**Top-level keys** (explicit order for v1):
1. `schemaVersion`
2. `artifactId`
3. `buildMeta`
4. `coordinateSystem`
5. `lods`
6. `files`
7. `fallbacks` (only if not nil)
8. `policyHash`
9. `artifactHash` (NOT in canonical bytes for hashing)

**Nested object keys**: Sort by Unicode scalar lexicographic:
- `a.unicodeScalars.lexicographicallyPrecedes(b.unicodeScalars)`

**Array elements**: Sort deterministically:
- `files[]`: Sort by `path` (UTF-8 lexicographic)
- `lods[]`: Sort by `lodId` (UTF-8 lexicographic)

### unitScale Fixed-Point Encoding

**SEALED RULE**: unitScale MUST be encoded using fixed-point Int64 (1e9) + pure Swift decimal string builder.

**FORBIDDEN**: `String(format:)`, `NumberFormatter`, any locale-sensitive formatting.

**Algorithm**:
1. Multiply by `1_000_000_000` (9 decimal digits)
2. Round to nearest `Int64`
3. Convert to string with manual integer/fraction formatting:
   - `intPart = scaled / 1_000_000_000`
   - `fracPart = abs(scaled % 1_000_000_000)`
   - Format `fracPart` as 9 digits with leading zeros
   - Trim trailing zeros in fractional part
   - If fractional becomes empty → emit integer part only
4. **No exponent notation ever**

Examples: `"1"`, `"1.25"`, `"0.001"`

## Hash Coverage & Immutability

### Domain Separation Prefix

**SEALED**: Domain separation prefix for artifact hashing:
- Prefix bytes: ASCII `"aether.artifact.manifest.v1\0"` (including trailing null byte `0x00`)
- Used for both `artifactId` and `artifactHash` computation

### artifactHash Computation

1. Compute canonical bytes (see Canonical Encoding Law)
   - Includes: `schemaVersion`, `artifactId`, `buildMeta`, `coordinateSystem`, `lods` (sorted), `files` (sorted), `fallbacks?`, `policyHash`
   - **EXCLUDES**: `artifactHash` itself

2. Prepend domain separation prefix

3. Compute SHA256 hash

4. Convert to 64 lowercase hex characters

### artifactId Computation

1. Compute temporary canonical bytes **WITHOUT** `artifactId`:
   - Includes: `schemaVersion`, `buildMeta`, `coordinateSystem`, `lods` (sorted), `files` (sorted), `fallbacks?`, `policyHash`
   - **EXCLUDES**: `artifactId`, `artifactHash`

2. Prepend domain separation prefix

3. Compute SHA256 hash

4. Take first 32 hex characters (128-bit identifier)

5. Include computed `artifactId` in final canonical bytes for `artifactHash` computation

### Hash Immutability

- `artifactHash` covers canonical manifest bytes excluding `artifactHash` itself
- `files[].sha256` are inputs to manifest, but `artifactHash` covers manifest's declared hashes (not file bytes)
- Changing any field (except `artifactHash`) must change `artifactHash`
- Domain separation prefix prevents accidental hash collisions with other hash domains

## buildMeta Encoding Rule

**SEALED**: `buildMeta` key MUST always be present in JSON encoding.

- Empty map: Encodes as `"buildMeta":{}` (never omitted)
- Enforcement: In `encode(to:)`, always encode `buildMeta` even if empty

## fallbacks Encoding Rule (GATE #10)

**SEALED**: Canonical encoding for `fallbacks` is LOCKED:

1. **fallbacks == nil**
   - MUST OMIT `"fallbacks"` key entirely

2. **fallbacks != nil AND all nested fields are nil**
   - MUST encode as: `"fallbacks": {}`

3. **fallbacks != nil AND some nested fields exist**
   - MUST encode ONLY present fields
   - MUST NOT encode any null-valued keys

**FORBIDDEN**:
- Encoding `"thumbnail": null`
- Encoding `"previewVideo": null`
- Any behavior that produces both `{}` and `{"x":null}` for the same semantic content

## Unknown Field Rejection

**SEALED**: All Codable structs MUST reject unknown keys.

**Strategy**: Use `DynamicCodingKey` + `allKeys` allowlist diff pattern.

**Applied to**: `ArtifactManifest`, `CoordinateSystem`, `LODDescriptor`, `FileDescriptor`, `Fallbacks`

**Implementation**:
1. Decode container with `DynamicCodingKey`
2. Get `allKeys` from container
3. Compare with known keys from `CodingKeys.allCases`
4. If unknown keys exist → throw `ArtifactError.unknownFields(keys: [...])`

## String Validation Rules

**Global string invariants** (applies to ALL String fields):
- MUST NOT contain null byte `\u{0000}`
- MUST be NFC normalized:
  - Require `s == s.precomposedStringWithCanonicalMapping`
  - If not, throw `ArtifactError.stringNotNFC(field:)`

**Enforcement location**:
- For Codable types: validate inside `init(from decoder:)` immediately after decoding
- For programmatic init: validate in `init` before storing

## Path Validation Rules

**SEALED**: Path rules (ASCII-only):

- ASCII only: bytes in `0x20...0x7E` (no control chars)
- Must match regex: `^[A-Za-z0-9._/-]+$`
- Must NOT contain:
  - `..`
  - Leading `/`
  - `\`
  - `//` (double slash)
- Must NOT end with `/`
- Max length: 512 bytes

**Rationale**:
- Cross-filesystem stability
- Deterministic sorting (no locale)
- Avoids shell quoting issues

**Path uniqueness**: `files[].path` must be unique case-insensitively.

## Versioning Policy

### schemaVersion Bump Triggers

**Breaking changes** that require `schemaVersion` bump:
- Removing a required field
- Changing field type
- Changing encoding format (e.g., unitScale encoding algorithm)
- Changing hash computation (e.g., domain separation prefix)
- Changing validation rules that reject previously valid data

**Non-bump changes** (allowed without version bump):
- Adding optional fields
- Adding new content types or roles to whitelists
- Comments, refactors, tests, lint improvements
- Documentation updates

### Compatibility Rules

- `schemaVersion != 1` is **rejected** by current decoder
- Future versions require explicit upgrade path
- Decoder MUST throw `ArtifactError.unsupportedSchemaVersion(version, supported: 1)` for `schemaVersion != 1`

## Equatable/Hashable Forbidden

**SEALED**: `ArtifactManifest` MUST NOT conform to `Equatable` or `Hashable`.

- Enforcement: Lint script checks repo-wide for extensions
- Rationale: Hash comparison should use `artifactHash` field explicitly, not structural equality

## Implementation Requirements

### Required Files

1. `Core/Artifacts/ArtifactManifest.swift`
   - All structs, validation, canonical encoding, hashing

2. `Tests/Artifacts/ArtifactManifestTests.swift`
   - Comprehensive test coverage (16+ tests)

3. `scripts/artifact_contract_lint.sh`
   - Forbidden API checks
   - Extension bypass detection

4. `docs/constitution/ARTIFACT_CONTRACT.md`
   - This document (SSOT)

### CI Integration

- Test job runs `swift test`
- Lint step runs `bash scripts/artifact_contract_lint.sh`
- Swift version: Pinned to `5.9.2` (no nightly)

## References

- PR#10.5.9 Artifact Contract Implementation
- PR#10 Determinism Specification (for policy hash context)
- PR#12 BuildMeta (for buildMeta type context)

