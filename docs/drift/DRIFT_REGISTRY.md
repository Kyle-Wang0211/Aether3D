# Spec Drift Registry

**Last Updated**: 2026-02-07
**Total Drifts**: 15

---

## Active Drifts

| ID | PR | Constant | Plan | SSOT | Category | Reason | Impact | Date |
|----|----|---------|----- |------|----------|--------|--------|------|
| D001 | PR#1 | SystemConstants.maxFrames | 2000 | 5000 | RELAXED | 15-min video at 2fps needs up to 1800 frames, 5000 provides headroom | Local | 2026-01-28 |
| D002 | PR#1 | QualityThresholds.sfmRegistrationMinRatio | 0.60 | 0.75 | STRICTER | Higher quality bar ensures reliable 3D reconstruction | Local | 2026-01-28 |
| D003 | PR#1 | QualityThresholds.psnrMinDb | 20.0 | 30.0 | STRICTER | Industry standard for acceptable visual quality | Local | 2026-01-28 |
| D004 | PR#2 | ContractConstants.STATE_COUNT | 8 | 9 | EXTENDED | Added CAPACITY_SATURATED for PR1 C-Class | Cross-module | 2026-01-28 |
| D005 | PR#2 | ContractConstants.LEGAL_TRANSITION_COUNT | 15 | 14 | CORRECTED | Actual legal transitions after analysis | Local | 2026-01-28 |
| D006 | PR#4 | CaptureRecordingConstants.minDurationSeconds | 10 | 2 | RELAXED | User testing showed 10s too restrictive | Local | 2026-01-28 |
| D007 | PR#4 | CaptureRecordingConstants.maxDurationSeconds | 120 | 900 | RELAXED | Pro users need longer recordings | Local | 2026-01-28 |
| D008 | PR#4 | CaptureRecordingConstants.maxBytes | 2GB | 2TiB | RELAXED | Future-proofing for 8K video | Local | 2026-01-28 |
| D009 | PR#5 | FrameQualityConstants.blurThresholdLaplacian | 100 | 200 | STRICTER | 2x industry standard for quality guarantee | Local | 2026-01-28 |
| D010 | PR#5 | FrameQualityConstants.darkThresholdBrightness | 30 | 60 | STRICTER | Better dark scene handling | Local | 2026-01-28 |
| D011 | PR-PROGRESS | PipelineRunner.timeout | 180s hard | stall-based (300s no-progress + 7200s absolute) | RELAXED | 180s incompatible with 900s max recording | Cross-module | 2026-02-07 |
| D012 | PR-PROGRESS | Polling backoff for queued | Fixed 5s interval | Exponential backoff (5s → 10s → 20s) | EXTENDED | Battery optimization for queued jobs | Local | 2026-02-07 |
| D013 | PR-PROGRESS | Worker lease token | None | `jobs.worker_lease_token` column | EXTENDED | Ownership gating for concurrent workers | Cross-module | 2026-02-07 |
| D014 | PR-PROGRESS | Progress audit retention | No audit table | `progress_audit_events` table (7-day retention) | EXTENDED | Observability enhancement for progress tracking | Local | 2026-02-07 |
| D015 | PR-PROGRESS | Swift 6.2 CI job | Swift 5.x only | Swift 6.2 CI job (non-blocking) | EXTENDED | Migration preparation for Swift 6.2 concurrency | Local | 2026-02-07 |

---

## Drift Count by PR

| PR | STRICTER | RELAXED | EXTENDED | CORRECTED | BREAKING | Total |
|----|----------|---------|----------|-----------|----------|-------|
| PR#1 | 2 | 1 | 0 | 0 | 0 | 3 |
| PR#2 | 0 | 0 | 1 | 1 | 0 | 2 |
| PR#3 | 0 | 0 | 0 | 0 | 0 | 0 |
| PR#4 | 0 | 3 | 0 | 0 | 0 | 3 |
| PR#5 | 2 | 0 | 0 | 0 | 0 | 2 |
| PR-PROGRESS | 0 | 1 | 4 | 0 | 0 | 5 |
| **Total** | **4** | **5** | **5** | **1** | **0** | **15** |

---

## Drift Statistics

- **Most drifts by category**: EXTENDED (5), STRICTER (4), RELAXED (5)
- **Most drifts by PR**: PR-PROGRESS (5), PR#4 (3), PR#1 (3)
- **Cross-platform drifts**: 2 (D004, D013)
- **RFCs required**: 0
- **Breaking changes**: 0

---

## Notes

All drifts in this registry have been:
1. Classified per SPEC_DRIFT_HANDLING.md §2
2. Assessed per risk matrix
3. Approved per workflow (self/peer/RFC)
4. Documented in respective PR Contract/Executive Reports

---

**END OF REGISTRY**
