# Execution tasks

## 1. Stage 2 — fusion in C++ with a byte gate

- [x] 1.1 Provenance: filter.py/fuse_official.py line map; OpenCV remap kernel diff
  4.0.1/4.13.0/5.0.0; HAL non-interception (4.0.1 no CALL_HAL, carotene none,
  KleidiCV 8U/16U only); device archive flags (`-ffp-contract=off`), FMA audit.
- [x] 1.2 Reference producer `fuse_ref_dump.py` (official calls only) → per-frame
  artifacts + input pack + numpy inverses + frame-0 stage probe.
- [x] 1.3 `dense_fuse.{h,cc}` + `test_fuse.cc` + CMake target `aether_dense_fuse_test`;
  host build against OpenCV 4.0.1 (`-ffp-contract=off`).
- [x] 1.4 Arm vs `ref_wheel`: x_src/y_src bit-identical (C++ inverse, mode 0);
  first divergence is `sampled` (wheel FMA, ≤3.6e-7); masks differ 25/42.9M,
  points 22,021,292 vs 22,021,287.
- [x] 1.5 Build `cv2` 4.13.0 `-ffp-contract=off`; regenerate `ref_off`; production
  arm bit-identical — **GATE PASS** 2026-09-15 10:18 (mode 1; mode 0 had left one xyz
  element in 66 M differing by one float32 ULP — evidence file).
- [x] 1.6 Cross-compiled for iOS arm64 against `libopencv_generic_4_0_1.a`; 8-frame
  sub-pack run on the iPhone 14 Pro in `com.kyle.casdifffusebench` (liveness +
  product-not-running gates, 300 s cap): per-frame digests identical to the host,
  2,471,581 points, 1.0 s for 8 frames — 2026-09-15 10:20.

## 2. Stage 1 — product runner

- [x] 2.0a Session table (`dense_session.{h,cc}`): line-by-line port of prep_phone_fixture.py
  (q2R, K scaling, projection visibility, MVSNet scoring θ0=5/σ1=1/σ2=10 + 6 cm baseline,
  nearest fill, p2·0.70 / p99.5·1.50 depth range via numpy's linear percentile and
  pairwise_sum). Gate: cams.f32 + neighbors.i32 byte-identical to fx_official (97 frames,
  9 sources) — 2026-09-15 10:27. Provenance pinned first: the script with default flags +
  FIX_NSRC=9 reproduces fx_official's cams/neighbors/images.f16 byte-for-byte.
- [x] 2.0b Model inputs (`dense_inputs.{h,cc}`): pm_stage1..3 + depth_values from the camera
  row (pack_inputs.py). Gate: byte-identical to inputs8.bin blocks for 8 frames; fp16
  round trip 0 mismatches over 4 M image samples.

- [x] 2.0c Photos (`dense_images.{h,cc}`): libjpeg-turbo 3.1.3 (the pinned submodule) decode +
  Pillow 11.3.0 Resample.c ported verbatim (BILINEAR, antialias, 22-bit fixed point) + Convert.c
  rgb2l + float32/255 + float16. Gate: images.f16 byte-identical to fx_official (97 photos)
  and resized RGB byte-identical to Pillow (8 photos) — 2026-09-15 10:36.
- [x] 2.1 Runner + pipeline (`dense_runner`, `dense_fuse_pack`, `dense_pipeline`): ORT-WebGPU
  session (bench_main.cc recipe), per-view inference written to an on-disk pack, session
  released, fusion from the pack. On the iPhone 14 Pro from raw inputs: 26 views at
  2002.6 ms median, parity ✅, 8 frames fused to 2,471,620 points (ref 2,471,581), peak
  1593 MB — 2026-09-15 10:41 (evidence file).
