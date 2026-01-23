# Failure Triage Map

**Document Version:** 1.1.1  
**Status:** IMMUTABLE  
**Rule ID:** TRIAGE_001

---

## Overview

This document prevents developers from "fixing tests" instead of fixing reality.

**Purpose:** Provide actionable guidance for every SSOT Foundation test failure.

**Philosophy:** CI failures are not inconveniences. They are constitutional violations that must be addressed correctly.

---

## Invariant Categories

### A2: Encoding Invariants

**What broke:**
- Byte order changed (Big-Endian → Little-Endian)
- String encoding format changed (length-prefixed → NUL-terminated)
- Domain separation prefix encoding changed
- Unicode normalization changed (NFC → NFD)

**Why this invariant exists:**
- Identity derivation (patchId, geomId, meshEpochSalt) depends on byte-level determinism
- Cross-platform consistency requires identical byte sequences
- Historical reproducibility requires stable encoding

**What fixes are allowed:**
- ✅ Fix implementation if implementation drifted
- ✅ Append new encoding vectors (append-only)
- ❌ **FORBIDDEN:** Change encoding format without breaking change process
- ❌ **FORBIDDEN:** Update golden vectors silently

**RFC / Version bump required:**
- YES - Any encoding format change requires RFC + contractVersion bump

**User impact if violated:**
- All existing patchId/geomId values become invalid
- Historical assets cannot be verified
- Cross-platform consistency breaks

**Example failure:**
```
❌ Encoding mismatch for 'simple_ascii'
Invariant: A2
Expected: 0000000568656c6c6f
Actual: 0000000568656c6c6f00
File: GOLDEN_VECTORS_ENCODING.json
Fix: Fix encoding implementation OR update golden vector with breaking change documentation
```

**Repair steps:**
1. Identify which encoding rule changed (byte order, string format, etc.)
2. If implementation wrong: fix implementation
3. If intentional change: follow breaking change process (RFC + version bump)

---

### A3/A4: Quantization Invariants

**What broke:**
- Quantization precision changed (1mm → 0.5mm)
- Rounding mode changed (ROUND_HALF_AWAY_FROM_ZERO → HALF_EVEN)
- Precision separation violated (geomId == patchId precision)

**Why this invariant exists:**
- Identity stability requires fixed quantization precision
- Cross-platform consistency requires identical rounding behavior
- Precision separation prevents identity collision

**What fixes are allowed:**
- ✅ Fix implementation if implementation drifted
- ✅ Append new quantization vectors (append-only)
- ❌ **FORBIDDEN:** Change precision without breaking change process
- ❌ **FORBIDDEN:** Change rounding mode without breaking change process

**RFC / Version bump required:**
- YES - Any precision or rounding mode change requires RFC + contractVersion bump

**User impact if violated:**
- All existing quantized coordinates change
- Identity inheritance breaks
- Historical comparisons invalid

**Example failure:**
```
❌ Quantization mismatch for 'geomId_1mm_positive'
Invariant: A3, A4
Input: 0.001
Precision: 0.001
Expected: 1
Actual: 2
File: GOLDEN_VECTORS_QUANTIZATION.json
Fix: Fix quantization implementation OR update golden vector with breaking change documentation
```

**Repair steps:**
1. Identify which quantization rule changed (precision, rounding mode)
2. If implementation wrong: fix implementation
3. If intentional change: follow breaking change process (RFC + version bump)

---

### A5: meshEpochSalt Closure Invariants

**What broke:**
- Included input changed (added/removed field)
- Excluded input included (deviceModelClass, timestampRange)
- Audit-only input used for identity derivation

**Why this invariant exists:**
- Identity must be deterministic and causal
- Cross-device inheritance requires stable closure
- Privacy requires exclusion of device-specific fields

**What fixes are allowed:**
- ✅ Fix implementation if closure violated
- ✅ Update closure documentation if documentation was wrong
- ❌ **FORBIDDEN:** Change closure without breaking change process

**RFC / Version bump required:**
- YES - Any closure change requires RFC + contractVersion bump

**User impact if violated:**
- Identity becomes non-deterministic
- Cross-device inheritance breaks
- Privacy concerns arise

