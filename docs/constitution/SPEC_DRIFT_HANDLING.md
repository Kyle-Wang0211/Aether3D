# Spec Drift Handling Protocol

**Document Version:** 1.0.0
**Created Date:** 2026-01-28
**Status:** IMMUTABLE (append-only after merge)
**Scope:** All PRs where implementation differs from initial plan

---

## §0 CORE PRINCIPLE

**Plan constants are hypotheses. SSOT constants are truth.**

Initial plans (like "MAX_DURATION=120s") are educated guesses made before implementation. During implementation, engineers discover reality:
- Physical constraints (device limits, API behaviors)
- User needs (real-world usage patterns)
- Safety margins (edge case protection)

This document establishes **legal, auditable drift** from plan to implementation.

---

## §1 WHAT IS SPEC DRIFT?

### §1.1 Definition

**Spec Drift** occurs when:
```
Plan Value ≠ Implemented SSOT Value
```

### §1.2 Examples from This Project

| PR | Constant | Plan Value | SSOT Value | Drift Type |
|----|----------|------------|------------|------------|
| PR#1 | MAX_FRAMES | 2000 | 5000 | Relaxed |
| PR#1 | SFM_REGISTRATION_MIN | 0.60 | 0.75 | Stricter |
| PR#1 | PSNR_MIN | 20.0 dB | 30.0 dB | Stricter |
| PR#2 | States | 8 | 9 | Extended (+C-Class) |
| PR#2 | Transitions | 15 | 14 | Corrected |
| PR#4 | MIN_DURATION | 10s | 2s | Relaxed |
| PR#4 | MAX_DURATION | 120s | 900s | Relaxed |
| PR#4 | MAX_SIZE | 2GB | 2TiB | Massively Relaxed |
| PR#5 | LAPLACIAN_THRESHOLD | 100 | 200 | Stricter |
| PR#5 | LOW_LIGHT_BRIGHTNESS | 30 | 60 | Stricter |

---

## §2 DRIFT CLASSIFICATION

### §2.1 Drift Categories

| Category | Definition | Risk Level | Approval |
|----------|------------|------------|----------|
| **STRICTER** | New value rejects more inputs | LOW | Self-approval |
| **RELAXED** | New value accepts more inputs | MEDIUM | Peer review |
| **EXTENDED** | New enum case / new state added | MEDIUM | Peer review |
| **CORRECTED** | Plan was mathematically wrong | LOW | Self-approval |
| **BREAKING** | Changes existing behavior | HIGH | RFC required |

### §2.2 Risk Assessment Matrix

| Drift Affects | STRICTER | RELAXED | EXTENDED | CORRECTED | BREAKING |
|---------------|----------|---------|----------|-----------|----------|
| Local-only (one module) | ✅ Safe | ✅ Safe | ✅ Safe | ✅ Safe | ⚠️ RFC |
| Cross-module | ✅ Safe | ⚠️ Review | ⚠️ Review | ✅ Safe | ⚠️ RFC |
| Cross-platform (iOS↔Server) | ⚠️ Review | ⚠️ Review | ⚠️ Review | ⚠️ Review | 🚨 RFC |
| API contract | 🚨 RFC | 🚨 RFC | 🚨 RFC | ⚠️ Review | 🚨 RFC |
| Billing/pricing | 🚨 RFC | 🚨 RFC | 🚨 RFC | 🚨 RFC | 🚨 RFC |
| Security boundary | 🚨 RFC | 🚨 RFC | 🚨 RFC | 🚨 RFC | 🚨 RFC |

---

## §3 DRIFT REGISTRATION (MANDATORY)

### §3.1 Drift Registry File

**File**: `docs/drift/DRIFT_REGISTRY.md`

Every spec drift MUST be registered. Format:

```markdown
# Spec Drift Registry

## Active Drifts

| ID | PR | Constant | Plan | SSOT | Category | Reason | Impact | Date |
|----|----|---------|----- |------|----------|--------|--------|------|
| D001 | PR#1 | MAX_FRAMES | 2000 | 5000 | RELAXED | 15-min video needs more frames | Local | 2026-01-XX |
| D002 | PR#1 | SFM_REGISTRATION_MIN | 0.60 | 0.75 | STRICTER | Quality guarantee | Local | 2026-01-XX |
| ... | ... | ... | ... | ... | ... | ... | ... | ... |

## Drift Count by PR

| PR | STRICTER | RELAXED | EXTENDED | CORRECTED | BREAKING | Total |
|----|----------|---------|----------|-----------|----------|-------|
| PR#1 | 2 | 1 | 0 | 0 | 0 | 3 |
| PR#2 | 0 | 0 | 1 | 1 | 0 | 2 |
| PR#4 | 0 | 3 | 0 | 0 | 0 | 3 |
| PR#5 | 2 | 0 | 0 | 0 | 0 | 2 |
```

### §3.2 Registration Process

1. **Discover drift** during implementation
2. **Classify** using §2.1 categories
3. **Assess risk** using §2.2 matrix
4. **Register** in DRIFT_REGISTRY.md with:
   - Unique ID (D001, D002, ...)
   - PR number
   - Constant name (SSOT ID)
   - Plan value (from original plan doc)
   - SSOT value (actual implementation)
   - Category
   - Reason (1-2 sentences)
   - Impact scope
   - Date
