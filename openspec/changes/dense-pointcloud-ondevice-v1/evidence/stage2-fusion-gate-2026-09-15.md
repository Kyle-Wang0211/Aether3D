# Evidence — Stage 2 fusion port, 2026-09-15

## Identity

- Sources (md5): dense_fuse.cc 23197b8e523d51b230e2e10cb5e363af, dense_fuse.h
  0b592b0b6cbe5560db5f5ff02d3bfd6d, test_fuse.cc cc0409e56302031c47e71a56def89346.
- Shipped iOS OpenCV archive libopencv_generic_4_0_1.a md5 7ade4bb9da9a5f2d0d7d28a726d52b93.
- Host toolchain: Apple clang 17.0.0 (clang-1700.6.3.2); `-std=c++20 -O2 -ffp-contract=off -fno-fast-math`.
- Reference: python3.11, numpy 2.4.6 (Accelerate); fixture fx_official 97×768×576, 9 sources; AB ep2 EXTNF_ABEP2.

## Remap kernel provenance

| item | finding |
|---|---|
| remapBilinear / interpolateLinear / initInterTab1D / initInterTab2D / RemapNoVec | 4.0.1 (device) vs 4.13.0 (wheel): identical except `isRelative` offset plumbing; 5.0.0 (opencv-pw) vs 4.13.0: identical |
| 32F path | `linear_tab[..][CV_32F] = remapBilinear<Cast<float,float>, RemapNoVec, float>` (imgwarp.cpp 4.13.0:1545); maps quantised by `cvRound(x*32)` (:1216-1222) |
| HAL | 4.0.1 `remap()` has no `CALL_HAL(remap…)`; carotene/tegra_hal.hpp has no remap; KleidiCV 0.7.0 `remap_f32` handles 8U/16U only, else `CV_HAL_ERROR_NOT_IMPLEMENTED` (kleidicv_hal.cpp:1435-1475) |

## Floating-point contraction

| object | FMA | fmul |
|---|---|---|
| iOS archive `imgwarp.o` (whole) | 0 | 833 |
| host opencv-401-build-mac `imgwarp.cpp.o` (whole) | 0 | 833 |
| iOS archive `remapBilinear<Cast<float,float>,RemapNoVec,float>` | 0 | 16 |
| pip wheel `cv2.abi3.so` 4.13.0 (whole, control) | 24,874 | 19,260 |

Random-data test (64×80, maps incl. borders): wheel remap == `fma(S3,w3,fma(S2,w2,fma(S0,w0,S1*w1)))`
100.0000 %; == pure float32 left-to-right 78.5547 %; on/off differ on 21.4453 % of pixels, max 9.5e-7.

## Arm vs ref_wheel (fp-contract=on reference; diagnostic only)

| stage (frame 0, sources s0/s1/s2) | differing |
|---|---|
| x_src, y_src (pre-remap, numpy only) | 0 / 0 / 0 — with C++ `lapack_inv`, mode 0, no injection |
| sampled (remap) | 22.08 % / 20.25 % / 21.88 %, max 3.6e-7 |
| mask | 0 / 0 / 1 |

Whole run: masks 25 / 42,909,696 differ (22 frames), geosum 179, points 22,021,292 vs 22,021,287.
Injecting numpy's inverses (`--inv-from`) changes nothing (same 25/179); mode 1 (FMA accumulate) leaves
x_src/y_src identical too. Conclusion: every difference originates in the wheel's contracted remap.

## Arm vs ref_off (the gate), run 1 — 10:12 (mode 0, C++ lapack_inv, no injection)

`ref_off` = official Python with cv2 4.13.0 rebuilt `-ffp-contract=off` (Custom HAL: NO; self-check:
cv2(off) == pure float32 left-to-right 100.0000 %). Reference points 22,021,292 (= C++).

| artifact | elements | differing |
|---|---|---|
| masks (u8) | 42,909,696 | 0 |
| geosum (i32) | 42,909,696 | 0 |
| davg (f64 bits) | 42,909,696 | 0 |
| col (u8) | 66,063,876 | 0 |
| xyz (f32 bits) | 66,063,876 | **1** (max abs 1.82e-12, one frame) |
| probe s0/s1/s2: x_src, y_src, sampled, depth_reproj, x_reproj, y_reproj, mask | 442,368 each | 0 |

Cross-check ref_wheel vs ref_off (FMA-only delta): masks 25, geosum 179, points 22,021,287 vs 22,021,292 —
identical to the C++-vs-wheel delta, i.e. the C++ sits exactly on the `off` side.

The single xyz element lives in the world back-projection `(xyz.T - t) @ R` (numpy → Accelerate dgemm):
a float64 accumulation-order difference that survives the float32 cast once in 66 M values. Resolved by the
float64-level probe below (accumulation mode measured, not guessed).

## float64-level probe — which accumulation reproduces numpy + Accelerate

Frames 0-2, pre-cast arrays (`x_src64/y_src64` = filter.py:38 before `.astype(float32)`; `xyz64` = world
points before the cast). Percent of float64 elements bit-identical to numpy:

| mode | x_src64 s0/s1/s2 | y_src64 s0/s1/s2 | xyz64 f0 / f1 / f2 |
|---|---|---|---|
| 0 `acc + a*b`, k↑ | 48.4 / 44.1 / 58.2 | 31.0 / 31.7 / 58.8 | 57.3 / 53.5 / 32.2 |
| 1 `fma(a,b,acc)`, k↑ | 64.0 / 54.0 / 72.8 | 46.2 / 42.1 / 38.9 | **100.0 / 100.0** / 35.1 |
| 2 `acc + a*b`, k↓ | 46.8 / 43.2 / 53.1 | 31.2 / 33.5 / 48.2 | 49.7 / 46.4 / 28.9 |
| 3 `fma(a,b,acc)`, k↓ | 48.5 / 43.5 / 56.2 | 30.3 / 29.4 / 51.0 | 39.4 / 38.6 / 28.3 |

