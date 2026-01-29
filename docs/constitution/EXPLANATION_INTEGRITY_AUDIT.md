# Explanation Integrity Audit

<!-- MARKER: EXPLANATION_INTEGRITY -->

**Document Version:** 1.1.1  
**Status:** IMMUTABLE  
**Rule ID:** EIA_001

---

## Overview

This document treats `USER_EXPLANATION_CATALOG.json` as a **product contract**, not documentation.

**Purpose:** Ensure the system never lies to users, never shows unexplained outputs, and never erodes trust.

---

## Explanation Philosophy (Explicit)

### Core Principles

1. **The system must never lie to users**
   - "Unknown" is better than false precision
   - "No action possible" must be explicit, not omitted
   - Scores without explanations are forbidden

2. **Explanation is a product requirement, not a feature**
   - Every output must be explainable
   - Every explanation must be truthful
   - Every explanation must be actionable or explicitly non-actionable

3. **User trust is non-negotiable**
   - False blame erodes trust
   - False certainty erodes trust
   - Unexplained outputs erode trust

---

## Mandatory Explanation Audits

### Audit Rule 1: Completeness

**Requirement:**
Every non-NORMAL PrimaryReasonCode must have:
- ✅ Human-readable explanation
- ✅ Technical explanation
- ✅ Severity classification
- ✅ Actionable guidance OR explicit non-actionability

**Enforcement:**
- `ExplanationCatalogCoverageTests` validates completeness
- CI blocks merge if incomplete

**Example violation:**
```
❌ PrimaryReasonCode.SPECULAR missing actionable guidance
Invariant: B2
Fix: Add suggestedActions OR mark as non-actionable with rationale
```

---

### Audit Rule 2: Uniqueness

**Requirement:**
No two codes explain the same reality ambiguously.

**Enforcement:**
- `CatalogUniquenessTests` validates uniqueness
- CI blocks merge if duplicates found

**Example violation:**
```
❌ Duplicate codes found: PRC_CAPTURE_OCCLUDED, PRC_HAND_OCCLUSION
Invariant: 5.1
Fix: Merge duplicate codes OR clarify semantic difference
```

---

### Audit Rule 3: Severity Consistency

**Requirement:**
Severity levels must be consistent across categories.

**Enforcement:**
- `CatalogUniquenessTests` validates consistency
- CI blocks merge if inconsistencies found

**Example violation:**
```
❌ Severity ↔ actionable inconsistency: PRC_RISK_FLAGGED (severity=critical, actionable=false)
Invariant: 5.1
Fix: Review severity/actionable consistency OR add justification
```

---

### Audit Rule 4: User Safety

**Requirement:**
Suggested actions must be user-safe and non-misleading.

**Enforcement:**
- Manual review required
- CI validates action codes exist in catalog

**Example violation:**
```
❌ Suggested action 'HINT_INVALID_ACTION' not found in catalog
Invariant: B2
Fix: Remove invalid action OR add action to catalog
```

---

## Risk-Oriented Review

### User Confusion Risk

**Assess for each explanation:**
- Is the explanation clear?
- Is the explanation accurate?
- Is the explanation non-technical enough?

**High-risk scenarios:**
- Technical jargon without user translation
- Ambiguous wording
- Contradictory explanations

**Mitigation:**
- Use `userExplanation` for clarity
- Use `technicalExplanation` for accuracy
- Review both fields for consistency

---

### False Blame Risk

**Assess for each explanation:**
- Does the explanation blame the user?
- Does the explanation imply user error?
- Is the explanation neutral?

**High-risk scenarios:**
- "You did X wrong"
- "Your device is inadequate"
- "You should have known"

**Mitigation:**
- Use neutral language
- Focus on physical limitations
- Emphasize "this is not your fault"

---

### False Certainty Risk

**Assess for each explanation:**
- Does the explanation claim certainty when uncertain?
- Does the explanation hide uncertainty?
- Is confidence level explicit?

**High-risk scenarios:**
- "Confirmed" when only "likely"
- Missing `primaryReasonConfidence`
- Overconfident language

