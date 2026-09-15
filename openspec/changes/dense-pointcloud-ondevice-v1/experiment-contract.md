# Experiment contract — Stage 2 fusion byte gate

## Frozen identity

- Official code: cvg/diffmvs HEAD `cd10d5c`, `tools/python/diffmvs/filter.py`
  (research repo), `fuse_official.py` (experiments/casdiffmvs_blendmvg_scratch_2026-08-16/tools).
- Fixture: `_host_experiments.nosync/phone_cap_20260811/fx_official` (frames.json
  count 97, 768×576, num_src 9; cams.f32 NF×36; neighbors.i32 97×9).
- Prediction: `bench_baseline/EXTNF_ABEP2` (AB ep2, 97 × depth/conf0/conf1/conf2, 576×768 f32).
- Parameters: `geo_mask_thres=3`, `geo_pixel_thres=1.0`, `geo_depth_thres=0.01`,
  photometric thresholds 0.3/0.5/0.5.
- C++: `aether_cpp/src/dense/dense_fuse.{h,cc}`, `test_fuse.cc`; Apple clang 17
  (`clang++ --version` recorded in the evidence file); `-std=c++20 -O2
  -ffp-contract=off -fno-fast-math`; OpenCV 4.0.1 host build
  `~/Developer/opencv-401-build-mac` (`CMAKE_CXX_FLAGS=-ffp-contract=off`,
  `WITH_LAPACK=OFF`, `BUILD_LIST=core,imgproc,video,features2d,flann`).
- Reference: python3.11, numpy 2.4.6 (Accelerate BLAS/LAPACK),
  (a) pip `opencv-python` 4.13.0 wheel (KleidiCV 0.7.0 HAL, clang 15, fp-contract on)
  → `ref_wheel`; (b) self-built OpenCV 4.13.0 `-ffp-contract=off`, `WITH_LAPACK=OFF`,
  no HAL (`~/Developer/opencv-4130-pyoff`) → `ref_off`.

## Verdict rule

- Production arm = `--mode 0`, C++ `lapack_inv`, no injection.
- PASS ⇔ every element of masks (u8), geosum (i32), davg (f64 bits), xyz (f32
  bits), col (u8) and every probe array is identical to `ref_off`. No tolerance.
- `ref_wheel` vs `ref_off` is reported as the FMA-only delta and grants nothing.
- Any mismatch: locate the first differing stage with the probe, fix, rerun;
  never widen the gate.

## Out of scope for this contract

Speed, memory and the physical phone. Host results grant no production credit;
the on-device run of the same harness on the same pack is a separate task.
