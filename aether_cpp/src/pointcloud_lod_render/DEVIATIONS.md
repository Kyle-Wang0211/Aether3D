# Point-cloud LOD viewer — sources, deviations, verification

This module is **moved code plus interface glue**. Nothing algorithmic is new.

| Part | Source | Revision | Licence |
|---|---|---|---|
| Render pass: `Pipe`, `MakePipe`, `LodFrame`, `Upload`, `EvictGpu`, `ResetLod`, `BuildVisibleNodeTable`, `LodByte`, `CpuGetLOD`, WGSL (`lod_render.cpp`) | PWLodBench `pw_splat_ab_bench/Sources/lod/pw_lod_bench.cpp` (in-house, Mac-verified) | `b792d57`, file sha256 `50af752c…` | ours |
| Quad point path inside that WGSL | `bench_cloud.mm` `kWgslCloud` (in-house), render state as the production splat pass | — | ours |
| Adaptive point size, `getLOD`, visible-node table | `potree/potree` `src/materials/shaders/pointcloud.vs` :158-175, :183-210, :216-254, :301-303, :666-705, **:690-692 (ortho, R6)**; `src/PointCloudOctree.js` :321-391; `src/PotreeRenderer.js` :1232-1233, :1237-1240, :1293-1300, :815, :730; `src/materials/PointCloudMaterial.js` :32-34 | `5636cd471d9e` | BSD-2-Clause (text in `../pointcloud_lod/upstream_licenses/potree.LICENSE`, reproduced in `lod_render.cpp`'s header and `m1_bench/NOTICE`) |
| Orthographic node size (selection) | `CesiumGS/cesium` `packages/engine/Source/Scene/Cesium3DTile.js` :943-954 — see `../pointcloud_lod/DEVIATIONS.md` D17 | `113c068e9af3` | Apache-2.0 (`../pointcloud_lod/upstream_licenses/cesium.LICENSE.md`) |
| Orthographic test matrix (tests only) | `mrdoob/three.js` `src/math/Matrix4.js` :1200-1244 `makeOrthographic`, WebGPU branch | `6101189ee28b` | MIT |
| C ABI shape | house: `include/aether/pocketworld/scene_iosurface_renderer.h:40-190` (opaque handle; create / load / set / render / destroy) | this repo | ours |
| Render thread + ring hand-off (plan 3b / B1) | **shape only, no code copied**: `flutter/packages` `packages/camera/camera_avfoundation/.../DefaultCamera.swift` :28-31, :1283-1296, :1518-1529; `CameraPlugin.swift` :297-303 | `fbc80a62002` | BSD-3-Clause (nothing to reproduce: no text copied) |
| Shared-texture access bracket | house: `src/render/dawn_gpu_device.cpp` `iosurface_begin_access` / `iosurface_end_access` (initialized = true, no fences in, fences freed) | this repo | ours |
| On-device build / verify | PR #100 `buildFromPly` + `optionsForBudget` (`include/aether/pointcloud_lod_build/build.h:85-119`) unchanged; judges C1/C2 from `tests/pointcloud_lod/test_octree.cpp` `checkCount` / `checkTiling`, S2 and its camera helpers from `tests/pointcloud_lod/test_select.cpp` :34-84, :110-143 | this repo | ours / BSD-2 (PotreeConverter port) |
| M1 measurement entry `pwlod_run` (`m1_bench/`) | `pw_lod_bench.{cpp,h}` **byte-identical** | `b792d57` | ours + Potree notice in `m1_bench/NOTICE` |
| **v3 look** (`viewer_look.{h,cpp}`, the VIEWER WGSL): display colour, tone maps, height ramp, sprite disc, scale rule, selection tint / cull | the product painter `SparseCloudPainter`, `lib/ui/official_capture/sparse_cloud_view.dart` (:27, :235, :382-384, :812-828, :1056-1253, :1459-1531, :1598-1723) and `SelectionBox.contains` (`lib/official_capture/selection_box.dart:119-126`), pocketworld 168 source | `86a45cf` | ours |
| Tone maps carried by that painter | three.js r160 `src/renderers/shaders/ShaderChunk/tonemapping_pars_fragment.glsl.js` (AgX, ACESFilmic); Khronos `PBR_Neutral/pbrNeutral.glsl` | `643680ed5fc7` (r160); `b5a2eed5ddf6` | MIT; Apache-2.0 |
| Sprite image (R18, `kPainterSpriteAlpha`) | the painter's `_buildSprite` output as its own frames show it: parity_fixture_v3 from `test/point_cloud_lod/painter_parity_fixture_v3_test.dart` (product `feat/lod-on-dense-168`) | `44bf12f` | ours |
| v3 camera | the product's `CloudCamera.projectionFor -> CloudProjection` (`lib/ui/official_capture/cloud_camera.dart:68-128`) -- node size: `../pointcloud_lod/DEVIATIONS.md` D19 | `86a45cf` | ours |
| Dawn C header (compile only; nothing vendored here) | `webgpu/webgpu.h` → `dawn/webgpu.h` sha256 `6d632738597019d0…` | Dawn `12ee391c` | BSD-3-Clause |

## Cross-platform self-certification

Every new or changed source (`include/aether/pointcloud_lod_render/*.h`,
`src/pointcloud_lod_render/**/*.{h,cpp}`, `tests/pointcloud_lod_render/*`,
`tests/pointcloud_lod/test_ortho.cpp`, `select.{h,cpp}`) with comments stripped
(`clang -fpreprocessed -dD -E -P`) and grepped for
`__APPLE__|TARGET_OS|IOSurface|Metal|MTL|AHardwareBuffer|ANativeWindow|OHNativeWindow|objc`
→ **0 hits**. Without stripping there are 3 hits, all in comments (two in the
frozen `pwlod_viewer.h`, which names the shells' platform types it keeps OUT of
the ABI, one in `test_ring.cpp` naming the Flutter engine class it imitates) —
so the grep can fire. The host-test link line (Dawn + its system libraries) is
a configure-time cache variable, not committed CMake.

## Deviations from the bench (R) — every one marked "R<n>" in the code

**R1 the global device is a parameter.** The bench kept one `Gpu g` per process.
`GpuCtx` is passed to every function; uncaptured errors and device loss of every
device made by `CreateGpu` go to one process-wide, mutex-guarded log
(`GpuErrorCount/Log`, `GpuDeviceLost`).

**R2 the colour target is the caller's.** `Pipe` no longer creates a colour
texture; `LodFrame` renders into `Target{texture, view, memory}`. The pipeline's
colour format is a `MakePipe` argument (the ABI allows RGBA8Unorm or BGRA8Unorm;
the bench hard-coded RGBA8Unorm). The depth buffer stays Pipe's, sized to the target.

**R3 no queue wait inside the frame.** The bench's `WaitQueueIdle()` after
submit is replaced by a caller hook (`SubmitHook`) called at the same point,
before the sync-mode `EvictGpu`. A null hook is the bench's `WaitQueueIdle`
(the host judges use that). The viewer's hook registers
`wgpuQueueOnSubmittedWorkDone` (WaitAnyOnly, so it fires only inside the render
thread's own wait), optionally publishes early (the negative-control switch),
then waits for it on the render thread. `FrameRec` gains `submit_ms` and
`access_failed`.

**R4 shared-texture access.** When the target has a `WGPUSharedTextureMemory`,
`LodFrame` calls `wgpuSharedTextureMemoryBeginAccess` before encoding and
`EndAccess` after the hook (i.e. after the GPU finished), exactly the house
pattern in `dawn_gpu_device.cpp`. A refused BeginAccess submits nothing and is
reported as `PWLOD_ERR_GPU`.

**R5 clear colour is a parameter** (`DrawParams::clear_rgba`, from
`pwlod_params.background_rgba`). The bench cleared to (0,0,0,0); the judges keep that.

**R6 orthographic adaptive point size.** FrameU's `pad0`/`pad1` become
`ortho_width`/`ortho` (same 64-byte layout). In the WGSL adaptive branch, when
`ortho == 1` the size is `(worldSpaceSize / ortho_width) * img_size.x` —
`pointcloud.vs:690-692`, with `uOrthoWidth = camera.right - camera.left`
(`PotreeRenderer.js:1239`). The perspective lines are unchanged and still run
first; `tan_half_fov` is set to 1 in orthographic mode only so the unused
perspective factor stays finite. Potree's orthographic `attenuated` branch
(`:683-684`) is not used (we have no attenuated mode).

**R7 `r_min` / `r_max` are parameters** (bench: 0 / 64 written unconditionally,
still the defaults). The C ABI's `PWLOD_PSIZE_FIXED` sets both to 1, which is
Potree's `PointSizeType.FIXED` (potree @ `5636cd471d9e`, BSD-2-Clause):
`src/materials/PointCloudMaterial.js:235-236` (FIXED → `#define fixed_point_size`;
FIXED is also the material default, `:37`), `src/materials/shaders/pointcloud.vs:680-681`
`pointSize = size`, clamped by `:699-700` with `PointCloudMaterial.js:32-34`
(size 1, minSize 2, maxSize 50) → 2 px diameter → half-size 1 (P4).
Decided by the coordinating session 2026-09-24: keep this; no orbit-distance
field is added to the ABI. Reason: the bench's mode 0 is the product's
orbit formula `base * camDist / depth`, and `pwlod_camera` carries no orbit
distance, so the ABI's FIXED arm cannot be that formula; the C++ path keeps it
(`CamState::cam_dist`) and `pwlod_run` keeps its own copy.

**R8 resources are released.** `ReleasePipe`, `ReleaseGpu`,
`wgpuAdapterInfoFreeMembers` after `wgpuAdapterGetInfo` — the bench was a
one-shot process and never released them.

**R9 readback takes any texture** (judges only, `tests/pointcloud_lod_render/judges.cpp`).

**R10 pipeline errors are detected.** Dawn returns an error object, never null,
for an invalid pipeline, so the bench's `if (!P->pipe)` could not fire.
`MakePipe` now flushes the queue and compares the uncaptured-error count.

**R11 caller features.** `CreateGpu` = the bench's `InitGpu` (TimedWaitAny
instance feature, default backend, Null backend refused, adapter max storage
limits, TimestampQuery when available) plus the caller's `required_features`;
a feature the adapter lacks is an error. A device-lost callback feeds R1's log.

**R12 `ResetLod` with no octree only releases** (the viewer resets before the
first octree arrives).

**R13 `FrameRec::lowest_spacing`** carries the frame's `Selection::lowestSpacing`
(both the sync and the async branch of `LodFrame`), for ABI v2 (A8).

**R14 the product viewer's look (ABI v3, `PWLOD_PSIZE_VIEWER`, `psize_mode 2`).**
A third point-size mode next to the bench's two, ported from the product painter
(sparse_cloud_view.dart @ 86a45cf):
- *colour*: the painter's `_displayColors` (:1206-1250: `_srgbDecode` -> tone ->
  `_srgbEncode`, AgX / ACES / PBR Neutral / None, the uncoloured height ramp) runs
  on the CPU in double at upload (`viewer_look.cpp`, `DisplayArgb`) and is baked
  into the point record, so a colour is the painter's to the bit; the GPU draws it.
