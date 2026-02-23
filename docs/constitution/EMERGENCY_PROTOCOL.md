# Emergency Protocol

**Document Version:** 1.0.0
**Created Date:** 2026-01-28
**Status:** IMMUTABLE (append-only after merge)
**Scope:** Production emergencies requiring constitution bypass

---

## §0 PURPOSE

This document defines **when and how** constitutional rules may be temporarily bypassed during genuine emergencies.

**Core Principle**: Constitution rules exist to prevent problems. But when production is on fire, we need a legal escape hatch that maintains accountability.

---

## §1 EMERGENCY CLASSIFICATION

### §1.1 Severity Levels

| Level | Name | Definition | Example |
|-------|------|------------|---------|
| E0 | CRITICAL | Production down, revenue loss, data loss risk | Server crash, payment failures |
| E1 | SEVERE | Major feature broken, significant user impact | Auth broken, uploads failing |
| E2 | MODERATE | Feature degraded, workaround exists | Slow performance, UI glitch |
| E3 | MINOR | Cosmetic issue, no functional impact | Wrong color, typo |

### §1.2 Bypass Eligibility

| Level | Constitution Bypass Allowed? |
|-------|------------------------------|
| E0 | Yes, with immediate post-fix |
| E1 | Yes, with 24-hour post-fix |
| E2 | No, use normal process |
| E3 | No, use normal process |

---

## §2 BYPASS AUTHORIZATION

### §2.1 Who Can Authorize

| Level | Authorizer |
|-------|------------|
| E0 | Any maintainer (can self-authorize if sole responder) |
| E1 | 2 maintainers (or 1 maintainer + 1 senior engineer) |

### §2.2 Authorization Record

Every bypass MUST be recorded:

```markdown
## Emergency Bypass Record

- **Bypass ID**: EB-YYYY-MM-DD-NNN
- **Level**: E0/E1
- **Authorized by**: @username
- **Time**: ISO8601 timestamp
- **Rules bypassed**: [List specific constitution sections]
- **Justification**: [1-2 sentences]
- **Tracking issue**: #NNN
```

---

## §3 BYPASS MECHANISM

### §3.1 Git Commit Format

Emergency commits MUST use this format:

```
EMERGENCY[E0]: Fix production crash in payment processing

BYPASS: CI_HARDENING_CONSTITUTION §1.1 (Date() used directly)
JUSTIFICATION: ClockProvider not available in hotfix branch
TRACKING: #1234
AUTHORIZED: @maintainer1
EXPIRES: 2026-01-30T00:00:00Z

[actual commit message]

Co-Authored-By: Claude <noreply@anthropic.com>
```

### §3.2 CI Bypass

For E0 only, CI checks may be skipped:

```bash
# Only for E0, with justification in commit message
git push --no-verify  # Skip pre-push hook

# In GitHub, use emergency label to skip required checks
# Requires admin permission
```

### §3.3 Bypass Tracking File

**File**: `docs/emergencies/ACTIVE_BYPASSES.md`

```markdown
# Active Emergency Bypasses

| Bypass ID | Level | Created | Expires | Rules | Issue | Status |
|-----------|-------|---------|---------|-------|-------|--------|
| EB-2026-01-28-001 | E0 | 2026-01-28 | 2026-01-30 | CI_HARD §1.1 | #1234 | ACTIVE |

## Resolution Queue

Bypasses MUST be resolved by expiry date or escalated.
```

---

## §4 RECOVERY REQUIREMENTS

### §4.1 Mandatory Recovery Timeline

| Level | Fix Deployed | Constitution Compliant | Post-mortem |
|-------|--------------|------------------------|-------------|
| E0 | ASAP | Within 48 hours | Within 7 days |
| E1 | Within 4 hours | Within 7 days | Within 14 days |

### §4.2 Recovery Commit

After emergency fix, a follow-up commit MUST:
1. Make the code constitution-compliant
2. Reference the bypass ID
3. Close the tracking issue

```
fix(emergency): Make payment fix constitution-compliant

Resolves emergency bypass EB-2026-01-28-001:
- Replaced Date() with ClockProvider injection
- Added missing tests

Closes #1234
```

### §4.3 Overdue Bypass Detection

CI MUST check for overdue bypasses daily:

```bash
#!/bin/bash
# scripts/check-overdue-bypasses.sh

TODAY=$(date -u +%Y-%m-%dT%H:%M:%SZ)

grep "| ACTIVE |" docs/emergencies/ACTIVE_BYPASSES.md | while read line; do
    EXPIRES=$(echo "$line" | cut -d'|' -f5 | tr -d ' ')
    if [[ "$TODAY" > "$EXPIRES" ]]; then
        BYPASS_ID=$(echo "$line" | cut -d'|' -f2 | tr -d ' ')
        echo "::error::OVERDUE BYPASS: $BYPASS_ID expired on $EXPIRES"
        exit 1
    fi
done
```

---

## §5 POST-MORTEM

### §5.1 Required Sections

Every E0/E1 post-mortem MUST include:

```markdown
# Post-Mortem: EB-YYYY-MM-DD-NNN

## Summary
[1-2 sentences]

## Timeline
| Time | Event |
|------|-------|
| ... | ... |

## Root Cause
[What actually broke and why]

## Constitution Rules Bypassed
| Rule | Why Bypassed | How Resolved |
|------|--------------|--------------|
| ... | ... | ... |

## Prevention
[What changes prevent recurrence]

## Action Items
- [ ] Item 1
- [ ] Item 2
```

### §5.2 Post-Mortem Storage

**Location**: `docs/emergencies/postmortems/EB-YYYY-MM-DD-NNN.md`

---

## §6 ABUSE PREVENTION

### §6.1 Abuse Indicators

| Indicator | Threshold | Action |
|-----------|-----------|--------|
| Bypasses per month | > 3 | Mandatory process review |
| Same rule bypassed | > 2 times | Rule may need amendment |
| Overdue recoveries | > 1 | Escalate to leadership |
| Missing post-mortems | Any | Block future bypasses for author |

### §6.2 Accountability

- All bypasses are logged permanently
- Bypass history is reviewed quarterly
- Repeat offenders lose self-authorization privilege

---

## §7 CHANGELOG

| Version | Date | Change |
|---------|------|--------|
| 1.0.0 | 2026-01-28 | Initial protocol |

---

**END OF DOCUMENT**