**Example failure:**
```
❌ meshEpochSalt closure must exclude 'deviceModelClass'
Invariant: A5
File: CrossPlatformConstants.swift
Fix: Remove deviceModelClass from identity derivation OR update closure with breaking change documentation
```

**Repair steps:**
1. Identify which closure rule violated
2. If implementation wrong: fix implementation
3. If intentional change: follow breaking change process (RFC + version bump)

---

### CE: Color Encoding Invariants

**What broke:**
- White point changed (D65 → D50)
- Color conversion matrix changed
- System/OS color API used instead of SSOT constants

**Why this invariant exists:**
- L3 color evidence must be stable across years
- Cross-platform consistency requires identical color conversion
- Historical reproducibility requires fixed reference system

**What fixes are allowed:**
- ✅ Fix implementation if implementation drifted
- ✅ Append new color vectors (append-only)
- ❌ **FORBIDDEN:** Change white point without breaking change process
- ❌ **FORBIDDEN:** Change conversion matrices without breaking change process

**RFC / Version bump required:**
- YES - Any color system change requires RFC + contractVersion bump + no L3 inheritance

**User impact if violated:**
- All existing L3 color evidence becomes invalid
- Historical color comparisons break
- Asset grading may change

**Example failure:**
```
❌ Lab L* channel mismatch for 'sRGB_red'
Invariant: CL2, CE
Expected: 53.2408
Actual: 53.2420
Difference: 0.0012
Tolerance: 0.001 (absolute per channel)
File: GOLDEN_VECTORS_COLOR.json
Fix: Check color conversion implementation OR update golden vector with breaking change documentation
```

**Repair steps:**
1. Identify which color rule changed (white point, matrix, etc.)
2. If implementation wrong: fix implementation
3. If intentional change: follow breaking change process (RFC + version bump + migration note)

---

### CL2: Numerical Tolerance Invariants

**What broke:**
- Tolerance loosened (1e-4 → 1e-3)
- Tolerance formula changed
- Relative error epsilon changed (1e-12 → 1e-10)

**Why this invariant exists:**
- Cross-platform equivalence requires fixed tolerances
- Tolerance defines "same input ≈ same output" contract
- Loosening tolerance erodes determinism guarantees

**What fixes are allowed:**
- ✅ Fix implementation if implementation drifted
- ❌ **FORBIDDEN:** Loosen tolerance without RFC
- ❌ **FORBIDDEN:** Change tolerance formula without breaking change process

**RFC / Version bump required:**
- YES - Any tolerance change requires RFC + contractVersion bump

**User impact if violated:**
- Cross-platform consistency erodes
- "Same input ≈ same output" guarantee weakens
- User trust erodes

**Example failure:**
```
❌ Coverage/Ratio relative error tolerance must be 1e-4 (CL2)
Actual: 1e-3
File: CrossPlatformConstants.swift
Fix: Revert tolerance change OR RFC to adjust tolerance with justification
```

**Repair steps:**
1. Identify which tolerance changed
2. If accidental: revert tolerance change
3. If intentional: RFC + version bump + justification

---

### B1/B2/B3: Explanation & Governance Invariants

**What broke:**
- Enum case missing from explanation catalog
- Explanation catalog entry missing required fields
- Enum case order changed (frozen order violated)
- Enum case renamed or deleted (append-only violated)

**Why this invariant exists:**
- Users must understand system outputs
- Enum order stability enables log comparability
- Append-only rule prevents historical data invalidation

**What fixes are allowed:**
- ✅ Add missing catalog entry
- ✅ Append new enum case to end
- ✅ Fix catalog entry structure
- ❌ **FORBIDDEN:** Reorder enum cases
- ❌ **FORBIDDEN:** Rename enum cases
- ❌ **FORBIDDEN:** Delete enum cases

**RFC / Version bump required:**
- NO - Adding catalog entries or appending enum cases doesn't require RFC
- YES - Renaming/deleting enum cases requires RFC (but is forbidden)

**User impact if violated:**
- Users see unexplained outputs
- Support cannot help effectively
- Log comparability breaks
- Historical data invalidates

**Example failure:**
```
❌ EdgeCaseType.NEGATIVE_INPUT (code: 'NEGATIVE_INPUT') missing from USER_EXPLANATION_CATALOG.json (B1)
Fix: Add explanation entry for NEGATIVE_INPUT to USER_EXPLANATION_CATALOG.json
```

