>Status: Binding
>Version: 1.0.0
>Authority: FP1 Constitution
>Change Control: RFC Required

# Gate Policy

**Version:** 1.0.0  
**Status:** Binding  
**Owner:** @kaidongwang  
**Effective From:** Merge commit timestamp (UTC)

## 1. Priority Order (Routing SSOT)

In case of conflict between governance documents:

**Priority Hierarchy:**

1. This document (GATES_POLICY.md)
2. Accepted RFCs
   - Explicit "Superseded by" declarations in superseded RFC
   - If no explicit declaration, later merge timestamp prevails
3. CONTRIBUTING.md
4. CODEOWNERS
5. SECURITY.md
6. GOVERNANCE_SPEC.md

Higher-priority document overrides lower without reconciliation.

**Interpretation Authority:**

Machine-checkable rules are authoritative (not subject to interpretation).

Owner interprets ambiguous text where machine verification is impossible.

## 2. Gate Set (Closed Definition)

### 2.1 Gate Structure (Four-Field Model)

Each gate defined by exactly four fields:

- **GateKey:** Unique identifier (Gate1-6, closed set)
- **GateName:** Human-readable name
- **Classification:** Enforcement category (Blocking or NonBlocking)
- **TestFile:** Test filename (if Tests/Gates/ exists)

**Derivation Prohibition:**

Table values are authoritative.

Deriving GateKey, GateName, or Classification from filenames is forbidden.

TestFile matching verifies file existence only.

CI implementation must verify against table, not derive from filenames.

### 2.2 Gate Definitions Table

| GateKey | GateName | Classification | TestFile |
|---------|----------|----------------|----------|
| Gate1 | PolicyHash | Blocking | PolicyHashGateTests.swift |
| Gate2 | StateAssignment | Blocking | StateAssignmentGateTests.swift |
| Gate3 | GoldenTrace | NonBlocking | GoldenTraceTests.swift |
| Gate4 | Determinism | Blocking | DeterminismGateTests.swift |
| Gate5 | ReplayHash | NonBlocking | ReplayHashTests.swift |
| Gate6 | SchemaCompat | NonBlocking | SchemaCompatTests.swift |

**Closed Set Rule:**

No other GateKey identifiers exist.

Adding gates requires RFC modifying this table.

### 2.3 Classification Vocabulary (SSOT)

**Normative Keywords (Exact Case, Consistent Usage):**

- `Blocking` (not "blocking", "BLOCKING", or "Blocking gates")
- `NonBlocking` (not "Non-Blocking", "non-blocking", "NonBlocking gates")

Use consistently in:
- Table Classification column
- Policy-canonical block
- All enforcement text
- All governance documents

**Natural Language Exception:**

Lowercase in descriptive prose where not used as classification keyword is permitted.

Example permitted: "when blocking gates fail" (lowercase, descriptive).

Example forbidden: "Classification: blocking" (lowercase, normative).

### 2.4 Gate Enforcement States

**State Definitions:**

- **Active-Required:** CI must check; failure blocks merge
- **Active-Warning:** CI must check; failure warns only
- **Deferred:** CI skips check; state documented