5. **Update** PR's Contract/Executive Report with drift reference
6. **If cross-platform/API/billing/security** → Create RFC

---

## §4 DRIFT APPROVAL WORKFLOW

### §4.1 Self-Approval (STRICTER, CORRECTED, Local)

```
Developer discovers drift
    │
    ▼
Register in DRIFT_REGISTRY.md
    │
    ▼
Update Contract/Executive Report
    │
    ▼
Include in PR description
    │
    ▼
Done (no additional approval needed)
```

### §4.2 Peer Review (RELAXED, EXTENDED, Cross-module)

```
Developer discovers drift
    │
    ▼
Register in DRIFT_REGISTRY.md
    │
    ▼
Update Contract/Executive Report
    │
    ▼
Add "DRIFT REVIEW" label to PR
    │
    ▼
Require 1 additional reviewer approval
    │
    ▼
Done
```

### §4.3 RFC Required (Cross-platform, API, Billing, Security, BREAKING)

```
Developer discovers drift
    │
    ▼
STOP implementation
    │
    ▼
Create RFC in docs/rfcs/
    │
    ▼
RFC review (minimum 3 business days)
    │
    ▼
RFC approval by 2+ maintainers
    │
    ▼
Register in DRIFT_REGISTRY.md with RFC link
    │
    ▼
Update ALL affected contracts
    │
    ▼
Continue implementation
```

---

## §5 DRIFT DOCUMENTATION IN PR

### §5.1 PR Description Template

Every PR with drift MUST include:

```markdown
## Spec Drift Declaration

This PR contains **{N}** spec drifts from the original plan:

| Drift ID | Constant | Plan → SSOT | Category | Reason |
|----------|----------|-------------|----------|--------|
| D0XX | {NAME} | {OLD} → {NEW} | {CAT} | {REASON} |

**Cross-platform impact**: None / Yes (see RFC-XXX)
**API contract impact**: None / Yes (see API_CONTRACT.md update)
**Billing impact**: None / Yes (see RFC-XXX)

All drifts registered in `docs/drift/DRIFT_REGISTRY.md`.
```

### §5.2 Contract/Executive Report Update

Add drift section:

```markdown
## Spec Drift from Plan

| Drift ID | Constant | Plan | SSOT | Reason |
|----------|----------|------|------|--------|
| D0XX | ... | ... | ... | ... |

All values in this document reflect SSOT (implementation truth), not plan (initial hypothesis).
```

---

## §6 TRUTH HIERARCHY

When conflicts arise, this is the resolution order:

```
1. SSOT Constants File (Core/Constants/*.swift)     ← ULTIMATE TRUTH
2. Contract/Executive Report (with drift section)   ← Documented truth
3. Drift Registry (docs/drift/DRIFT_REGISTRY.md)    ← Historical record
4. Original Plan Document                           ← Historical hypothesis
```

**Rule**: If code and docs disagree, code wins. Then fix docs.

---

## §7 ANTI-PATTERNS

### §7.1 Forbidden Practices

| Anti-Pattern | Why Bad | Correct Approach |
|--------------|---------|------------------|
| Changing SSOT without registering drift | Invisible change, audit failure | Register in DRIFT_REGISTRY |
| Keeping plan value in comments "for reference" | Confusion about truth | Remove or mark as `HISTORICAL` |
| Multiple sources for same constant | SSOT violation | Consolidate to one source |
| Drift without updating contract doc | Doc-code desync | Update contract in same PR |
| Undocumented "temporary" relaxation | Permanent tech debt | Register or don't do it |

### §7.2 Detection

CI SHOULD warn on:
- Constants in comments that differ from SSOT
- Multiple definitions of same constant name
- Contract docs older than SSOT file (mtime check)

---

## §8 EXAMPLES

### §8.1 Good Drift Declaration

```markdown
## PR#4 Spec Drift Declaration

This PR contains **3** spec drifts:

| Drift ID | Constant | Plan → SSOT | Category | Reason |
|----------|----------|-------------|----------|--------|
| D010 | MIN_DURATION | 10s → 2s | RELAXED | User testing showed 10s too restrictive for quick scans |
| D011 | MAX_DURATION | 120s → 900s | RELAXED | Pro users need longer recordings for large objects |
| D012 | MAX_SIZE | 2GB → 2TiB | RELAXED | Future-proofing for 8K video, current HW can't hit this |

**Cross-platform impact**: None (client-only constants)
**API contract impact**: None (not sent to server)
**Billing impact**: None (recording limits don't affect pricing)
```

### §8.2 Bad Drift (Anti-Pattern)

```swift
// BAD: Undocumented drift
public static let maxDuration: TimeInterval = 900 // was 120 in plan, changed because reasons

// GOOD: Properly documented
/// Maximum recording duration.
/// - SSOT: 900 seconds (15 minutes)
/// - Drift: D011 (RELAXED from plan value 120s)
/// - Reason: Pro users need longer recordings
public static let maxDuration: TimeInterval = 900
```

---

## §9 CHANGELOG

| Version | Date | Change |
|---------|------|--------|
| 1.0.0 | 2026-01-28 | Initial protocol |

---

**END OF DOCUMENT**
