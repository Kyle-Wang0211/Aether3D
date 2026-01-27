# Guardian Layer

<!-- MARKER: GUARDIAN_LAYER -->

**Document Version:** 1.1.1  
**Status:** IMMUTABLE  
**Rule ID:** GUARDIAN_001

---

## Overview

The Guardian Layer unifies three responsibilities into one coherent system:

1. **CI Enforcement** (machine-level defense)
2. **Failure Triage & Repair Guidance** (developer-level defense)
3. **User Trust & Explanation Integrity** (product-level defense)

These are not separate features. They are three faces of the same guarantee:

> **Nothing breaks silently.**  
> **Nothing is fixed blindly.**  
> **Nothing is shown to users without truth and context.**

---

## The Unified Guarantee

### Machine-Level Defense (CI)

**What it does:**
- Blocks silent drift
- Blocks accidental identity changes
- Blocks explanation inconsistencies
- Blocks "green by editing goldens"

**How it works:**
- Two-gate CI architecture
- Multi-axis matrix (build config × toolchain)
- Actionable failure messages with invariant IDs

**Invariant IDs referenced:**
- A2, A3, A4, A5 (Encoding, Quantization, Closure)
- B1, B2, B3 (Explanation, Governance)
- CE, CL2 (Color, Numerical Tolerances)
- C1, D2, E2, G1 (Breaking Surface, Minimum Set, Reproducibility, Domain Prefixes)

---

### Developer-Level Defense (Failure Triage)

**What it does:**
- Prevents "fixing tests" instead of fixing reality
- Provides actionable guidance for every failure
- Categorizes failures by invariant type
- Explains why invariants exist

**How it works:**
- `FAILURE_TRIAGE_MAP.md` documents every invariant category
- Each category includes: what broke, why it exists, allowed fixes, forbidden fixes
- Quick reference decision tree
- Golden vector update process

**Invariant IDs referenced:**
- Same IDs as CI (A2, A3, A4, A5, B1, B2, B3, CE, CL2, C1, D2, E2, G1)

---

### Product-Level Defense (Explanation Integrity)

**What it does:**
- Ensures system never lies to users
- Ensures no unexplained outputs
- Ensures no false blame
- Ensures no false certainty

**How it works:**
- `EXPLANATION_INTEGRITY_AUDIT.md` defines explanation philosophy
- Mandatory explanation audits
- Risk-oriented review
- Explanation drift prevention

**Invariant IDs referenced:**
- B1, B2 (Explanation Completeness)
- EIA_001 (Explanation Integrity)
- U2 (No Empty Hints)

---

## One Source of Truth

### Invariant ID Vocabulary

All three layers use the same invariant IDs:

| Invariant ID | Meaning | CI | Triage | Explanation |
|--------------|---------|----|--------|-------------|
| A2 | Encoding (byte order, string format) | ✅ | ✅ | - |
| A3 | Quantization precision | ✅ | ✅ | - |
| A4 | Rounding mode | ✅ | ✅ | - |
| A5 | meshEpochSalt closure | ✅ | ✅ | - |
| B1 | Explanation catalog completeness | ✅ | ✅ | ✅ |
| B2 | Guaranteed interpretability fields | ✅ | ✅ | ✅ |
| B3 | Enum order freezing | ✅ | ✅ | - |
| CE | Color encoding (D65, matrices) | ✅ | ✅ | - |
| CL2 | Numerical tolerances | ✅ | ✅ | - |
| C1 | Breaking change surface | ✅ | ✅ | - |
| D2 | Minimum explanation set | ✅ | ✅ | ✅ |
| E2 | Reproducibility boundary | ✅ | ✅ | - |
| G1 | Domain separation prefixes | ✅ | ✅ | - |
| EIA_001 | Explanation integrity | - | - | ✅ |
| U2 | No empty hints | ✅ | ✅ | ✅ |

---

## CI Failure Message Contract

Every CI failure must emit:

1. **Invariant ID(s):** e.g. A3, CE, CL2, B1
2. **Failing artifact:** file + key + value
3. **Why this violates SSOT guarantees:** brief explanation
4. **Allowed fix category:**
   - catalog update
   - append-only enum extension
   - RFC + breaking change
   - forbidden change

**Example:**
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

---

## Failure Triage Map Structure

For each invariant category, `FAILURE_TRIAGE_MAP.md` includes:

1. **What broke:** Specific failure scenarios
2. **Why this invariant exists:** Rationale
3. **What fixes are allowed:** ✅ Allowed actions
4. **What fixes are forbidden:** ❌ Forbidden actions
5. **RFC / Version bump required:** YES/NO
6. **User impact if violated:** Impact description
7. **Example failure:** Real failure message
8. **Repair steps:** Step-by-step guidance

---

## Explanation Integrity Audit Structure

`EXPLANATION_INTEGRITY_AUDIT.md` includes:

1. **Explanation Philosophy:** Core principles
2. **Mandatory Explanation Audits:** Completeness, uniqueness, consistency, safety
3. **Risk-Oriented Review:** User confusion, false blame, false certainty, support escalation
4. **Explanation Categories:** Specific guidance for each category
5. **Explanation Drift Prevention:** Append-only text, semantic stability, wording change policy
6. **User Trust Guarantees:** No unexplained outputs, no false precision, no false blame, actionable or explicit non-actionable

---

## The Flow: From CI Failure to User Trust

### Step 1: CI Detects Violation

```
CI Failure:
❌ Lab L* channel mismatch for 'sRGB_red'
Invariant: CL2, CE
Expected: 53.2408
Actual: 53.2420
Difference: 0.0012
Tolerance: 0.001 (absolute per channel)
File: GOLDEN_VECTORS_COLOR.json
Fix: Check color conversion implementation OR update golden vector with breaking change documentation
```

### Step 2: Developer Consults Triage Map

Developer looks up `CL2, CE` in `FAILURE_TRIAGE_MAP.md`:

- **What broke:** Color conversion tolerance exceeded
- **Why:** Cross-platform consistency requires fixed tolerances
- **Allowed fixes:** Fix implementation OR RFC + version bump
- **Forbidden fixes:** Loosen tolerance without RFC
- **User impact:** Cross-platform consistency erodes

### Step 3: Developer Fixes Correctly

Developer fixes implementation (not golden vector), preserving:
- User trust (no breaking change)
- Historical reproducibility (golden vectors intact)
- Cross-platform consistency (tolerance maintained)

### Step 4: Explanation Integrity Maintained

If explanation catalog affected:
- `EXPLANATION_INTEGRITY_AUDIT.md` ensures explanations remain truthful
- No false certainty introduced
- No user blame introduced
- User trust preserved

---

## Success Criteria

The Guardian Layer is successful only if:

1. **CI prevents silent technical drift**
   - ✅ Multi-axis matrix catches optimization-level drift
   - ✅ Two-gate architecture catches violations early
   - ✅ Actionable messages guide correct fixes

2. **Developers know exactly how to respond to failures**
   - ✅ Triage map provides clear guidance
   - ✅ Invariant IDs link CI → Triage → Explanation
   - ✅ Forbidden fixes are explicit

3. **Users never see unexplained or dishonest outputs**
   - ✅ Explanation integrity audits prevent false information
   - ✅ Completeness checks ensure all outputs explained
   - ✅ Risk-oriented review prevents trust erosion

4. **Future contributors cannot "accidentally" break trust**
   - ✅ CI blocks illegal changes automatically
   - ✅ Triage map prevents "fixing tests"
   - ✅ Explanation audits prevent false information

---

## Integration Points

### CI ↔ Triage Map

- CI failures reference invariant IDs
- Triage map documents each invariant ID
- Same vocabulary, same mental model

### Triage Map ↔ Explanation Audit

- Triage map explains why invariants exist
- Explanation audit ensures user-facing truth
- Both protect user trust

### CI ↔ Explanation Audit

- CI validates explanation completeness
- Explanation audit ensures explanation quality
- Both prevent unexplained outputs

---

## The Constitutional Court Analogy

**CI is the constitutional court:**
- Interprets SSOT Foundation rules
- Blocks violations automatically
- Provides clear rulings (failure messages)

**Triage Map is the legal guide:**
- Explains what each rule means
- Provides guidance for compliance
- Prevents accidental violations

**Explanation Audit is the truth commission:**
- Ensures system never lies
- Protects user trust
- Maintains explanation integrity

Together, they form a complete system protecting:
- **Reality** (determinism, reproducibility)
- **History** (audit trails, golden vectors)
- **Trust** (explanations, user experience)

---

**Status:** APPROVED FOR PR#1 v1.1.1  
**Enforcement:** CI + Manual Review  
**Audience:** All contributors, product managers, support team  
**Purpose:** Unify CI enforcement, failure triage, and user trust into one coherent system