**Repair steps:**
1. Identify missing entry or violated rule
2. Add catalog entry OR revert enum change
3. Update frozenCaseOrderHash if appending enum case

---

### C1: Breaking Surface Invariants

**What broke:**
- Breaking change surface not documented
- Breaking change made without RFC
- Breaking change made without version bump

**Why this invariant exists:**
- Breaking changes must be explicit and auditable
- Downstream systems must be notified
- Migration paths must be documented

**What fixes are allowed:**
- ✅ Add breaking change documentation
- ✅ Create RFC for breaking change
- ✅ Increment contractVersion
- ❌ **FORBIDDEN:** Make breaking change silently

**RFC / Version bump required:**
- YES - All breaking changes require RFC + contractVersion bump

**User impact if violated:**
- Downstream systems break unexpectedly
- Migration becomes impossible
- User trust erodes

**Example failure:**
```
❌ BREAKING_CHANGE_SURFACE.json missing required surface 'quant.geom_precision' (C1)
Fix: Add entry to BREAKING_CHANGE_SURFACE.json OR revert quantization precision change
```

**Repair steps:**
1. Identify which breaking surface changed
2. Add entry to BREAKING_CHANGE_SURFACE.json
3. Create RFC documenting change
4. Increment contractVersion
5. Update MIGRATION_GUIDE.md

---

### D2: Minimum Explanation Set Invariants

**What broke:**
- Minimum explanation set not satisfied
- Mandatory code missing from catalog
- Catalog completeness check failed

**Why this invariant exists:**
- MVP UX requires minimum explanation coverage
- Users must understand critical scenarios
- Support must have explanations for common cases

**What fixes are allowed:**
- ✅ Add missing catalog entries
- ✅ Update minimum explanation set if requirements changed
- ❌ **FORBIDDEN:** Remove codes from minimum set without justification

**RFC / Version bump required:**
- NO - Adding entries doesn't require RFC
- YES - Removing codes from minimum set requires RFC

**User impact if violated:**
- Users see unexplained critical scenarios
- Support cannot help with common cases
- User trust erodes

**Example failure:**
```
❌ MINIMUM_EXPLANATION_SET.json requires 'PRC_CAPTURE_OCCLUDED' but it's missing from USER_EXPLANATION_CATALOG.json
Invariant: D2
Fix: Add explanation entry for 'PRC_CAPTURE_OCCLUDED' to USER_EXPLANATION_CATALOG.json
```

**Repair steps:**
1. Identify missing mandatory code
2. Add explanation entry to catalog
3. Ensure all required fields present

---

### E2: Reproducibility Boundary Invariants

**What broke:**
- Required version field missing
- Runtime switching detected
- Reproducibility bundle incomplete

**Why this invariant exists:**
- Assets must be reproducible for audit/dispute resolution
- Historical reproducibility requires fixed parameters
- Runtime switching breaks reproducibility guarantees

**What fixes are allowed:**
- ✅ Add missing version fields
- ✅ Remove runtime switching code
- ✅ Complete reproducibility bundle
- ❌ **FORBIDDEN:** Remove version fields
- ❌ **FORBIDDEN:** Add runtime switching

**RFC / Version bump required:**
- NO - Adding version fields doesn't require RFC
- YES - Removing version fields requires RFC

**User impact if violated:**
- Assets cannot be reproduced
- Audit/dispute resolution impossible
- User trust erodes

**Example failure:**
```
❌ Reproducibility bundle missing required field 'deterministicEncodingVersion'
Invariant: E2
Fix: Add deterministicEncodingVersion field to reproducibility bundle
```

**Repair steps:**
1. Identify missing version field
2. Add version field to bundle
3. Ensure all required fields present

---

## Golden Vector Failures (Special Section)

### Why Golden Vectors Exist

Golden vectors are **historical records**, not test data.

They encode:
- Historical determinism guarantees
- Cross-platform consistency expectations
- Identity derivation correctness

### Why Updating Them Is Dangerous

Updating golden vectors changes history:
- Old outputs become "wrong"
- Historical comparisons break
- Audit trails become unreliable