- *sprite*: the painter draws a 16x16 white disc (`drawCircle(Offset(8,8), 7,
  isAntiAlias)`, :819-825) with `drawRawAtlas` + `BlendMode.modulate` (:1715-1723),
  anchored at `scale * 8` (:1702). Here: a quad of half-size `8 * scale` px and,
  per fragment, the sprite's alpha -- since R18 the painter's own 16x16 image
  sampled nearest (first written as the analytic `clamp(7 + 0.5 - r, 0, 1)`, which
  the painter's PNGs rejected, see R18) -- premultiplied source-over.
- *scale*: `pointSize / 16` when orthoMix == 1, else
  `min(pointSize/16 * camDist / divisor, 50/16)` (:1669-1677); the divisor is the
  fragment's clip.w, which the v3 `view_proj` defines as `divisorAt(depth)`.
- *selection*: `SelectionBox.contains` (`|rot^T (p - c)| <= size / 2`,
  selection_box.dart:119-126) per point in the vertex shader, with `p - c` formed
  as (node origin - c, double then cast, `NodeU.sel_off`) + node-relative point;
  outside -> `selection_out_argb` (TINT, :1680-1682) or not drawn (CULL, :1610).
- *occlusion*: the painter sorts far -> near every frame (:1692-1694) to imitate
  "WebGL's depth buffer" (its own comment, :1588-1591). Here the depth buffer
  itself: pass 1 draws the fully covered texels with depth write, pass 2 the rim
  texels, depth-tested, not written, blended. The result differs from the
  painter's only where two or more rims lie in front of the nearest fully
  covered texel (blended in draw order, not depth order) and where two points
  are a depth tie for a float32 depth buffer; measured, see Verification.
New objects: `ViewerU` (binding 4), `NodeU.sel_off` (NodeU 80 -> 96 B), pipelines
`viewer_core` / `viewer_rim`, the compute probe `cs_viewer_probe` that runs the
vertex shader's own `viewerPoint()` for per-point parity (test only).
The bench's two modes are unchanged (the 36M / 216M reference numbers still hold).

**R15 the draw half of `LodFrame` is shared** (`EncodeDraws`), so a flat point
set (`FlatSet`, `UploadFlat`, `FlatFrame`; ABI v3 `set_points`) is drawn by the
identical code: one or more chunks of <= 2^20 points, positions relative to the
set's box centre, colours baked like a node's.

**R16 `FrameU` under the v3 camera.** Potree's adaptive size needs
`0.5 H / tan(fov/2)` (= `focal_px`) and, orthographic, `orthoWidth` (= `W *
orbit_distance / focal_px`); with the product projection clip.w is the divisor,
so the perspective formula reads `focal / divisor` at every orthoMix < 1.

**R17 `RetargetPipe`: a new target size / format keeps the GPU copies.** Found
while adding v3: the v2 viewer rebuilt its whole `Pipe` when a frame came with a
different target size (e.g. `render_once` at another size than the ring), leaving
every resident node's bind group pointing at the released uniform buffers.
Now only the pipelines and the depth buffer are rebuilt; the bind-group layout
and buffers stay (a bind group is valid with any group-equivalent layout).

**R18 the sprite is the painter's 16x16 image, sampled nearest.** The painter's
own output (parity_fixture_v3, product `feat/lod-on-dense-168` @ `44bf12f`,
`test/point_cloud_lod/painter_parity_fixture_v3_test.dart`: the real
`SparseCloudPainter` and sprite) showed two things R14's analytic disc got wrong:
(1) `drawRawAtlas` is called with `Paint()`, whose `filterQuality` defaults to
`FilterQuality.none` -- the sprite is sampled NEAREST: a pixel whose centre lies
at sprite coordinate `(u, v) = (pixel centre - (centre - 8 s)) / s` takes texel
`[floor v][floor u]`, blocky at 3x, not a smooth ramp; (2) the texel values are
the rasterizer's coverage of that circle (e.g. 224 and 232 where the analytic
disc gives 250), not symmetric to the bit. The table (`kPainterSpriteAlpha`,
`viewer_look.{h,cpp}`) is those 256 bytes, recovered from the painter's 3x PNGs:
all 1,595,711 pixels covered by exactly one sprite (>= 0.02 texel from a texel
edge) equal `round(colour * alpha / 255)` with it, 0 exceptions (judge T0 of
`test_parity.cpp` re-checks it on every run); the analytic disc fails 353,034 of
them. The fragment derives `(u, v)` from its own position and the point's flat
centre (VsOut `spr`), not from interpolated vertex attributes: the rasterizer
snaps quad vertices to its sub-pixel grid, which moved texel edges by up to 0.02
texel at 1x and flipped 79 pixels of one 1x frame to the neighbouring texel. Any
other sprite geometry than the product's (16 px, radius 7) keeps the analytic
disc. Not verified: the phone's rasterizer (the fixture ran under the host test
renderer); a dump of `_sprite.toByteData()` on the device would settle it, and
would only change table data. The frozen header still describes the sprite as
"a disc ... with a 1 px anti-aliased rim" -- the painter's intent; what is drawn
is its actual image (a wording for the next header revision, not an ABI change).

