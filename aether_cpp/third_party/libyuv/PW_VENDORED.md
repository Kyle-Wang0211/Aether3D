# libyuv — vendored copy (openspec change `dense-lossless-speedup-v1`, task 2.1)

Plain directory, **not** a git submodule (`.gitmodules` belongs to another line and was not touched).

| | |
|---|---|
| Upstream | https://chromium.googlesource.com/libyuv/libyuv |
| Commit | `2dd4257364d39c38d79465c4ddc4b93137fe729b` |
| Commit date | 2026-09-11 05:56:04 -0700 (committer date); author date 2026-08-10 09:45:29 +0100 |
| Commit subject | `AArch64: Fix HalfMergeUVRow_SVE2 average calculation` |
| `LIBYUV_VERSION` | 1971 (`include/libyuv/version.h`) |
| Vendored on | 2026-09-16 |
| License | BSD-3-Clause (`LICENSE`) + additional IP rights grant (`PATENTS`); contributors in `AUTHORS` |

## What was copied

`include/` (whole tree), `source/*.cc` (52 files; `source/test.sh` skipped), `LICENSE`, `AUTHORS`, `PATENTS`,
`README.md`. **Not** copied: `unit_test/`, `util/`, `tools_libyuv/`, `docs/`, `infra/`, build files
(`BUILD.gn`, `CMakeLists.txt`, `Android.bp`, …), `DEPS`, `.git`.

## Why

The archived-photo path of the on-device dense pipeline (proposal "方案甲"): PWVA-owned captures are decoded
from HEVC to **full-range NV12** and must become 8-bit RGB for the existing
`pil_resize_bilinear_rgb → pil_rgb_to_l → gray_to_f16` chain. Previously the Dart layer re-encoded each frame to
JPEG q0.95 with ImageIO and decoded it again — Apple-only, serial, two lossy generations. libyuv is the
cross-platform (iOS / Android / HarmonyOS, NEON + SSE + runtime dispatch) canonical YUV library used by Chromium
and Android, so the colour conversion is *its* code and *its* constants, not ours.

Entry point used by the product — `aether_cpp/src/dense/dense_images.cc`, `load_frame_rgb()`:

```
libyuv::NV21ToRGB24Matrix(y, w, uv, w, rgb, w*3, k, w, h)
  k = &libyuv::kYvuJPEGConstants   // nv12_matrix 0 = BT.601 full range (source/row_common.cc:1613-1629)
  k = &libyuv::kYvuF709Constants   // nv12_matrix 1 = BT.709 full range (source/row_common.cc:1667-1683)
```

That call **is** libyuv's own `NV12ToRAWMatrix` — the macro at `include/libyuv/convert_argb.h:57-58` expands to
`NV21ToRGB24Matrix(..., <constants>VU, ...)`, and `include/libyuv/convert_argb.h:46-51` maps `kYuvXConstantsVU`
to `kYvuXConstants`. We call the underlying function directly only because the macro pastes the constant *name*
and our matrix is chosen at run time. libyuv's fixed-matrix entry point does the identical thing with the
limited-range constants: `source/convert_argb.cc:4768-4778`
`NV12ToRAW(...) { return NV21ToRGB24Matrix(..., &kYvuI601Constants, ...); }`.
"RAW" is R,G,B in memory and "RGB24" is B,G,R (upstream `docs/formats.md:174`), which is why the destination-side
name looks swapped; `RgbImage::rgb` is R,G,B.

## Source files the PRODUCT compiles

Determined empirically: every `source/*.cc` was compiled into one archive and the NV12→RGB probe was linked with
`-Wl,-why_load`, so this is the exact archive-member closure, not a guess.

**All targets (7):**

```
source/convert_argb.cc
source/cpu_id.cc
source/planar_functions.cc
source/row_any.cc
source/row_common.cc
source/scale_any.cc
source/scale_common.cc
```

**arm64 (iOS device, Android arm64-v8a, HarmonyOS arm64) — add:**

```
source/row_neon64.cc     compile with -march=armv8.2-a+dotprod+i8mm
source/scale_neon64.cc   compile with -march=armv8.2-a+dotprod+i8mm
source/row_sve.cc        compile with -march=armv8.5-a+i8mm+sve2
```

**x86_64 (iOS simulator, Android x86_64 emulator, Intel macOS host) — add:**

```
source/row_gcc.cc
source/scale_gcc.cc
```

(32-bit ARM, if it ever comes back: `source/row_neon.cc` + `source/scale_neon.cc` with `-mfpu=neon` and
`-DLIBYUV_NEON`. Not needed for any current target.)

## Defines / flags

* Product flags are unchanged: `-std=c++20 -O2 -ffp-contract=off -fno-fast-math`
  (`pw-dense-stage/vendor/pw_dense/scripts/build_xcframeworks.sh:43-44`). libyuv needs nothing added to them.
* Include path: `-I aether_cpp/third_party/libyuv/include`.
* **No `-DLIBYUV_NEON`.** That define is only for 32-bit ARM; on arm64 NEON is auto-detected via `__aarch64__`
  (`include/libyuv/row.h:589`), and so is SVE2 (`include/libyuv/row.h:622`). Dispatch is at run time
  (`TestCpuFlag`, `include/libyuv/cpu_id.h:80`), so an i8mm/SVE2-less phone simply takes the plain NEON/C row.
* The two `-march=` flags above are **per-file** (upstream does the same: `CMakeLists.txt` targets
  `yuv_neon64` / `yuv_sve`). They are required to *assemble* the inline asm in those files; the code they guard
  is still selected by run-time CPU detection.
* **SME:** upstream enables it only on `__aarch64__ && __linux__ && clang>=18` (`include/libyuv/cpu_support.h:93-96`).
  On iOS/macOS it is therefore off and `row_sme.cc` / `rotate_sme.cc` / `scale_sme.cc` are **not** in the closure.
  On **Android** (which defines `__linux__`) with NDK clang ≥ 18 they *would* enter the closure — so the Android
  build must either add those three files with `-march=armv8.5-a+i8mm+sme` **or** pass `-DLIBYUV_DISABLE_SME`.
  Recommendation: `-DLIBYUV_DISABLE_SME` on Android (SME is irrelevant to the phones we ship to and it keeps the
  three platforms' file list identical).
* `-DLIBYUV_DISABLE_SVE` is the equivalent escape hatch if a toolchain cannot assemble `row_sve.cc`; it drops that
  file from the closure at the cost of the SVE2 kernels on ARMv9 Android parts.
* `HAVE_JPEG` is **not** defined, so `convert_jpeg.cc` / `mjpeg_*.cc` compile to nothing and never pull in
  libjpeg. (Not in the closure anyway.)

## Test-only

`aether_cpp/src/dense/test_images.cc --nv12-roundtrip` additionally uses `RAWToARGB`
(`source/convert_argb.cc:3734`) + `ARGBToNV12Matrix` (`source/convert_from_argb.cc:406`) with
`kArgbJPEGConstants` / `kArgbF709Constants` (`source/row_common.cc:1512-1524`, `:1540-1552`) to *build* the NV12
fixture, i.e. the exact inverse of the product call. That drags in more of libyuv (`convert.cc`,
`convert_from_argb.cc`, …), so the host test links the whole vendored tree; the product does not.