- [x] 2.2 Product integration built and assembled (2026-09-15 11:00; install awaits the user's order): `pwdense_c.{h,cc}` C ABI (5 exported symbols)
  → `PWDense.xcframework` (device: dense C++ + OpenCV 4.0.1 archive + libjpeg-turbo + model inside the
  framework; simulator: stub) + `PWOnnxRuntime.xcframework` (the ORT 1.29.0 dylib re-homed), vendored as
  `vendor/pw_dense` (podspec) in worktree `~/Developer/pw-dense-stage` (branch `feat/dense-stage` =
  shipping line pw-head-0827 5939197 + its uncommitted diffs). Dart: `lib/dense/pw_dense_ffi.dart`
  (opened by path like PWOfficialSfm, worker isolate, NativeCallable progress), `native_dense_stage_launcher.dart`
  (implements the existing `DenseStageLauncher` seam; inputs copied from sparse_meta.json / sidecars /
  fed frames / sparse PLY; archived photos materialised via PhotoArchiveResolver), `dense_stage_progress.dart`;
  registered in main.dart; viewer shows a progress/result bar and opens `official_dense.ply` in the same viewer.
  Selection (user requirement 2026-09-15 13:4x, "未被选中的部分就不用进入稠密点云"): `BoxFilter` = the app's
  `SelectionBox.contains()` copied verbatim (gate: 200,000 points vs the Dart class, 0 mismatches); only frames that
  see ≥1 sparse point inside the box are used, the certified session recipe unchanged on that subset (gate: subset
  identical to a numpy expectation on fixture97); fused points outside the box are dropped before the PLY.
  Device: 97 frames → 14 selected → 14 views inferred (28.1 s), 81,327 points, PLY read-back 0 outside, peak 1331 MB.
  Install form: baseline Runner-156 + App.framework swap + the two frameworks → `Runner-157-dense-stage.app`
  (ledger entry written; self-checks: only App differs, four untouched binaries byte-identical after
  signature strip, five exported symbols, model md5 0932f6ce…, codesign --deep --strict OK).
- [x] 2.2b Installed 2026-09-15 15:12 as `Runner-159-dense-stage.app` on top of the on-device 158 (branch rebased onto
  158's source 2fe229a; five gates passed; 29 sessions intact; not launched). 157 was never installed.
- [x] 2.2c Incident: 159's viewer page went black — the idle progress bar was a non-Positioned SizedBox.shrink
  in a loose Stack of Positioned children (Stack collapsed to 0×0). Fixed by an always-Positioned
  `DenseProgressBar` + widget test with a negative control; `Runner-160-dense-stage-fix.app` installed
  2026-09-15 20:39 over 159 (gates passed, 29 sessions intact, not launched).
- [x] 2.2d Incident 2 (build 160): the job never started — the Isolate.run closure captured the caller's
  ReceivePort ("object is unsendable"). Fixed by spawning from a scope holding only the args; host test
  crosses the isolate boundary with a progress callback. UI rebuilt as DenseStagePanel (spinner, phase,
  elapsed, weighted progress bar, done/failed states) + stateful bottom pill; 6/6 dense tests green.
- [x] 2.3 Functional arm: build 161, capture cap_1789381704918369 (21 photos, 12,122 sparse points) → 下一步 →
  58.2 s, 21 views inferred (2399 ms median), fusion 3.4 s, **6,922,990 points**, official_dense.ply 99 MB.
- [x] 2.4 Incident 3: the Dart-canvas review viewer froze on 6.9 M points (per-frame projection + sort of every
  point) and the process died. Fix (build 162): Potree default point budget 1,000,000 — the viewer shows the
  first 1 M points of the progressive octree order (uniform), the PLY stays full; tests green.
- [ ] 2.5 User's eyes on the dense cloud in the viewer (build 162), then the full-capture timing table. open a finished capture's sparse preview, tap 下一步, watch progress, view
  official_dense.ply; pull the device log for `DenseStage available=true` and the `DenseStage end` line.
- [ ] 2.3 On-device end-to-end on a fresh capture (not the fixture), user's eyes.
