# Learned-Feature Extraction (XFeat / ALIKED) — Assessment & Decision

Status: **ASSESSMENT** (2026-06-22). Stage 4 of the extraction speedup explored
swapping DSP-SIFT for a learned detector+descriptor (one CNN forward pass instead
of the ~115k-pass CPU/GPU DSP loop). Conclusion up front: **this is a high-risk
PIVOT, not a speedup of the current pipeline — recommend parking it as a
contingency, not pursuing now.**

## The candidates (commercial-OK only)
| Model | License | Notes |
|---|---|---|
| **XFeat** | **Apache-2.0** ✅ | Designed for speed/mobile; ~lightweight CNN. Descriptor 64-D (vs SIFT 128-D). |
| **ALIKED** | **BSD-3** ✅ | Heavier; deformable-conv (CoreML-hostile, cf. BiRefNet's 15-round deform_conv saga). |
| SuperPoint | **NON-COMMERCIAL** 🚩 | disqualified |
| DISK | research-encumbered 🚩 | avoid |
| ORB (OpenCV) | BSD ✅ | free + fast but quality << SIFT; not a quality route |

## Why it is a PIVOT, not a speedup
The whole downstream is tuned for DSP-SIFT and would be invalidated by a different
feature:
- **GPU matcher** (shipped, 119ms): brute-force L2 on 128-D uint8 RootSIFT with
  Lowe ratio 0.7. XFeat is 64-D float with a different distribution → the matcher,
  the ratio threshold, and the cross-check all change.
- **COLMAP geometric verification** thresholds (RANSAC inlier counts, E/F/H ratios,
  the RelPoseFilter min_inlier_num=30 / ratio=0.25) are calibrated to SIFT match
  statistics → learned-feature matches behave differently → re-tune.
- **All the grounded numbers** (the K-sweep, connectivity floors K≥6/8, reproj
  0.933px @4224, 0.943 @2048) were measured with DSP-SIFT → a new feature means
  re-running the ENTIRE 50-frame bench + re-deriving K + re-validating reproj.
- So this is **end-to-end pipeline re-validation with an UNCERTAIN quality
  outcome**, not a localized speedup behind a stable C-ABI (unlike the GPU port,
  which preserves DSP-SIFT bit-for-bit-close).

## The speed prize is real but UNVALIDATED on the target
- Potential: one CoreML forward pass on the ANE could be ~10× (5.4s → sub-500ms)
  IF it genuinely runs on the ANE. But the only published embedded XFeat number is
  ~1.8 FPS (~550ms) at 480×360 on a weak Cortex-A CPU — **no iPhone/ANE number
  exists**, and our resolution is 2048/4224, far larger.
- CoreML conversion is itself a multi-round effort (project precedent: BiRefNet
  needed ~15 rounds + 6 patches; VGGT 5 patches). No official CoreML export for
  XFeat/ALIKED → PyTorch→CoreML conversion required, ANE-op-coverage unknown.
- The decisive unknown (ANE speed at our resolution) **can only be answered by a
  device spike** — which is exactly what an overnight, device-less session cannot
  resolve.

## Decision framework
Pursue XFeat ONLY if BOTH cheaper paths fail to make extraction tractable:
1. **CPU threading (stages 1-2, shipped, bit-identical)** + the 2048@K6 route
   (reproj 0.943, only 1.1% off 4224's 0.933, imperceptible to DA3): 2048
   extraction 5.4s → ~3.5s threaded. Possibly already acceptable behind a
   capture-overlap + short post-capture processing phase (Polycam/KIRI norm).
2. **GPU DSP-SIFT port (stage 3, designed)**: targets 2-3s/frame @4224 while
   PRESERVING the proven 0.933px quality (no re-validation, stable C-ABI).

Both preserve quality. XFeat trades the proven quality for raw speed with an
unproven ANE payoff and a full pipeline rebuild. **Recommendation: do NOT pursue
XFeat now. Revisit only if the GPU port stalls AND 2048-threaded is still too slow
for the product.** If revisited, the FIRST step is a device-only spike: convert
XFeat to CoreML and measure ANE latency at 2048 — answer the speed question before
sinking any pipeline-integration effort.

## If/when pursued — the staged spike (device-gated)
1. Convert XFeat → CoreML (coremltools), force ANE compute units, measure latency
   at 2048 on iPhone 14 Pro. **GO/NO-GO gate: < 1s/frame on ANE.** (No-go → stop.)
2. Wire XFeat keypoints/descriptors into a parallel C-ABI; re-tune the GPU matcher
   for 64-D float + the ratio threshold; greedy-NN recall vs DSP-SIFT.
3. Re-run the 50-frame COLMAP bench: re-derive K, require reproj ≤ ~0.95px /
   50-of-50. If quality regresses materially → XFeat is not a quality route.

## Licenses
XFeat Apache-2.0 ✅, ALIKED BSD-3 ✅, ONNX Runtime MIT ✅, coremltools BSD-3 ✅.
Avoid SuperPoint (NC) / DISK (research-encumbered).