No single pattern reproduces Accelerate's dgemm at the float64 level for every product shape (the reference
BLAS is itself platform-specific); those float64 residuals almost never survive the float32 casts the official
code performs. Mode 1 is the closest and is the one under which the whole float32 gate is clean.

## Arm vs ref_off (the gate), run 2 — 10:18, mode 1 (now the default), C++ lapack_inv, no injection

| artifact | elements | differing |
|---|---|---|
| masks | 42,909,696 | 0 |
| geosum | 42,909,696 | 0 |
| davg (f64 bits) | 42,909,696 | 0 |
| xyz (f32 bits) | 66,063,876 | 0 |
| col | 66,063,876 | 0 |
| probes s0/s1/s2 (7 arrays each) | | 0 |

**GATE PASS.** Points 22,021,292 (= reference). Digest of frames 0-7 (FNV-1a over the five artifacts):
`HALL 462447d96490ff94`; per-frame lines in `hash_0-7.txt`. The 8-frame sub-pack (26 unique views, 219 MB)
reproduces the same per-frame digests on the host, so the on-device run compares digests only.
Host wall time 11.7 s for 97 frames (single thread, M-series).

## On-device run — iPhone 14 Pro (A16), 10:20

App `com.kyle.casdifffusebench` (hand-rolled .app, 211 MB with the 8-frame sub-pack; dense_fuse + test_fuse
`-Dmain=fuse_run`, linked against the shipped `libopencv_generic_4_0_1.a`, `-ffp-contract=off -fno-fast-math`,
minos 26.2). Gates before launch: process list 298 / 298 lines (liveness, twice), product app not running.

| | host (M-series) | iPhone 14 Pro |
|---|---|---|
| frames 0-7 wall time | ~1.0 s | 1.0 s (DONE 15 s after launch incl. poll interval) |
| points (8 frames) | 2,471,581 | 2,471,581 |
| digest HALL | 462447d96490ff94 | 462447d96490ff94 |
| per-frame digests (8 × masks/geosum/davg/xyz/col) | | all identical |

**DEVICE == HOST == official Python.** Stage 2 is closed: the fusion the product will run on the phone is
bit-identical to the official `filter.py` path on the fixture.

## Stage 1 input-side gates (host, 2026-09-15 10:27-10:36)

| component | source copied | gate | result |
|---|---|---|---|
| dense_session | prep_phone_fixture.py:62-203 (fixture builder; defaults + FIX_NSRC=9 reproduce fx_official byte-for-byte) | cams.f32 + neighbors.i32 vs fx_official, 97 frames | identical |
| dense_inputs | pack_inputs.py (pm stages /8 /4 /2, linspace depth values) | pm1/pm2/pm3/dv blocks vs inputs8.bin, 8 frames | identical; fp16 round trip 0/4 M |
| dense_images | libjpeg-turbo 3.1.3 + Pillow 11.3.0 Resample.c/Convert.c verbatim | images.f16 vs fx_official (97), resized RGB vs Pillow (8) | identical |

## End-to-end chain on the iPhone 14 Pro from RAW inputs — 10:41 (`com.kyle.casdiffdensebench`, 462 MB app)

Inputs: 97 refined poses + intrinsics + 49,253 sparse points + 47 photos (4032×3024 JPEG) + reference noise;
refs 0-7 → 26 views inferred (ORT 1.29.0 WebGPU, fused AB ep2 graph) → fusion of 8 frames.

| stage | time |
|---|---|
| session table (97 frames, 49 k points) | 5.6 s |
| 47 photos decode + resize + grey f16 | 3.1 s |
| ORT session | 0.8 s |
| inference, 26 views | median 2002.6 ms/view, 54.2 s total |
| fusion, 8 frames | 1.4 s |
| total to DONE | 67.6 s (79 s incl. launch/poll) |
| peak memory (phys_footprint) | 1593 MB (bench hooks hold 224 MB of reference noise/depth the product path does not) |

Depth parity vs the host PyTorch reference over the 26 inferred views: non-finite 0, pixels >1 % 0.0071 %,
worst relative 7.1 % (same criteria and magnitude as the certified A16 bench). Fusion of the device-inferred
depths: 2,471,620 points vs 2,471,581 from the reference depths (+39, 0.0016 %) — ULP-level depth differences
flip a handful of threshold ties, as expected; the fusion code itself is the bit-exact one.

## Selection box — gates and device run (13:50-13:58)

| check | result |
|---|---|
| `BoxFilter.contains` vs `SelectionBox.contains` (Dart, `withYaw` 30°), 200,000 LCG points | 892 inside on both sides, 0 mismatches |
| frames seeing a 1.0×0.8×1.2 m box on fixture97 (C++ vs numpy with the fixture's visibility formula) | 96/97, identical lists |
| iPhone 14 Pro, box 0.4 m at (0.343, −0.146, −0.279), yaw 30° | 97 → 14 frames selected, 14 photos 0.9 s, 14 views 2003.8 ms median (28.1 s), fusion 1.6 s, 81,327 points, PLY read-back: 0 points outside, peak 1331 MB |
