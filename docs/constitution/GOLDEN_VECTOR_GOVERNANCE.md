# Golden Vector Governance

**Document Version:** 1.1.1  
**Status:** IMMUTABLE  
**Rule ID:** GVG_001

---

## Overview

Golden vectors are **constitutional artifacts**, not test conveniences. They encode historical determinism guarantees and must be treated with the same rigor as the SSOT constants themselves.

---

## Default Rule: Golden Updates Are Forbidden

**Rule ID:** GVG_001  
**Status:** IMMUTABLE

Any PR that modifies:
- `GOLDEN_VECTORS_ENCODING.json`
- `GOLDEN_VECTORS_QUANTIZATION.json`
- `GOLDEN_VECTORS_COLOR.json`

**MUST** also modify at least one of:
- `BREAKING_CHANGE_SURFACE.json` (document the breaking change)
- `MIGRATION_GUIDE.md` (document migration path)
- `contractVersion` in `FoundationVersioning.swift` (explicit version bump)

**Otherwise CI MUST fail.**

---

## When Golden Vectors May Be Updated

### Scenario 1: Breaking Change (Explicit)

**Allowed when:**
- A breaking change is intentionally introduced
- `BREAKING_CHANGE_SURFACE.json` is updated to document the change
- `MIGRATION_GUIDE.md` includes migration notes
- `contractVersion` is incremented

**Example:**
- Changing quantization precision (A3)
- Changing byte order (A2)
- Changing color white point (CE)

**Required documentation:**
- Breaking change surface entry
- Migration guide entry
- Version bump

---

### Scenario 2: Test Correction (Rare)

**Allowed when:**
- Golden vector was incorrectly specified initially
- No actual behavior change occurred
- Test was wrong, not implementation

**Required:**
- Explicit justification in PR description
- Review approval from platform architect
- No breaking change surface impact

**Note:** This should be extremely rare. If you find yourself here, question whether the test was wrong or the implementation drifted.

---

### Scenario 3: Adding New Vectors (Append-Only)

**Allowed when:**
- Adding new test vectors to existing files
- No modification of existing vectors
- Append-only addition

**Required:**
- No breaking change documentation needed
- Must not modify existing vector expectations

---

## What Version Bump or RFC Is Required

### Minor Changes (Append-Only)
- **No version bump required**
- Adding new vectors is safe

### Breaking Changes
- **contractVersion MUST be incremented**
- **RFC required** if change affects:
  - Identity derivation (patchId, geomId, meshEpochSalt)
  - Color conversion (Lab values)
  - Encoding format (byte order, string format)

---

## How Users and Downstream Systems Are Affected

### Encoding Changes (A2)
**Impact:**
- All existing patchId/geomId values become invalid
- Historical assets cannot be verified
- Cross-platform consistency breaks

**Mitigation:**
- New schemaVersion required
- Explicit migration boundary
- Old assets marked as legacy

### Quantization Changes (A3, A4)
**Impact:**
- All existing quantized coordinates change
- Identity inheritance breaks
- Historical comparisons invalid

**Mitigation:**
- New schemaVersion required
- Explicit migration boundary
- Old quantized values cannot be reused

### Color Changes (CE)
**Impact:**
- All L3 color evidence becomes invalid
- Historical color comparisons break
- Asset grading may change

**Mitigation:**
- New schemaVersion required
- Explicit migration boundary
- Old L3 evidence cannot be inherited

---

## Whether Inheritance of Old Evidence Is Allowed

### General Rule: No Silent Inheritance

**Rule ID:** GVG_002  
**Status:** IMMUTABLE

When golden vectors change due to breaking change:
- **Old evidence CANNOT be silently inherited**
- New schemaVersion creates explicit boundary
- Old evidence must be recomputed or marked legacy

### Exception: Append-Only Additions

If only new vectors are added (no existing vectors modified):
- Old evidence remains valid
- New vectors extend coverage
- No inheritance boundary created

---

## Golden Vector Update Process

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

5. **Run CI:**
   - Gate A must pass
   - Gate B must pass
   - Golden vector governance check must pass

---

## Enforcement

**CI Enforcement:**
- `.github/workflows/ssot-foundation-ci.yml` includes `golden_vector_governance` job
- Automatically detects golden vector changes
- Fails if breaking change documentation missing

**Manual Review:**
- All golden vector changes require explicit review
- Platform architect must approve breaking changes
- Test corrections require justification

---

## History and Auditability

Golden vectors encode history. They are:
- **Not disposable:** Cannot be casually updated
- **Not test data:** They are constitutional artifacts
- **Not optional:** They enforce long-term determinism

**Remember:** If you change a golden vector, you are changing history. This requires explicit acknowledgment and migration planning.

---

## Examples

### ✅ Allowed: Append-Only Addition

```json
// Adding new test vector
{
  "name": "new_edge_case",
  "input": 0.00015,
  "precision": 0.0001,
  "expectedQuantized": 2
}
```

**Action:** No documentation needed.

---

### ❌ Forbidden: Silent Update

```json
// Changing existing vector
{
  "name": "geomId_1mm_positive",
  "input": 0.001,
  "precision": 0.001,
  "expectedQuantized": 2  // Changed from 1
}
```

**Action:** CI fails. Must update breaking change documentation.

---

### ✅ Allowed: Breaking Change with Documentation

```json
// Changing quantization precision (breaking change)
{
  "name": "geomId_1mm_positive",
  "input": 0.001,
  "precision": 0.0005,  // Changed from 0.001
  "expectedQuantized": 2
}
```

**Required actions:**
1. Update `BREAKING_CHANGE_SURFACE.json` (add entry for `quant.geom_precision`)
2. Update `MIGRATION_GUIDE.md` (document migration)
3. Increment `contractVersion`
4. Document impact in PR

---

**Status:** APPROVED FOR PR#1 v1.1.1  
**Enforcement:** CI + Manual Review  
**Audience:** All contributors modifying SSOT Foundation