Inherited from the bench unchanged: P1–P6 (listed at `BuildVisibleNodeTable`).

## Interface glue decisions (A) — no upstream exists for these

**A1 render loop.** A `std::thread` owned by the viewer. It renders when an
input changed since it last looked (camera / params / octree generation
counters, remembered by the loop itself so a frame that could not run does not
make it retry the same inputs), or the last
frame left work (loads in flight or queued, nodes promoted, controller moved),
at most once per `target_frame_ms`; otherwise it waits on a condition variable.
One frame in flight at a time: submit → wait for `OnSubmittedWorkDone` on the
render thread → EndAccess → publish → callback.

**A2 ring choice.** Rotation from the last written index, skipping the latest
published target and the target the consumer holds (both read under the ring
lock, the only lock `acquire_latest` takes). With 3 targets and at most 2
excluded, a target always exists. The choice is counted by `viewer_probe.h`
(`held_overwrites`, `latest_overwrites`); `SetIgnoreHeldExclusion` drops the
held rule for the negative control.

**A3 publish.** Under the ring lock: latest index, its frame number and stats;
then the shell's `pwlod_frame_ready_fn` outside the lock.
`completed_frame_number` is written only by the OnSubmittedWorkDone callback
(its own path), so a publish can be reconciled against it.
`debug_publish_before_done = 1` publishes right after submit instead.

