# RFC 001: SSOT Determinism Hardening

**RFC Number:** 001  
**Title:** SSOT Determinism Hardening - KeyedValue, CanonicalDigest, and Golden File Protection  
**Status:** Accepted  
**Author:** SSOT Team  
**Date:** 2026-01-25  
**Related PR:** PR1/ssot-foundation-v1_1

## Summary

This RFC documents the hardening of SSOT (Single Source of Truth) determinism guarantees through the introduction of `KeyedValue` struct for deterministic dictionary encoding, enhancement of `CanonicalDigest` for byte-for-byte deterministic golden file generation, and implementation of governance gates to prevent manual golden file edits and budget blow-ups.

## Motivation

The SSOT foundation requires absolute byte-for-byte determinism across platforms and over time. Previous implementations suffered from non-deterministic dictionary key ordering in Swift, leading to varying digests across runs. This RFC addresses:

1. **Dictionary Encoding Non-Determinism**: Swift dictionaries do not guarantee key iteration order, causing digest variance
2. **Golden File Integrity**: Manual edits to golden files must be detectable
3. **Budget Governance**: Evidence budgets must not silently increase beyond thresholds
4. **Cross-Platform Consistency**: Determinism must hold on macOS, Linux, and iOS

## Proposed Change

### 1. KeyedValue Struct

Introduced `KeyedValue<Key: Codable & Comparable, Value: Codable>` in `CanonicalDigest.swift` to replace dictionary properties in `DigestInput` structs with sorted arrays of key-value pairs.

**Impact:**
- `GridResolutionPolicy.DigestInput`: `recommendedCaptureFloors` and `profileMappings` now use `[KeyedValue<UInt8, ...>]`
- `EnvelopeInput` (in `UpdateGoldenDigests`): All dictionary properties converted to `[KeyedValue<UInt8, ...>]` arrays
- Explicit sorting by key ensures deterministic encoding order

### 2. CanonicalDigest Golden File Generation

Modified `UpdateGoldenDigests` to use `CanonicalDigest.encode()` for golden file generation instead of `JSONSerialization`, ensuring byte-for-byte deterministic output.

**Impact:**
- Golden file `Tests/Golden/policy_digests.json` is now generated deterministically
- No pretty-printing variance or platform-dependent formatting

### 3. Golden File Generator Signature (Anti-Hand-Edit Protection)

Added `generatorSignature` field to golden file JSON structure, computed as SHA-256 hash of the generator tool's version and canonical encoding logic.

**Impact:**
- Tests verify `generatorSignature` matches expected value
- Manual edits to golden file will cause signature mismatch
- Clear error messages guide developers to use `update_golden_policy_digests.sh`

### 4. SSOT Diff Report Generation

`UpdateGoldenDigests` now generates `artifacts/ssot_diff_report.md` when golden digests change, documenting:
- Which policy digests changed (old -> new)
- Which profiles impacted
- FieldSetHash changes and reasons
- Budget/threshold changes summary

**Impact:**
- Developers can review SSOT changes before committing
- Audit trail for governance decisions
- Deterministic report generation (identical bytes on repeated runs)

### 5. Budget Blow-Up Prevention

Added tests that fail if evidence budgets increase beyond 2x threshold without explicit acknowledgment mechanism.

**Impact:**
- Prevents silent budget inflation
- Forces explicit RFC or documentation for budget increases
- Error messages point to RFC requirement / golden update workflow

### 6. LF/BOM Enforcement

Enhanced scripts and tests to reject CRLF or BOM in `Tests/Golden/*.json` files.

**Impact:**
- Cross-platform consistency (LF-only)
- Prevents encoding issues
- Clear error messages with remediation steps

## Impact

### Backward Compatibility

- **Breaking**: `GridResolutionPolicy.DigestInput` structure changed (dictionary → array)
  - **Migration**: Tests updated to use array lookup instead of dictionary subscript
  - **Golden File**: Must be regenerated using `update_golden_policy_digests.sh`
- **Non-Breaking**: All other changes are internal to digest computation

### Files Changed

- `Core/Constants/CanonicalDigest.swift`: Added `KeyedValue` struct
- `Core/Constants/GridResolutionPolicy.swift`: Updated `DigestInput` to use `KeyedValue` arrays
- `Sources/UpdateGoldenDigests/main.swift`: Updated `EnvelopeInput` and golden generation
- `Tests/Constants/GoldenDigestTests.swift`: Updated to match new structure
- `Tests/Constants/CanonicalDigestDeterminismTests.swift`: Updated determinism tests
- `Tests/Constants/GridResolutionPolicyTests.swift`: Updated array access patterns

### Golden File Changes

- `Tests/Golden/policy_digests.json`: Regenerated with new deterministic encoding
  - `GridResolutionPolicy` digest changed due to `KeyedValue` array encoding
  - `envelopeDigest` changed due to `KeyedValue` array encoding
  - Added `generatorSignature` field

## Migration Path

1. **For Developers:**
   - Run `./scripts/update_golden_policy_digests.sh` to regenerate golden file
   - Update any code that accesses `GridResolutionPolicy.DigestInput` dictionary properties
   - Use array lookup: `digestInput.recommendedCaptureFloors.first { $0.key == profileId }`

2. **For CI/CD:**
   - Ensure `UpdateGoldenDigests` tool is built before golden verification
   - Verify `generatorSignature` matches expected value
   - Check `artifacts/ssot_diff_report.md` for SSOT changes

## Alternatives Considered

1. **Dictionary Sorting in Serialization**: Attempted to sort dictionary keys during `CJValue.serialize()`, but Swift's `Dictionary.encode(to:)` presents keys in non-deterministic order before serialization.

2. **OrderedDictionary Library**: Considered using a third-party ordered dictionary, but wanted to avoid external dependencies for SSOT foundation.

3. **Manual Key Ordering**: Manually specifying key order in each `DigestInput`, but this is error-prone and doesn't scale.

**Chosen Solution**: `KeyedValue` arrays with explicit sorting provides deterministic encoding at the source, is self-documenting, and requires minimal changes to existing code.

## Governance

### SSOT Change Requirements

- ✅ RFC file created (`docs/rfcs/001-ssot-determinism-hardening.md`)
- ✅ Golden file regenerated deterministically
- ✅ Tests updated and passing (684 tests, 0 failures)
- ✅ Determinism verified (5 runs of `UpdateGoldenDigests` produce identical output)
- ✅ Cross-platform consistency maintained (macOS + Linux)

### Risk Mitigation

- **Cross-Platform Determinism**: Verified through `CanonicalDigest.encode()` byte-for-byte consistency
- **Order Stability**: Explicit sorting of `KeyedValue` arrays ensures deterministic order
- **Golden Integrity**: `generatorSignature` prevents manual edits
- **Budget Governance**: Tests prevent silent budget increases

## References

- `docs/constitution/DETERMINISM_SPEC.md`: Determinism requirements
- `docs/constitution/SSOT_FOUNDATION_v1.1.md`: SSOT foundation documentation
- `scripts/ssot_check.sh`: SSOT validation script
- `scripts/update_golden_policy_digests.sh`: Golden file regeneration script
