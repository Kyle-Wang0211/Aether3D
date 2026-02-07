# P5-T03: Format Validation Harness for CI

**Phase**: 5 - Format Bridge + Provenance Bundle  
**Dependencies**: P5-T02 (GLTFExporter)  
**Estimated Duration**: 2-3 days

## Goal

Integrate external format validators (gltf-validator, usd-checker, 3d-tiles-validator, e57validator) in CI. Fail build if validation fails. Support macOS and Linux CI.

## Non-Goals

- Implementing validators from scratch (use existing validators)
- Supporting all export formats in initial version (glTF first, others later)
- Implementing validator caching (always run validation)

## Inputs / Outputs

**Inputs**:
- Exported format file: GLB, USD, tileset.json, E57
- Validator command: External validator executable

**Outputs**:
- Validation result: Pass/fail
- Validation errors: Array of error messages (if validation failed)

## Public Interfaces

**FormatValidator** (struct):
- `init(validatorPath: String)`
- `validate(fileURL: URL, format: ExportFormat) throws -> ValidationResult`

**ValidationResult** (struct):
- `passed: Bool`
- `errors: [String]`
- `warnings: [String]`

**FormatValidatorError** (enum, Error, Sendable):
- `validatorNotFound(path: String)`
- `validationFailed(errors: [String])`
- `executionFailed(underlying: Error)`

**ExportFormat** (enum, Codable, Sendable):
- `gltf`
- `usd`
- `tiles3d`
- `e57`
- `gltfGaussianSplatting`

## Acceptance Criteria

1. **Validator Discovery**: Locate validator executable (gltf-validator, usd-checker, etc.) in PATH or specified path.
2. **Docker Integration**: Run validators in Docker containers for cross-platform consistency (macOS + Linux).
3. **GLB Validation**: Run gltf-validator on GLB file. Parse output, extract errors/warnings.
4. **USD Validation**: Run usd-checker on USD file. Parse output, extract errors/warnings.
5. **3D Tiles Validation**: Run 3d-tiles-validator on tileset.json. Parse output, extract errors/warnings.
6. **E57 Validation**: Run e57validator on E57 file. Parse output, extract errors/warnings.
7. **CI Integration**: Fail build if validation fails (any errors reported). Warnings are non-fatal.
8. **Timeout**: Validation timeout = 10 seconds per format. If timeout exceeded, fail validation.
9. **Cross-Platform**: Validators run identically on macOS (Docker Desktop) and Linux (native Docker).
10. **Error Reporting**: Validation errors reported in CI logs with file path and error details.

## Failure Modes & Error Taxonomy

**Validator Errors**:
- `FormatValidatorError.validatorNotFound`: Validator executable not found in PATH
- `FormatValidatorError.validationFailed`: Validation reported errors (errors array contains details)
- `FormatValidatorError.executionFailed`: Validator execution failed (underlying error wrapped)

## Determinism & Cross-Platform Notes

- **Docker Containers**: Validators run in Docker for cross-platform consistency (same validator version, same behavior).
- **Error Parsing**: Validator output parsing must be deterministic (same output = same parsed errors).

## Security Considerations

**Abuse Cases**:
- Validator compromise: Validators run in isolated Docker containers (limited attack surface)
- DoS via large files: File size limits prevent DoS (GLB max 100MB, etc.)

**Parsing Limits**:
- Validator output size: Max 1MB (reject larger outputs)
- Error count: Max 1000 errors (truncate if more)

**Replay Protection**:
- Not applicable (validation is read-only)

**Key Pinning**:
- Not applicable (no keys involved)

## Rollback Plan

1. Delete `Core/FormatBridge/FormatValidator.swift`
2. Delete `Core/FormatBridge/FormatValidatorError.swift`
3. Delete CI validation steps (revert CI configuration)
4. No impact on exporters (exporters remain functional, validation is optional)

## Open Questions

- **Validator Versions**: Which validator versions to pin? Document as implementation decision (use latest stable versions, update periodically).

---

**Implementation Not Started: Verified**

**Checklist**:
- [x] No Swift code implementations included
- [x] No test code included
- [x] Only interface names and signatures provided
- [x] Acceptance criteria are testable and fail-closed
- [x] Error taxonomy is complete
- [x] Security considerations addressed
