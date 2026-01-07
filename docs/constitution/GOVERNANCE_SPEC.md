>Status: Informational
>Version: 1.0.0
>Authority: FP1 Constitution
>Change Control: RFC Required

# Governance Specification

**Version:** 1.0.0  
**Status:** Informational  
**Owner:** @kaidongwang  
**Generated:** 2026-01-07  
**Generator:** Cursor

**Status Note:** This document is Informational (not Binding). It provides provenance, meta-governance context, and routing information. Substantive governance rules reside in other constitutional documents.

## 1. Source and Authority

**Generation Source:**
- Prompt: PR#11 Constitutional Prompt v1.8
- Date: 2026-01-07
- Generator: Cursor

**Prompt Lifecycle:**

Prompt governed PR#11 generation phase only.

Post-merge: Repository documents govern (prompt becomes historical artifact).

Prompt has no operational authority post-merge.

**Prompt Preservation:**

Prompt content must be preserved via RFC for auditability.

Action required: File RFC within 90 days of PR#11 merge.

RFC archives prompt as docs/rfcs/RFC-<NNNN>-prompt-v1.8.md (owner assigns number).

**Prompt Supersession:**

Prompt is historical artifact.

Archiving via RFC is permitted but prompt is never superseded operationally (not part of runtime governance).

## 2. Closed World Limitation (CRITICAL)

**PR#11 Generation Constraints:**

The following apply ONLY to PR#11 file generation phase:

- File set closed (Section 2 of generation prompt)
- No modifications to scripts/, .github/workflows/, .gitignore
- No runtime or product logic
- No normative governance language promises for forbidden paths

**Post-Merge Transition:**

After PR#11 merge, governance document set becomes open.

Adding, modifying, or removing governance documents requires RFC.

This transition documented in all generated files where relevant.

**Closed World Documentation:**

Generated files must not contain language promising creation of:
- scripts/** files in PR#11
- .github/workflows/** files in PR#11
- .gitignore in PR#11

Permitted phrasing: "deferred to PR#12" or "protected for future governance".

## 3. Binding Documents (Current State)

### 3.1 Enforcement Layer
- CODEOWNERS (Binding via GitHub enforcement)

### 3.2 Constitutional Layer
- docs/constitution/GATES_POLICY.md (Status: Binding)
- docs/constitution/GOVERNANCE_SPEC.md (Status: Informational - this file)

**Directory Note:**

Location in docs/constitution/ does not determine binding status.

Status field in each document determines binding authority.

### 3.3 Process Layer
- CONTRIBUTING.md (Status: Binding)
- SECURITY.md (Status: Binding)

### 3.4 RFC Layer
- docs/rfcs/RFC-0000-template.md (Status: Template, non-binding)
- docs/rfcs/RFC-*.md with Status: Accepted (Binding)
- docs/rfcs/RFC-*.md with other Status (non-binding)

## 4. Governance Version Semantics

**Format:** X.Y.Z (Semantic Versioning)

- Major (X): Breaking structural changes
- Minor (Y): New rules or sections  
- Patch (Z): Non-substantive fixes per GATES_POLICY.md "Non-Substantive Changes" section

**Effective Date:**

Versions apply from merge commit timestamp (UTC).

Non-retroactive unless RFC explicitly specifies retroactive effect.

## 5. Priority Order (Routing SSOT)

**Primary Definition:**

GATES_POLICY.md "Priority Order" section contains authoritative hierarchy.

**Routing Function:**

This section provides routing information only.

Priority authority derives from GATES_POLICY.md by reference.

**Hierarchy (Reference):**

See GATES_POLICY.md "Priority Order" section for complete specification.

Higher-priority documents override lower without reconciliation.

## 6. Cross-Reference Standards

**Valid References:**

All governance documents must maintain valid cross-references:
- Referenced file paths must exist
- Referenced section titles must exist

**Preferred Format:**

Title-based references (more stable):
```
Per GATES_POLICY.md "RFC Reference Format" section
```

Discouraged but permitted:
```
Per GATES_POLICY.md Section 4
```

**Detection and Correction:**

Broken reference detection: First CI failure OR manual discovery.

Detection timestamp: First CI failure (from logs) OR issue creation time (manual).

Note: Issue creation time detection is manual (not machine-checkable).

Correction deadline: 7 days from detection (UTC).

Correction PR: Does not require RFC if limited to fixing reference integrity.

## 7. Change Control

**Changes Requiring RFC:**

All changes to docs/constitution/** require RFC.

**Exception (No RFC Required):**

Changes matching GATES_POLICY.md "Non-Substantive Changes" section allowlist.

**Allowlist Reference:**

See GATES_POLICY.md "Non-Substantive Changes" section for complete specification.

Do not duplicate allowlist content here (SSOT principle).

**Ambiguous Cases:**

Owner classifies per GATES_POLICY.md allowlist boundaries.

Default: RFC-required unless clearly in allowlist.

## 8. Audit Trail

**Governance Changes Tracked Via:**
- Git commit history (immutable record, SHA-256 content addressing)
- RFC trail (docs/rfcs/ with Status field state machine)
- Emergency log (EMERGENCY commit messages with INC- identifiers)

**Timestamp Standards:**

All timestamps per GATES_POLICY.md "Timestamp Standards" section.

## 9. Related Operational Documents

**Non-Governance Documents:**

The following documents inform but do not bind governance:
- docs/ROLLBACK.md (operational guidance if exists)
- docs/WORKFLOW.md (historical if exists)
- docs/WHITEBOX.md (product spec if exists)
- docs/PHASES.md (project planning if exists)

**Conflict Resolution:**

Governance documents supersede operational documents.

Priority: Per GATES_POLICY.md "Priority Order" section.

## 10. Implementation Notes (Non-Normative)

**CI Implementation Timeline:**

Most machine checks specified in PR#11 are implemented in PR#12.

Specifications are normative (SSOT for behavior).

Implementation scripts are non-normative (one possible realization).

**Manual Enforcement Items:**

The following require manual enforcement or GitHub API (not pure repo checks):
- Owner activity detection (30-day frozen state trigger)
- Security Advisories enablement verification
- Branch protection settings verification
- Issue creation timestamp detection

These are documented as operational requirements (manual configuration).

