# Design: Stage 2 — official fusion in C++, gated byte-for-byte

## Context

Reference chain (the truth the port must reproduce):
`fuse_official.py` per-frame loop → official `filter.py::check_geometric_consistency`
→ `reproject_with_depth` → `cv2.remap(..., INTER_LINEAR)`. Inputs: fixture
`fx_official` (97 frames, 768×576, 9 sources per frame) and the AB ep2 prediction
`bench_baseline/EXTNF_ABEP2` (depth + conf0..2). Reference output: 22,021,287 points.

## Decisions

### 1. Copy the library, do not replicate it

`filter.py:41` calls OpenCV's `remap`. The C++ calls `cv::remap` — the identical
kernel, not a re-implementation:

- The iPhone product links `vendor/xrslam/libs/ios-arm64/libopencv_generic_4_0_1.a`
  (`ios/Runner.xcodeproj/project.pbxproj:470`); it exports `cv::remap` and contains
  `remapBilinear<Cast<float,float>,RemapNoVec,float>`.
- `remapBilinear`, `interpolateLinear`, `initInterTab1D/2D`, `RemapNoVec` are
  identical (diff, whitespace-insensitive) between OpenCV 4.0.1 (device), 4.13.0
  (pip wheel) and 5.0.0 (opencv-pw), apart from 4.13's `isRelative` offset
  plumbing which is inert for absolute maps. Kernel: `imgwarp.cpp` 4.13.0
  :615-843; fixed-point map conversion `cvRound(x*32)` :1216-1222; float path
  dispatch `linear_tab[..][CV_32F]` :1545.
- No HAL can intercept the 32F path: 4.0.1 `remap()` has no `CALL_HAL(remap…)`
  at all; carotene (Android default) has no remap hook; the pip wheel's KleidiCV
  0.7.0 `remap_f32` only handles 8U/16U sources and falls back
  (`adapters/opencv/kleidicv_hal.cpp:1435-1475`, `kleidicv_hal.h:439-452`).

### 2. Rounding contract: `-ffp-contract=off` on every end, including the reference

Measured 2026-09-15: the pip `cv2` 4.13.0 (Apple clang 15, default
`-ffp-contract=on`) computes the bilinear sum as
`fma(S3,w3, fma(S2,w2, fma(S0,w0, S1*w1)))` (100.0000 % match on random data);
pure float32 left-to-right matches only 78.55 %. Every device OpenCV is built
with `-ffp-contract=off` (`android_ready/native/xrslam/build_generic_core.sh:127`;
opencv-pw `docs_fp_contract.md`; host `opencv-401-build-mac` CMakeCache). FMA
audit of the shipped iOS archive's `imgwarp.o`: FMA 0 / fmul 833, identical to the
host object; `remapBilinear<float>` alone: FMA 0 / fmul 16; the wheel `.so` as the
"on" control: FMA 24,874. Therefore the reference is regenerated with a `cv2`
built from the same 4.13.0 tag with `-ffp-contract=off` (`~/Developer/opencv-4130-pyoff`);
the wheel-based reference is kept only to quantify the FMA-only difference.

### 3. numpy float64 stages are double, float32 casts stay where numpy casts

`reproject_with_depth` is ported statement by statement (see line comments in
`dense_fuse.cc`). `numpy.linalg.inv` = LAPACK `?gesv(A, I)`; the port carries a
verbatim-structure port of reference `dgetf2` + `dgetrs`. Whether this and the
plain `acc + a*b` matmul reproduce numpy+Accelerate is **measured**, not
assumed: on the fixture the pre-remap maps `x_src`/`y_src` (float32) are
bit-identical for all probed sources, with the C++ inverse and without injection.
Accumulation pattern is switchable (`g_fuse_matmul_mode`) and an injection arm
(`--inv-from`) isolates the inverse; both exist only as gate instruments.

### 4. Gate

`test_fuse <pack> <out>` writes `masks/ geosum/ davg/ xyz/ col/` per frame exactly
as `fuse_ref_dump.py` does; `fuse_gate_compare.py` compares bit patterns (NaN-safe)
and the frame-0 stage probe (`x_src, y_src, sampled, depth_reproj, x_reproj,
y_reproj, mask`). Verdict = zero differing elements against the `off` reference.

### 5. Platform notes

iOS: link the already-shipped 4.0.1 archive; no new dependency. Android: the
`android_ready` 4.0.1 build uses the same flags; carotene does not hook remap.
Threading: `cv::remap` splits rows deterministically; results do not depend on
the parallel backend.
