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

**A8 ABI v2 `lowest_spacing`** (header sha256 `fb6459d6…`, `PWLOD_ABI_VERSION 2`,
`pwlod_version()` = `"<sha8> abi=" PWLOD_ABI_VERSION`). Filled on both paths (render
thread, `render_once`, and the early-publish negative control) with
`Selection::lowestSpacing` from the frame's own `selectVisible` call
(`src/pointcloud_lod/select.cpp:106`), and with 0 when no node was drawn or
nothing was accepted (the header's "<= 0 if none drawn"). Judged bit for bit
against a direct `selectVisible` call (test_capi V2), with a negative control that
fills the root's spacing (`SetFillMaxSpacing`, viewer_probe.h).
**Three definitions disagree — reported, not changed here:**
(1) Potree `Potree_update_visibility.js:276-280` @ `5636cd4` updates
lowestSpacing for EVERY node popped from the queue, before the budget break
(`:282`) and before the visibility test (`:286`), so frustum-culled nodes and the
node that trips the budget count; (2) `select.cpp:106` (PR #98) updates it only
for accepted nodes (after both tests); (3) the frozen header's comment says
"among the nodes drawn this frame" — in async mode accepted nodes that are not
yet drawable count in (2) but are not drawn. The coordinator asked for (2); (1)
would change `aether::pointcloud_lod`, which this module uses as-is.

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
