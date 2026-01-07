# Security Policy

**Version:** 1.0.0  
**Status:** Binding  
**Owner:** @kaidongwang

## 1. Vulnerability Reporting

**Primary Channel (Canonical Repository - Manual Configuration):**

Use repository Security Advisories feature.

Access: Repository → Security tab → Advisories

**Enablement Requirement (Operational - Manual):**

Security Advisories must be enabled in canonical repository.

Configuration method: Repository settings (not code PR).

If disabled when vulnerability reported:
- Owner enables within 24h (UTC from report timestamp)
- Enablement is manual repository configuration

**Fork Policy:**

Forks: Not required to enable Security Advisories (non-enforceable guideline).

PRs from forks to canonical: Must follow canonical security policy.

**Response Timeline:**

Maximum 48 hours to acknowledgment (UTC from report timestamp).

## 2. Credential Handling

**Prohibited Actions:**
- Committing API keys
- Committing secrets
- Committing credentials

**Detection Response (Emergency Trigger Mapping):**

Credential commit triggers API_KEY_LEAK emergency per GATES_POLICY.md "Emergency Triggers" section.

Required actions:
1. EMERGENCY response commit (per GATES_POLICY.md "Emergency Commit Format" section)
2. Immediate key rotation
3. Rotation deadline: 24h from incident commit (UTC)
4. Incident RFC: 48h from incident commit

**Special Privilege:**

EMERGENCY: API_KEY_LEAK commits permitted to modify:
- SECURITY.md (document response)
- .gitignore (exclude from future commits)

Other governance files require RFC per GATES_POLICY.md "Emergency File Allowlist" section.

## 3. Credential Rotation Policy

**Timeline:**
- Rotation: 24h from detection (UTC)
- Emergency override: Per GATES_POLICY.md "Emergency Override" section
- Post-rotation RFC: 48h from detection (UTC)

**Timestamp Source:**

All timestamps per GATES_POLICY.md "Timestamp Standards" section.

Command: `git log --format=%cI`

## 4. Excluded Files

**Requirement Applicability:**

This requirement is established when .gitignore is next modified or during emergency event.

PR#11 does not create or modify .gitignore (closed world constraint).

Post-merge: When .gitignore exists or is modified, it must include:

- `.env`
- `*.key`
- `*.pem`
- `*_secret.*`
- `*.credentials`

**Emergency Context:**

Emergency credential response is permitted to create/modify .gitignore per GATES_POLICY.md "Emergency File Allowlist" section.

## 5. Related Documents

**Rollback Procedures:**

If docs/ROLLBACK.md exists: Provides operational rollback guidance.

If ROLLBACK.md does not exist: Emergency procedures per GATES_POLICY.md "Emergency Override" section.

**Governance Framework:**

All security governance subject to GATES_POLICY.md.

Conflict resolution: Per GATES_POLICY.md "Priority Order" section.