**A4 controller input.** `QualityController::onFrame(fr.wall)` — the bench fed
the same quantity (frame start → after the GPU wait and eviction).
`min_node_pixel_size` in the stats is the controller state after that call.

**A5 defaults.** `pwlod_params_default`: budget 3,630,000, target 1000/30 ms
(QualityController's default; the header's "33.333"), ADAPTIVE, async on,
`cache_bytes = 15 × budget` and never less (header: "default and minimum");
background (0,0,0,1). **Note:** the bench ran with 3 × 15 B × budget; with the
header's floor a drawn node can be evicted by a burst of loads in async mode
(visible as `dropped_for_cache`). Coordinator decision 2026-09-24: the header
stays; the shell passes the bench's measured 3 × 15 × budget explicitly.

**A6 error classes.** Missing file → `ERR_IO`; `loadOctree` error text starting
"cannot read" → `ERR_IO`, other parse errors → `ERR_FORMAT`.
`pwlod_build_from_ply` failure → `ERR_FORMAT` if `openPly` rejects the input
(truncated, malformed, zero points, non-finite), else `ERR_IO` (writing the tree).
`memory_budget_mb <= 0` → no memory cap on `optionsForBudget`'s thread count
(its own `min(4, cores)`), `threads <= 0` → that default.

**A8 ABI v2 `lowest_spacing` — RESOLVED 2026-09-24 per Potree** (header sha256
`4b047f1f…`, comment-only change over `fb6459d6…`; `PWLOD_ABI_VERSION 2`,
`pwlod_version()` = `"<sha8> abi=" PWLOD_ABI_VERSION`). Filled on every path
(render thread, `render_once`, the early-publish negative control) with the
frame's `Selection::lowestSpacing`, which is now Potree's
`Potree_update_visibility.js:276-280` exactly: min spacing over EVERY node
popped from the queue, before the budget break and the visibility test
(`../pointcloud_lod/DEVIATIONS.md` D18). It does not depend on what was drawn,
so the async first frame (0 nodes drawn) reports select's value too; 0 only if
nothing was popped (+infinity; an empty tree). Judged bit for bit against a
direct `selectVisible` call through `render_once` (perspective, orthographic),
the render thread's first published frame and the async first frame
(test_capi V2), with a negative control that fills the root's (largest)
spacing (`SetFillMaxSpacing`, viewer_probe.h); the definition itself is judged
in `tests/pointcloud_lod/test_spacing.cpp`.
History: the first v2 build (engine `740c1dd`, artifact `libpw_lod_740c1ddd.a`)
used the old select.cpp placement (accepted nodes only) and reported 0 when
nothing was drawn; superseded.