**Mitigation:**
- Use `primaryReasonConfidence` appropriately
- Distinguish "likely" from "confirmed"
- Be explicit about uncertainty

---

### Support Escalation Risk

**Assess for each explanation:**
- Can support help with this?
- Is the explanation actionable?
- Is escalation path clear?

**High-risk scenarios:**
- No actionable guidance
- Vague suggestions
- Missing escalation path

**Mitigation:**
- Provide clear `suggestedActions`
- Include `HINT_CONTACT_SUPPORT` when needed
- Make escalation path explicit

---

## Explanation Categories: Specific Guidance

### Capture Occlusion

**User message must convey:**
- "This is not your fault"
- "This is a physical limitation"
- "This can be improved by doing X"

**Example good explanation:**
```
userExplanation: "Some parts of the object were temporarily blocked from view during scanning, possibly by your hand or another object."
suggestedActions: ["HINT_CLEAR_OCCLUSION", "HINT_CHANGE_ANGLE"]
```

**Example bad explanation:**
```
userExplanation: "You blocked the object with your hand."  // ❌ Blames user
```

---

### Structural Occlusion

**User message must convey:**
- "This is a physical limitation"
- "This cannot be fixed by rescanning"
- "This is expected for this object type"

**Example good explanation:**
```
userExplanation: "Some parts of the object were permanently blocked from view during scanning."
suggestedActions: ["HINT_CHANGE_ANGLE", "HINT_MOVE_CLOSER"]
```

---

### Specular / Transparent Surfaces

**User message must convey:**
- "This is a material limitation"
- "This is expected for reflective/transparent objects"
- "Appearance quality may be limited"

**Example good explanation:**
```
userExplanation: "The object has many reflective surfaces that make reliable color capture difficult."
appearancePromise: "cannot_promise"
expectedCeiling: "S4_warned"
```

---

### Dynamic Motion

**User message must convey:**
- "This is expected for moving objects"
- "This can be declared as dynamic-intended"
- "This limits appearance quality"

**Example good explanation:**
```
userExplanation: "The object moved during scanning, affecting reconstruction quality."
suggestedActions: ["HINT_STABILIZE_OBJECT", "HINT_DECLARE_DYNAMIC"]
expectedCeiling: "S4_warned"
```

---

### Boundary Ambiguity

**User message must convey:**
- "This is a detection limitation"
- "This can be improved with better lighting"
- "This is not a critical failure"

**Example good explanation:**
```
userExplanation: "The edges of the object are uncertain due to similar background or lighting conditions."
suggestedActions: ["HINT_IMPROVE_LIGHT", "HINT_CHANGE_ANGLE"]
```

---

## Explanation Drift Prevention

### Rule 1: Append-Only Text

**Requirement:**
Explanation text is append-only.

**Enforcement:**
- Manual review required for text changes
- CI validates structure, not text content

**Exception:**
- Typo fixes allowed with justification
- Semantic changes require catalog version bump

---

### Rule 2: Semantic Meaning Stability

**Requirement:**
Semantic meaning cannot change silently.

**Enforcement:**
- `meaningHash` field tracks semantic changes
- `meaningChangeRequiresRFC` flag enforces RFC requirement

**Example violation:**
```
❌ Explanation meaning changed without RFC
Code: PRC_CAPTURE_OCCLUDED
Old meaning: "Temporary occlusion"
New meaning: "Permanent occlusion"
Fix: Revert change OR RFC + catalog version bump
```

---

### Rule 3: Wording Change Policy

**Requirement:**
Any wording change with meaning impact requires:
- Catalog version bump
- Migration note
- Explicit rationale

**Enforcement:**
- Manual review required
- CI validates version bump if meaningHash changes

---

## Explanation Completeness Checklist

For each explanation entry, verify:

- [ ] `code` exists and is unique
- [ ] `category` is valid (primary_reason, action_hint, edge_case, risk_flag)
- [ ] `severity` is valid (info, caution, critical)
- [ ] `shortLabel` is ≤32 characters
- [ ] `userExplanation` is ≤500 characters, user-readable
- [ ] `technicalExplanation` exists for support/developers
- [ ] `appliesTo` array is non-empty
- [ ] `actionable` is consistent with severity
- [ ] `suggestedActions` is non-empty if actionable=true
- [ ] All `suggestedActions` codes exist in catalog
- [ ] `meaningHash` exists (v1.1.1)
- [ ] `meaningChangeRequiresRFC` is true (v1.1.1)

---

## User Trust Guarantees

### Guarantee 1: No Unexplained Outputs

**Requirement:**
Every output must have an explanation.

**Enforcement:**
- `ExplanationCatalogCoverageTests` validates coverage
- CI blocks merge if coverage incomplete

---

### Guarantee 2: No False Precision

**Requirement:**
Uncertainty must be explicit.

**Enforcement:**
- `primaryReasonConfidence` must be set appropriately
- CI validates confidence field exists

---

### Guarantee 3: No False Blame

**Requirement:**
Explanations must not blame users.

**Enforcement:**
- Manual review required
- Tone policy validation (neutral, caution, critical)

---

### Guarantee 4: Actionable or Explicitly Non-Actionable

**Requirement:**
Every explanation must be actionable OR explicitly non-actionable.

**Enforcement:**
- `actionable` field must be set
- `suggestedActions` must be non-empty if actionable=true
- Non-actionable entries must have rationale

---

## Explanation Audit Process

1. **Automated Checks (CI):**
   - Completeness (all fields present)
   - Uniqueness (no duplicate codes)
   - Consistency (severity ↔ actionable)
   - Coverage (all enum cases have entries)

2. **Manual Review (Required):**
   - User clarity
   - False blame risk
   - False certainty risk
   - Support escalation risk

3. **Risk Assessment:**
   - User confusion risk
   - Trust erosion risk
   - Support burden risk

4. **Approval:**
   - Platform architect approval required
   - Product manager approval recommended
   - Support team review recommended

---

## Example: Good Explanation Entry

```json
{
  "code": "PRC_CAPTURE_OCCLUDED",
  "category": "primary_reason",
  "severity": "caution",
  "shortLabel": "Hand or object occlusion",
  "userExplanation": "Some parts of the object were temporarily blocked from view during scanning, possibly by your hand or another object.",
  "technicalExplanation": "Temporary occlusion detected during capture, affecting coverage in specific regions.",
  "appliesTo": ["user_ui", "developer_logs"],
  "actionable": true,
  "suggestedActions": ["HINT_CLEAR_OCCLUSION", "HINT_CHANGE_ANGLE"],
  "meaningHash": "sha256_hash",
  "meaningChangeRequiresRFC": true,
  "tonePolicy": "neutral"
}
```

**Why this is good:**
- ✅ Clear, user-readable explanation
- ✅ Neutral tone (doesn't blame user)
- ✅ Actionable guidance provided
- ✅ Technical explanation for support
- ✅ Meaning hash for drift prevention

---

## Example: Bad Explanation Entry

```json
{
  "code": "PRC_CAPTURE_OCCLUDED",
  "category": "primary_reason",
  "severity": "critical",  // ❌ Too severe
  "shortLabel": "You blocked the object",  // ❌ Blames user
  "userExplanation": "Your hand was in the way.",  // ❌ Blames user, vague
  "technicalExplanation": "Occlusion detected.",  // ❌ Too brief
  "appliesTo": [],
  "actionable": false,  // ❌ Inconsistent with severity
  "suggestedActions": []  // ❌ No guidance
}
```

**Why this is bad:**
- ❌ Blames user
- ❌ Too severe for temporary issue
- ❌ No actionable guidance
- ❌ Vague explanation
- ❌ Inconsistent fields

---

**Status:** APPROVED FOR PR#1 v1.1.1  
**Enforcement:** CI + Manual Review  
**Audience:** Product managers, support team, developers  
**Purpose:** Ensure system never lies to users, never shows unexplained outputs, never erodes trust
