>Status: Binding
>Version: v1.3.10
>Authority: FP1 Constitution
>Change Control: RFC Required

# Audit Specification

This document defines audit requirements and procedures.

---

## Progress Audit Events (Phase 2)

**Status:** Phase 2 (Planned, Not Required for Phase 1)

### Phase 1 Behavior

- Progress updates written directly to `jobs` table
- No separate audit table required
- Basic logging sufficient for Phase 1

### Phase 2 Requirements

**Audit Table:**
- `progress_audit_events` table must exist
- Records all significant progress state changes
- Separate from `jobs` table (read-only audit trail)

**Events to Audit:**

1. **Stage Transitions:**
   - When `progress_stage` changes (e.g., `sfm` → `train`)
   - Record: `old_stage`, `new_stage`, `timestamp`, `job_id`

2. **Significant Progress Jumps:**
   - When `progress` increases by >= 5% in single update
   - Record: `old_percent`, `new_percent`, `delta`, `timestamp`, `job_id`

3. **Stall Detection Triggers:**
   - When stall detection logic triggers (no progress for 5 minutes)
   - Record: `last_progress_value`, `last_progress_time`, `stall_detected_at`, `job_id`

**Retention Policy:**
- Audit events retained for 7 days
- After 7 days, events may be archived or deleted
- Archive format: JSON or compressed database dump

**Rationale:**
- Enables post-mortem analysis of progress reporting issues
- Provides observability into pipeline behavior
- Supports debugging of stall detection false positives/negatives