### What Must Accompany a Golden Change

**Required (all of):**
1. Update to `BREAKING_CHANGE_SURFACE.json`
2. Update to `MIGRATION_GUIDE.md`
3. `contractVersion` bump

**Optional but recommended:**
- RFC documenting change
- User-facing migration guide
- Support team notification

### Golden Vector Update Process

1. **Identify the change:**
   - Is this a breaking change?
   - Is this a test correction?
   - Is this an append-only addition?

2. **If breaking change:**
   - Update `BREAKING_CHANGE_SURFACE.json`
   - Update `MIGRATION_GUIDE.md`
   - Increment `contractVersion`
   - Document impact in PR description

3. **If test correction:**
   - Justify why test was wrong
   - Get platform architect approval
   - Document in PR description

4. **If append-only:**
   - No additional documentation needed
   - Ensure no existing vectors modified

---

## Enum Order / Closed Set Failures

### Why Enum Order Is Frozen

**Frozen order enables:**
- Log comparability across years
- Serialization stability
- Historical analysis
- Audit integrity

**Frozen order prevents:**
- Silent log format drift
- Serialization breakage
- Historical data invalidation
- Audit trail confusion

### Why Renaming Is Forbidden

Renaming breaks:
- Historical log parsing
- Serialized data compatibility
- Audit trail consistency

### Why Deletion Is Forbidden

Deletion breaks:
- Historical data validity
- Audit trail completeness
- Log comparability

### Why Append-Only Is the Only Allowed Path

Append-only preserves:
- Historical data validity
- Log comparability
- Serialization compatibility
- Audit integrity

### Examples

**✅ Legal Append:**
```swift
enum EdgeCaseType {
    case EXISTING_CASE
    case NEW_CASE  // ✅ Appended to end
}
// Must update frozenCaseOrderHash
```

**❌ Illegal Reorder:**
```swift
enum EdgeCaseType {
    case CASE_B  // ❌ Moved before CASE_A
    case CASE_A
}
// CI fails: frozenCaseOrderHash mismatch
```

**❌ Illegal Rename:**
```swift
enum EdgeCaseType {
    case RENAMED_CASE  // ❌ Was OLD_CASE
}
// CI fails: frozenCaseOrderHash mismatch
```

**❌ Illegal Delete:**
```swift
enum EdgeCaseType {
    // ❌ CASE_A deleted
    case CASE_B
}
// CI fails: frozenCaseOrderHash mismatch
```

---

## Quick Reference: Fix Decision Tree

```
Test Failed
│
├─ Encoding (A2)?
│  ├─ Implementation wrong? → Fix implementation
│  └─ Intentional change? → RFC + version bump
│
├─ Quantization (A3/A4)?
│  ├─ Implementation wrong? → Fix implementation
│  └─ Intentional change? → RFC + version bump
│
├─ Color (CE)?
│  ├─ Implementation wrong? → Fix implementation
│  └─ Intentional change? → RFC + version bump + no L3 inheritance
│
├─ Enum/Catalog (B1/B2/B3)?
│  ├─ Missing entry? → Add catalog entry
│  ├─ Enum reorder? → Revert reorder
│  └─ Enum rename/delete? → Revert (forbidden)
│
├─ Golden Vector?
│  ├─ Implementation wrong? → Fix implementation
│  ├─ Test wrong? → Update golden + justification
│  └─ Intentional change? → Breaking change process
│
└─ Other?
   └─ See specific invariant section above
```

---

## Forbidden Fixes (Will Cause CI Failure)

1. **Silent golden vector updates** (without breaking change docs)
2. **Enum case reorder** (without updating frozenCaseOrderHash)
3. **Enum case deletion** (append-only rule)
4. **Tolerance loosening** (without RFC)
5. **Breaking surface changes** (without RFC + version bump)
6. **Catalog code deletion** (append-only rule)
7. **Encoding format change** (without RFC + version bump)
8. **Quantization precision change** (without RFC + version bump)
9. **Color system change** (without RFC + version bump + migration)

---

**Status:** APPROVED FOR PR#1 v1.1.1  
**Enforcement:** CI + Manual Review  
**Audience:** All contributors  
**Purpose:** Prevent "fixing tests" instead of fixing reality