**Bootstrap State (PR#11):**

All gates default to Deferred state until Tests/Gates/ directory is created.

PR#11 defines policy only.

Enforcement begins after activation (post-PR#11).

**Activation Requirement:**

When Tests/Gates/ is introduced, that PR must:
- Include all 6 test files from table (exact filenames)
- Reference RFC authorizing activation (per "RFC Reference Format" section)
- Use PR title format: `[RFC-NNNN] <description>`

Activation is NOT exempt from RFC requirement.

Activation without RFC is governance violation requiring revert.

**Activation RFC Content:**

Activation RFC must:
- Reference this section by title: "Gate Definitions Table"
- Declare intent to activate gate enforcement
- NOT require bypass frontmatter (activation is not bypass)

### 2.5 Golden Policy Hash

**Canonical Source:**

```policy-canonical
Gate1:PolicyHash:Blocking|Gate2:StateAssignment:Blocking|Gate4:Determinism:Blocking|Gate3:GoldenTrace:NonBlocking|Gate5:ReplayHash:NonBlocking|Gate6:SchemaCompat:NonBlocking
```

**Content Rules:**

- Must contain exactly one line (the canonical string above)
- Must NOT contain `#` character anywhere between fence markers
- Must NOT contain blank lines
- Must NOT contain any other content
- Ordering is normative (independent of table row order)

**Ordering Rationale:**

Blocking gates first (1, 2, 4), then non-blocking (3, 5, 6).

This ordering is normative and independent of table presentation.

**Hash Computation Algorithm (SSOT):**

```
1. Extract content between ```policy-canonical and closing ```
2. Verify exactly one non-empty line exists (fail if 0 or >1)
3. Verify no `#` characters in extracted line
4. Trim leading/trailing whitespace from line
5. Compute: SHA256(UTF8(normalized_line))
6. Output as lowercase hexadecimal
```

Line ending normalization: Use LF before hashing (CRLF converted to LF).

Character encoding: UTF-8; canonical block uses ASCII subset only.

CI implementation in PR#12 uses this algorithm.

## 3. RFC-Required Changes

**Enumerated Actions Requiring RFC:**

1. Changing any gate Classification keyword
2. Changing any gate enforcement state (Active ↔ Deferred)
3. Modifying any character inside policy-canonical fence (including comments)
4. Adding, removing, or renaming GateKey identifiers
5. Modifying enforcement semantics or CI failure conditions

**Non-Substantive Changes (Allowlist - No RFC Required):**

Limited to changes OUTSIDE canonical fence:
- Single-word spelling corrections (typos)
- Punctuation fixes (commas, periods only)
- Metadata updates (Version, dates) not affecting substantive rules

**Canonical Fence Protection:**

Any character change between policy-canonical fence markers triggers RFC requirement.

No exceptions.

CI must verify fence content line count equals 1.

**Ambiguous Classification:**

Owner determines substantive vs non-substantive per allowlist boundaries.

Changes affecting enumerated triggers above are substantive by definition.

Default: RFC-required unless clearly in allowlist.

## 4. RFC Reference Format (SSOT)

**PR Title Requirement:**

Must match regex: `^\[RFC-\d{4}\]\s+`

Example: `[RFC-0042] Update gate policy`

RFC number must be exactly 4 digits (zero-padded).

**PR Body Requirement:**

Must contain exactly one line matching regex: `^RFC:\s*RFC-\d{4}\b`

Example valid line:
```
RFC: RFC-0042
```

Surrounding text before/after this line is permitted.

Multiple RFC reference lines are forbidden (CI must fail if >1 match).

**Both Required:**

PR title AND body must satisfy respective requirements.

**Consistency Requirement:**

RFC number in title must match RFC number in body (CI must verify).

Example violation: Title `[RFC-0005]` but body `RFC: RFC-0006` (forbidden).

**Reference Resolution:**

Referenced RFC file must:
1. Exist in docs/rfcs/ on main branch
2. Have filename matching RFC-NNNN-*.md pattern
3. Contain `**Status:** Accepted` in metadata

CI verifies existence and status (implementation in PR#12).

**RFC Applicability:**

This format applies when:
- RFC is required (per enumerated triggers), OR
- PR invokes RFC bypass mechanism

Non-RFC governance PRs (non-substantive changes) are not required to use this format.

## 5. Emergency Override

### 5.1 Emergency Triggers (Exhaustive Enum - SSOT)

Valid triggers forming closed set:

- **API_KEY_LEAK:** Credential exposure requiring immediate rotation
- **LEGAL:** Legal mandate with hard external deadline < 48h
- **DATA_BREACH:** Active security incident with ongoing risk

**Explicitly Excluded (Not Emergencies):**

- CI system failure
- Build failures
- Deadline pressure
- Performance issues
- User complaints
- Test flakiness

### 5.2 Approval Authority

All emergency overrides approved by: @kaidongwang

### 5.3 Emergency Commit Format (SSOT)

**Required Format:**

```
EMERGENCY: <TRIGGER> / Gate<N> / INC-<YYYYMMDD>-<NNN>

Example:
EMERGENCY: API_KEY_LEAK / Gate1 / INC-20260107-001
```

**Component Rules:**
- TRIGGER: Must be one of Section 5.1 values (exact case)
- Gate<N>: Single gate number (1-6), format Gate<digit>
- INC-<YYYYMMDD>-<NNN>: Incident ID
  - Date: UTC, format YYYYMMDD
  - Sequence: Zero-padded 3-digit number

**Format Validation:**

CI must verify format compliance (implementation in PR#12).

Malformed emergency commits do not grant override privileges.

### 5.4 Emergency Scope

**Single Gate Rule:**

Each emergency commit targets one gate only.

Multi-gate emergency requires RFC authorization.

**Emergency File Allowlist (Post-Merge Governance):**

EMERGENCY commits permitted to modify:
- SECURITY.md (document security response)
- .gitignore (exclude credentials from future commits)

EMERGENCY commits forbidden to modify:
- CODEOWNERS
- GATES_POLICY.md (this file)
- CONTRIBUTING.md
- GOVERNANCE_SPEC.md
- Other docs/constitution/** files
- Other docs/rfcs/** files
- scripts/**
- .github/workflows/**

**Broader Changes:**

For changes beyond allowlist, file RFC within 24h per Section 5.6.

**PR#11 Closed World Note:**

Emergency allowlist applies post-merge only.

PR#11 does not create or modify .gitignore.

### 5.5 Emergency Closure (Mandatory)

**Deadline:** 24 hours from emergency commit timestamp (UTC).

**Closure Commit Format:**

```
EMERGENCY_CLOSE: INC-<YYYYMMDD>-<NNN> / Gate<N> re-enabled
```

**If Re-Enable Impossible:**

RFC filed within 24h containing:
- Incident ID reference
- Reason re-enable failed
- Updated timeline (maximum 7 days from original emergency)
- Mitigation plan

### 5.6 Emergency Frequency Limit

**Rule:**

More than 1 emergency per 30-day rolling window constitutes governance incident.

**Window Calculation:** 30 × 24 hours from previous EMERGENCY commit timestamp.

**Incident Response:**

- Minor (2 emergencies): Short RFC appendix (300+ non-whitespace characters)
- Major (3+ emergencies): Full incident postmortem RFC with all 6 sections

### 5.7 Timestamp Standards (SSOT)

**All Governance Timestamps:**

Use git committer date in UTC (ISO 8601 format).

**Standard Command:**

```bash
git log --format=%cI -- <file_or_path>
```

**Specific Applications:**

- Emergency timestamps: Committer date of EMERGENCY commit
- Closure deadline: 24h from above timestamp
- RFC merge timestamp: Committer date of merge commit adding RFC to main
- Sunset calculation: Based on RFC merge timestamp
- Cross-reference detection: First CI failure timestamp (from CI logs)

## 6. RFC Bypass Mechanism

### 6.1 Bypass Eligibility (Strict)

**PR invokes RFC bypass if it references RFC that:**

1. Exists on main branch (not in PR itself)
2. Has `**Status:** Accepted` in metadata
3. Contains valid bypass frontmatter (Section 6.2)

**Bypass Timing Restriction:**

RFC must be merged to main and Status changed to Accepted BEFORE bypassing PR.

Simultaneous merge (RFC acceptance and bypass invocation in same commit) is NOT supported.

**Rationale:**

Ensures machine-checkable verification without PR-time GitHub API calls.

CI implementation (PR#12) verifies by reading main branch files.

### 6.2 RFC Bypass Frontmatter Specification

**Location Requirement:**

YAML frontmatter must start at line 1 of RFC file (no content before opening `---`).

**Required Format:**

```yaml
---
bypass:
  gates: [Gate1, Gate2]
  sunset: 2026-12-31
---
```

**Field Rules:**

- `gates`: Array of GateKey values from table (must match exactly)
- `sunset`: Date in YYYY-MM-DD format (ISO 8601 date only)

**Field Constraints:**

- Gates array: Must be non-empty, de-duplicated, GateKey values only
- Gates array: Sorted for consistency preferred (not enforced)
- Sunset: Must not be earlier than RFC merge date (CI warns if violated)

**Frontmatter Precedence:**

YAML frontmatter is authoritative over prose in RFC body.

Claims of bypass in RFC prose without frontmatter are not recognized.

**No Frontmatter = No Bypass:**

RFC without valid frontmatter does not enable gate bypass.

### 6.3 RFC Bypass Sunset (SSOT)

**Maximum Duration:**

30 days from RFC merge commit timestamp.

**Merge Commit Identification:**

First commit on main branch containing RFC file with Status: Accepted.

Command:
```bash
git log --format=%cI --diff-filter=A -- docs/rfcs/RFC-NNNN-*.md | head -1
```

For modified status: Use commit timestamp when Status changed to Accepted.

**CI Verification:**

CI must verify: `current_date_utc <= sunset_date`

Implementation: PR#12 CI script.

**Expired Bypass:**

If sunset has passed, RFC bypass is invalid and CI must fail.

### 6.4 Bypass Enforcement Truth Table

| Gate State | Check | RFC Valid | Sunset Valid | CI Verdict |
|------------|-------|-----------|--------------|------------|
| Active-Required | Pass | N/A | N/A | Pass |
| Active-Required | Fail | Yes | Yes | Pass (bypass) |
| Active-Required | Fail | Yes | No | **Fail** (expired) |
| Active-Required | Fail | No | N/A | **Fail** |
| Active-Warning | Fail | N/A | N/A | Warn |
| Deferred | N/A | N/A | N/A | Skip |

## 7. CI Configuration Changes

**Gate Logic Definition (SSOT):**

Changes to .github/workflows/** require RFC if they modify:
- References to Tests/Gates/** paths
- Gate keyword detection (GateName values from table)
- Bypass verification logic
- Enforcement failure conditions

**Detection Method:**

File changes under .github/workflows/ containing strings:
- Any GateName from table (PolicyHash, StateAssignment, etc.)
- Path string "Tests/Gates"
- String "bypass"
- String "RFC-"

**Non-Gate Changes (No RFC):**

CI changes NOT matching above definition do not require RFC.

Examples: linting rules, formatting, matrix configuration, caching, dependencies.

## 8. Governance States

### 8.1 Normal

All governance rules apply without exception.

### 8.2 Frozen (Manual Enforcement)

**Entry:** 30 days no owner activity.

**Owner Activity Signals:**
- Commit to main branch
- PR approval (GitHub "Approve" action)
- PR merge to main

**Detection:** Manual/operational (requires GitHub activity tracking).

**Rules During Frozen:**

Forbidden:
- All governance changes
- All core changes
- RFC acceptance (Draft creation is permitted for preparation only)
- Normal PR merges

Permitted:
- EMERGENCY commits per Section 5 (limited to allowlist files)

**Exit:** Any owner activity signal from list above.

### 8.3 Superseded Rules

**Binding Transition:**

Superseded RFC loses binding authority when:
- Superseding RFC explicitly declares effective date, OR
- Explicit removal via subsequent RFC

**Binding Until Removal:**

Without explicit effective date, superseded RFC remains binding until:
- Removal PR merges
- Superseding RFC specifies transition

**Audit Trail:**

Superseded RFCs remain in repository for audit trail.

**Status Field:**

Superseded RFC must update to:
- `**Status:** Superseded`
- `**Superseded by:** RFC-NNNN`
- `**Effective Until:** <commit_sha>` (optional, defines end of binding period)

**Multiple Supersessions:**

If multiple RFCs claim to supersede same RFC:
- "Superseded by" field in original RFC is authoritative
- If original RFC does not declare, later merge timestamp prevails
- Owner resolves conflicts if timestamps equal

**RFC Number Priority:**

RFC numbers do NOT imply supersession priority.

Only explicit "Superseded by" declarations create supersession relationships.

## 9. Cross-Reference Requirements

**Valid References:**

Governance documents must maintain valid cross-references:
- Referenced file paths must exist
- Referenced section headings must exist (title-based, not number-based)

**Reference Format (Preferred):**

Use section titles, not numbers:
```
Per GATES_POLICY.md "RFC Reference Format" section
```

Avoid:
```
Per GATES_POLICY.md Section 4
```

**Rationale:** Title-based references are more stable under document reorganization.

**Defect Handling:**

Broken reference detection: First CI failure OR issue creation (whichever earlier, UTC).

Correction deadline: 7 days from detection.

Correction PR: Does not require RFC if limited to fixing reference integrity.

## 10. Violation Handling

**Non-Malicious Violations:**

Intent is irrelevant for detection and correction requirement.

Violation must be corrected before merge.

Correction is mandatory regardless of intent.

**Bad Faith Compliance:**

Actions that are formally compliant but defeat governance intent constitute violations.

Intent becomes relevant for severity determination and response choice.

Owner adjudicates bad faith cases.

**Emergency Violations:**

EMERGENCY commits (per Section 5.3) exempt from normal requirements during 24h window.

Follow-up correction required per Section 5.5.

