# Spec Drift Registry

**Last Updated**: 2026-01-28
**Total Drifts**: 10

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

---

## Drift Count by PR

| PR | STRICTER | RELAXED | EXTENDED | CORRECTED | BREAKING | Total |
|----|----------|---------|----------|-----------|----------|-------|
| PR#1 | 2 | 1 | 0 | 0 | 0 | 3 |
| PR#2 | 0 | 0 | 1 | 1 | 0 | 2 |
| PR#3 | 0 | 0 | 0 | 0 | 0 | 0 |
| PR#4 | 0 | 3 | 0 | 0 | 0 | 3 |
| PR#5 | 2 | 0 | 0 | 0 | 0 | 2 |
| **Total** | **4** | **4** | **1** | **1** | **0** | **10** |

---

## Drift Statistics

- **Most drifts by category**: STRICTER (4), RELAXED (4)
- **Most drifts by PR**: PR#4 (3), PR#1 (3)
- **Cross-platform drifts**: 1 (D004)
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