**A9 flat source and point-size modes.** A flat set has no octree, so
`PWLOD_PSIZE_ADAPTIVE` (Potree's getLOD needs the visible-node table) falls back
to the viewer's own rule on it; `FIXED` stays `FIXED`.

**A10 a flat set is drawn whole.** No selection, no budget, no controller update
(there is no pixel size to choose); `stats.nodes_drawn` counts its chunks,
`lowest_spacing` is 0 (nothing was popped), `source` 1. A non-finite point is
left out (the painter's arithmetic turns it into NaN, which the canvas drops).

**A11 colour cache.** Display colours are baked into the GPU copies, keyed like
the painter's own cache (`_displayColors`, :1197-1213: cloud, exposure, tone) plus
the uncoloured ramp domain and the mode; a new key re-bakes: the flat set is
re-uploaded, the octree's GPU copies are dropped and re-streamed. The selection
box and all camera terms are per-frame uniforms, never baked.

**A12 source switching.** `set_points` and `load_octree` share one generation
counter; whichever came last is the source at the next frame boundary. Camera,
style and the controller state are not touched by a switch. With
`async_loading = 1` the first octree frames draw only what has loaded (Potree's
behaviour: nothing until the root arrives); the viewer does not keep the flat set
on screen meanwhile (reported to the coordinator, not decided here).

**A13 what the shell hands over, as the parity judge exercises it.** Not new
ABI, the header's units spelled out: `pwlod_style` and `pwlod_camera` are in
TARGET pixels, so a shell drawing at device pixel ratio d passes `focal_px`,
the view origin (inside `view_proj`), `point_size` and `max_sprite_scale`
multiplied by d -- the painter scales its canvas instead (`canvas.scale(3)` in
the fixture's 3x PNGs, which the engine then matches). The painter's near cull
is `depth <= 0.02 R` (:1618); the engine drops what the shell's `view_proj`
clips, so a shell that wants that cut exactly puts its near plane there. A
visibility mask whose length differs from the cloud is ignored by the painter
(:1545-1548); the ABI takes a pointer without a length, so the shell drops such
a mask (passes NULL) -- the engine cannot.

**A7 C2 in bytes.** `pwlod_verify_octree` reports gap and overlap BYTES instead
of stopping at the first break; it passes iff both are 0, which is exactly when
`test_octree.cpp` `checkTiling` passes.

## M1 carry (`m1_bench/`)

`pw_lod_bench.cpp` / `.h` are byte-identical to the bench (sha256 above). **No
change was needed** to compile them into the library under the repo's C++20 +
`-Wall -Wextra -Werror -fno-exceptions -fno-rtti -ffp-contract=off
-fno-fast-math`. Everything in the .cpp except `pwlod_run` has internal linkage
(anonymous namespace), so its own `InitGpu`, `Pipe`, `LodFrame`… cannot collide
with this module's; `pwlod_run` creates its own instance and device as on the
bench. The only integration step is the include path for `"pw_lod_bench.h"`.

## Verification (Mac M3 Pro, Dawn Metal backend, repo strict flags)

The render judges reproduce the bench's Mac reference
(`results_mac_20260924_async_adaptive/summary_correct_{36M,216M}.txt`) **number for
number** at every pose: points drawn, visible-node entries, see-through floor /
fixed / adaptive / adaptive-vs-adaptive-ref, getLOD node / point counts and
negative-control counts, async frames to converge, leaf check (36M: 26,196 px
changed, 27,522 leaf-only px; 216M: 13,288 / 13,879).

"See-through ≤ jitter floor at every pose where the production formula sees
through" holds on 36M (orbit_mid: production 7.97 %, adaptive 0.00 %, floor
0.43 %) and on 216M at orbit_mid and pan_mid, but **fails on 216M overview**
(production 0.80 %, adaptive 0.51 %, floor 0.15 %) — the same numbers as the
bench's own Mac run, i.e. a property of Potree's adaptive size at that LOD cut,
not of the move. Not registered as a ctest on 216M for that reason; reported.
Coordinator decision 2026-09-24: record as is, no change.

### ABI v3 (look, flat source, camera) — `tests/pointcloud_lod_render/test_viewer.cpp`

Reference: `painter_ref.{h,cpp}`, the painter transcribed in double (projection,
depth / off-screen cuts, scale rule, display colour, selection) plus a far->near
source-over rasterizer of its sprites. The fixture's 25,000-point `source.ply`,
600 x 800, 13 camera / style cases (orthographic, perspective, orthoMix 0.5,
rolled + panned, zoomed; coloured, uncoloured ramp, AgX / ACES / PBR Neutral /
None, TINT, CULL, mask).

- Per point (the probe runs the vertex shader's own `viewerPoint()`): every
  drawn point's colour identical to the bit, cull flag identical, screen
  position within 1.4e-4 px (limit 0.02 px), scale within 1e-5.
- Whole image: pixels with a channel off by > 8 outside the pixels the
  reference marks order-sensitive (>= 2 rims in front of the nearest covered
  texel, or a float32 depth tie) <= 0.011 % (limit 0.05 %); inside that set
  0.002-0.12 %; PSNR 48.9-66.9 dB.
- Negative controls caught: transposed `view_proj` (every point off, 17 % of the
  image), a wrong tone (24,984 / 25,000 colours, 3.9 % of the image), TINT dropped
  (8,016 colours), mask ignored (8,334 extra points).
- `set_points` copies its arrays (image identical after the caller overwrote
  them), the mask hides exactly its 8,334 points, `source` 1, `lowest_spacing` 0.
- Flat -> octree (the fixture tree = the same points): the first frame after
  `load_octree` reports `source` 2; converged (all 25,000 points drawn),
  coverage 0.1609 vs 0.1609 and 0.135 % pixels off by > 8 (PSNR 50.5 dB) --
  the octree's positions are the int32 grid of the conversion, not the PLY
  floats. Negatives: another tone 13 % of pixels, shuffled flat colours 13.6 %.
- The bench's two point-size modes are unaffected: the 36M render judges still
  reproduce the Mac reference number for number.

Since R18 `painter_ref`'s rasterizer is the painter's 8-bit canvas with the
nearest-sampled sprite table -- the model the Dart PNGs confirm (test_parity.cpp) -- and the
numbers above were re-run with it: outside the order-sensitive set <= 0.013 %
(persp roll zoom), all other cases <= 0.011 %, negatives unchanged in kind.

### Parity with the product painter itself — `tests/pointcloud_lod_render/test_parity.cpp`

Input: parity_fixture_v3 (product side, `SHA256SUMS` sha256 `c4070a6a…`, all
entries OK; `index.json` `c8e2ac52…`; 27 groups, 1536 points, contract = the v3
header `4e867aa3…`), given to ctest as `AETHER_PWLOD_PARITY_FIXTURE` (not
committed). The test plays the shell (A13) at 1x and 3x.

- T0 sprite: 1,595,711 single-covered 3x pixels, 0 differ from the table;
  analytic disc (NEG) 353,034 differ.
- R0 / R1 `painter_ref` vs Dart: `ProjectionFor` reproduces the projection
  scalars exactly (max |diff| 0 over 27 groups x 14 scalars); `PaintPoint`
  over 30,045 drawn points: drawn set identical, argb identical, position within
  5.9e-5 px and scale within 5.8e-8 relative -- the fixture's numbers are the
  painter's float32 atlas (`vx = rst[2] + 8 scale`), so that is float32 rounding.
- P1 engine per point, 27 groups x {1x, 3x}: drawn set identical (mask, CULL,
  near cull, off-screen skip), argb identical, position within 2.6e-4 logical px
  (limit 0.02), scale within 3.1e-7 relative (limit 1e-5).
- P2 engine whole frame vs the Dart PNG (RGB, black clear): outside the
  order-sensitive set <= 0.0010 % of pixels (1x) / 0.0005 % (3x), limit 0.005 %;
  PSNR there >= 60.0 / 62.8 dB, limit 50 dB. The painter's own per-point numbers
  rasterized by `painter_ref` differ from its PNG on up to 0.0009 % (texel-edge
  ties decided in Skia's float32), which is the floor. The order-sensitive set is
  0.000-0.044 % of the frame at the product point size and 4.3 % at the 50/16
  size cap (`persp_maxsize`), where 1.16 % of the frame differs by > 8: large
  overlapping sprites whose rims the painter blends far->near and the GPU in
  draw order (R14).
- Negative controls, each caught by both the per-point and the image judge:
  transposed `view_proj` (224 positions + 997 drawn-set of 1536; 2.73 % px),
  ACES for PBR Neutral (1533 / 1533 argb; 1.90 %), TINT dropped (723 argb;
  1.33 %), mask ignored (649 drawn-set; 0.89 %), the analytic disc = the engine
  before R18 (0.561 % px).
