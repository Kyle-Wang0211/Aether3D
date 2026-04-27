# Phase 6 plan — splat viewer (vertex+fragment) + training pipeline (Brush WGSL) — v3

**Status**: ACTIVE 2026-04-26. **v3 upgrade in flight** (the v2 viewer-data-flow + Brush kernel scope have been replaced by industry-aligned vertex+fragment + instanced quads viewer with freemium training tier). v3 carries forward all committed work (6.0 / 6.1 / 6.2.A-F / 6.3a Steps 1-3); only the viewer rasterizer path + sub-step ordering change.

**Phase 6 mission (v3 verbatim from user)**: "viewer rasterizer = vertex+fragment + instanced quads (MetalSplatter style), Brush 14 WGSL files all retained as algorithm base for training, splat_render.wgsl is the only new WGSL we write in Phase 6, freemium training tier (local Phase 7 + cloud Phase 6.7), national-grade stability across iPhone 8 → iPhone 17 Pro + Snapdragon 8 Gen 2+ + cloud-fallback for Adreno/Maleoon."

**v1 → v2 → v3 evolution table**:

| Dimension | v1 | v2 | v3 |
|---|---|---|---|
| Viewer rasterizer path | hand-translate compute from MSL | adapt Brush 4 compute kernels | **vertex+fragment + instanced quads** (MetalSplatter style) |
| Shader source | hand MSL→WGSL translation | adapt Brush WGSL (Apache-2.0) | adapt Brush 14 + new `splat_render.wgsl` (~80 lines, Aether3D-original) |
| Cross-val oracle | none | MetalSplatter (compute-vs-vert+frag → architectural mismatch) | **MetalSplatter** (architecture matches v3 → diff comes from FP rounding only) |
| Perf bar | ≥30 fps loose | Mobile-GS 60 FPS @ 50k iPhone 14 Pro | Mobile-GS bar **+ national-grade device coverage** (iPhone 8+ / Snapdragon 8 Gen 2+ / cloud fallback for older / Adreno crash mitigated) |
| Training position | end-to-end on-device (assumed) | end-to-end on-device (assumed) | **freemium tiers**: Phase 7 on-device free + Phase 6.7 cloud paid (vast.ai A100/H100) |
| Industry validation | none | implicit from Brush adoption | **explicit**: GauRast 23×, C3DGS 3.5×, MetalSplatter App Store, Spark.js, PlayCanvas SuperSplat v2.17 (compute→instanced quads regression), Brush Issue #77 (Adreno crash) |

---

## Locked decisions

| # | Decision | Choice | Rationale |
|---|---|---|---|
| **A** | Cross-validation oracle | **v2: MetalSplatter (App Store-shipped, MIT-licensed iOS reference)** | v1 deprecated TestFlight Aether3D entirely; v2 picks MetalSplatter because it's actively shipped (Vision Pro viewer + OverSoul social app), so its rendering math is production-validated by Apple's review process — strictly better oracle than building one from scratch |
| **B** | Test data sourcing | **Mip-NeRF 360 garden (50k Gaussians, 3DGS-paper academic gold standard) + synthetic_smoke.ply (~100 deterministic Gaussians, dev-iteration smoke)** | Mip-NeRF garden is the same scene Mobile-GS paper benchmarks against → directly comparable perf numbers. Synthetic smoke gives dev a sub-second-load deterministic input for inner-loop debug (garden takes seconds + hundreds of MB) |
| **C** | Training convergence testing | **DEFERRED** to post-UI-redesign with real captured data | Phase 6 only validates training data plumbing (FFI buffer round-trip), not gradient correctness. Convergence verification happens when Phase 7+ UI ships with real-world scans |
| **D** | Dawn iOS attack | **Build-flag flip only** (audit confirmed Dawn submodule already has Metal backend + iOS GPU family code at `third_party/dawn/src/dawn/native/metal/`) | Phase 5 BACKLOG "1-2 days" estimate assumed vendor work; audit shows infra is already in tree, so 6.0 collapsed to a single-line flip + the Abseil C++17 probe regression noted in BACKLOG |
| **E** | Per-step abort policy | **No phase降级; no MSL fallback; no per-platform shader fallback** | Per the locked Phase 6 prerequisite BACKLOG entry: "per-platform shader is a violation, not a fallback." 6.0 / 6.3 abort = BACKLOG entry + diagnose forward, never retreat |
| **F** | Time budget | **Multi-session, no single-night attempt** | Phase 6 v2 realistically 5-10 days of focused work given Brush adaptation + MetalSplatter cross-val infra. 04:00 hard stop applies per session, not per phase |
| **G** | Shader strategy (v2 NEW) | **Adapt Brush WGSL kernels (math 1:1, bindings rewired to aether_cpp's GPUBufferDesc)** — NOT translate from MSL | Brush ships gSplat-paper-level math, Apache-2.0, already verified end-to-end. Translating MSL ourselves duplicates effort and introduces bug-risk. Per-file attribution header preserved; LICENSE-Brush at repo root. Brush math is sacrosanct; only the bindings change. |
| **H** | Performance bar (v2 NEW) | **Mobile-GS standard — 60 FPS @ 50k Gaussians on iPhone 14 Pro + ≥30 FPS @ iPhone 12** | Mobile-GS paper measured 116 FPS @ 1600×1063 on Snapdragon 8 Gen 3 (≈ Apple A16). 60 FPS at 50k is the public benchmark for "national-grade mobile 3DGS"; settling for less violates user's stability requirement |
| **I** | Cross-val frame-dump method (v2 NEW) | **Fork MetalSplatter, add IOSurface raw-RGBA dump path** (Phase 4/5 IOSurface experience reusable) | Default per user 2026-04-26; if IOSurface routing turns out more complex than expected during 6.5 implementation, fall back to "UI button → texture.getBytes() → write file" — both paths are tools, not architecture |
| **J** | Viewer rasterizer architecture (v3 NEW) | **vertex+fragment + instanced quads** (MetalSplatter / Spark.js / PlayCanvas SuperSplat style) | Industry evidence one-sided: GauRast 23× / C3DGS 3.5× / WebSplatter "raster substantially better" / PlayCanvas v2.17 actively reverted from compute → instanced quads / Brush Issue #77 Adreno crashes 5-750 steps / Flutter Issue #157811 Maleoon Vulkan compute disabled. Reverse evidence (compute beats vert+frag): zero. National-grade "不挑设备" requires the path that works on every mobile GPU vendor. |
| **K** | Algorithm-base preservation (v3 NEW) | **All 14 Brush WGSL files retained**, even those the v3 viewer doesn't use (`map_gaussian_to_intersects.wgsl`, `rasterize.wgsl`) | Phase 7 on-device training + Phase 6.7 server training need them. Removing = permanently closing the freemium-local-training door. Keep cost = ~3h of additional smoke tests for unused-by-viewer kernels. |
| **L** | Freemium training tier (v3 NEW) | **Local on-device free (Phase 7) + Cloud A100/H100 paid (Phase 6.7)** via vast.ai existing infra | Scaniverse 100% local entry-level (free, fast, lower quality) + Polycam/KIRI/Luma cloud (paid, slower, higher quality) — PocketWorld combines both. Cloud path zero-new-infrastructure (vast.ai already rented for VGGT pipeline; add Brush stage). |
| **M** | Device capability matrix (v3 NEW) | **Whitelist on-device** for iPhone 12+ / Mac M1+ / Snapdragon 8 Gen 2+, **cloud-only fallback** for older / Adreno-old / Mali / Maleoon | Adreno crash + Maleoon-Vulkan-disabled make blanket-on-device impossible. Capability detection + cloud fallback satisfies national-grade "every-device-can-use" without forcing every device through a known-broken path. |
| **N** | New WGSL file in Phase 6 (v3 NEW) | **`splat_render.wgsl` (~80 lines, vertex+fragment, Aether3D-original)** is the only new shader code we write | Aether3D-original code, not Brush-adapted. Apache-2.0 attribution does NOT apply (it's our code). Same conic math as Brush's rasterize.wgsl fragment but expressed as fragment shader running over rasterized instanced quads instead of compute over tile mosaic. |

**Pre-kickoff audit findings** (locked into plan):

- ✅ All 17 splat + render header/src files at exact prompted paths (one minor: `splat_render_engine.cpp` is 1061 lines not the 1825 stated in prompt — prompt drift, harmless)
- ✅ All 3 MSL shader files (Aether3D-cross copy at `App/GaussianSplatting/Shaders/`)
- ✅ Dawn submodule at `aether_cpp/third_party/dawn/`, Metal backend with iOS GPU family checks (`MTLFeatureSet_iOS_GPUFamily*`) already in tree
- ✅ `AETHER_ENABLE_DAWN=ON` by default in CMakeLists; only `build_ios_xcframework.sh` overrides to OFF (Phase 5.0 deferral) → 6.0 step 1 is a single-line flip
- ✅ `shader_source.h` has 3 enum values (kMSL/kGLSL_ES300/kGLSL_Vulkan) → 6.1 is a single-line append
- ✅ Training engine present at `aether_cpp/include/aether/training/` (12 headers); training MSL exists at `App/GaussianSplatting/Shaders/GaussianTraining.metal` (1460 lines) — both ready for 6.3b
- ❌ `aether_cpp/test_data/` does not exist — to be created when 6.5 needs splat scenes (per B, "any .ply / .spz" suffices)

---

## Sub-step decomposition + execution order

Per Phase 4/5 de-risk principle (validation chain, not dependency order). Order: **6.0 → 6.1 → 6.2 → 6.3a → 6.3b → 6.4 → 6.5 → 6.6**.

| # | Description | Risk | Validation env | Dependencies |
|---|---|---|---|---|
| 6.0 | Dawn iOS unblock (build-flag flip + iOS xcframework rebuild) | 🟡 medium (audit confirmed infra ready, but Apple toolchain quirks possible) | iPhone 14 Pro real device | None |
| 6.1 | Add `kWGSL = 3u` to `ShaderLanguage` enum | 🟢 trivial | host build | None |
| 6.2 | Implement `DawnGPUDevice` C++ class (~950-line mirror of `metal_gpu_device.mm`) | 🔴 highest (real engineering, every virtual override) | host + iOS | 6.0, 6.1 |
| 6.3a | **v3: Brush 3 viewer kernels (project_forward, project_visible, sort/prefix_sum) + new splat_render.wgsl (vertex+fragment)** | 🟡 medium (Brush math is sacrosanct, splat_render fragment is ~80-line conic-evaluation) | Dawn Tint compile + per-kernel smoke + sanity-render synthetic_smoke.ply via vert+frag pipeline to RGBA8 IOSurface | 6.1 |
| 6.3b | **Brush 4 training kernels: project_backwards, rasterize_backwards (training-only), + retain map_gaussian_to_intersects + rasterize for training path** | 🟡 medium (compute-only; Phase 7 enables on-device, Phase 6.7 ships cloud) | Dawn Tint compile + buffer round-trip via aether_train_step | 6.1 |
| 6.4 | Wire `DawnGPUDevice` into PocketWorld iOS + macOS plugins | 🟡 medium (FFI pluming + Dart UI changes) | iPhone + macOS desktop | 6.2, 6.3a, 6.3b |
| 6.5 | End-to-end smoke (load any .ply, render, sanity-check `train_step` buffer round-trip) | 🟢 low (verification only) | iPhone + macOS desktop | 6.0–6.4 |
| 6.6 | 6-axis quality gate execution + `PHASE6_DONE.md` write-up | 🟢 low (instrumentation + docs) | iPhone | 6.5 |

---

## Per-sub-step precise plan

### 6.0 — Dawn iOS unblock (build-flag flip)

**Input**: `aether_cpp/scripts/build_ios_xcframework.sh` (Phase 5.0 set `-DAETHER_ENABLE_DAWN=OFF`); CMakeLists default is ON.

**Action**:
1. Edit `build_ios_xcframework.sh`: remove `-DAETHER_ENABLE_DAWN=OFF` from `COMMON_ARGS` (or flip to `=ON`).
2. Run script. Expected outputs: `dist/aether3d_ffi.xcframework` (already produced) + Dawn now linked into `aether3d_core` static lib.
3. Build `aether_dawn_hello` for iOS device target via xcodebuild (the Phase 1.4 P1.4 hello samples are `add_executable` targets, will need a separate iOS-device build invocation).
4. Deploy hello binary to Kyle's iPhone via the `scripts/deploy_iphone.sh` pattern.
5. Capture `NSLog` output (Dawn hello uses `NSLog` per Phase 5 lesson — stdout doesn't reach real device) confirming Metal backend is selected + iOS GPU family detected.

**Verification**:
- iOS xcframework rebuild succeeds with Dawn ON
- Dawn hello binary launches on iPhone
- NSLog stream shows `Backend: Metal`, `GPU family: <some Apple GPU family>`

**Per-step abort signal**: build fails or Dawn doesn't initialize → diagnosis to `PHASE_BACKLOG.md` "Phase 6.0 abort" entry. **NO MSL fallback** per E.

---

### 6.1 — Add `kWGSL` enum

**Action**:
1. `aether_cpp/include/aether/render/shader_source.h`: add `kWGSL = 3u` after `kGLSL_Vulkan = 2u`.
2. `aether_cpp/src/render/shader_source.cpp`: ensure existing switch-cases or callers handle new value (likely `static_assert(static_cast<int>(ShaderLanguage::kWGSL) == 3)` plus a string-name function update).
3. Compile `aether3d_core` clean.

**Verification**: build clean, no `-Werror` triggers, no unhandled-enum warnings.

---

### 6.2 — `DawnGPUDevice` implementation

**Input**: `metal_gpu_device.mm` (950 lines — every virtual override on `GPUDevice`); Dawn `webgpu.h` C API; iOS-specific IOSurface support (since 6.4 needs zero-copy Texture widget pipeline).

**Action**:
1. Read `metal_gpu_device.mm` end-to-end. Catalog every virtual method override.
2. Create `aether_cpp/include/aether/render/dawn_gpu_device.h` (mirror of `metal_gpu_device.h`).
3. Create `aether_cpp/src/render/dawn_gpu_device.cpp`. For each virtual method:
   - Read Metal impl
   - Implement via Dawn `webgpu.h` (`wgpuDeviceCreate*`, `wgpuQueueSubmit`, etc.)
4. Add `kDawn` to `GraphicsBackend` enum (likely in `gpu_handle.h`).
5. **IOSurface bridge** (the high-risk part): `DawnGPUDevice::create_texture` must accept an IOSurface handle and return a Dawn `WGPUTexture` backed by the same memory. Dawn's `wgpuDeviceCreateTextureFromMetal` (if exposed) or `WGPUExternalTextureDescriptor` with Metal interop. May require Dawn-internal API — fall back to plain Metal `MTLTexture` interop if the public API is missing.
6. Wire into `CMakeLists.txt`: add `src/render/dawn_gpu_device.cpp` to `AETHER_CORE_SOURCES`. Conditional on `AETHER_ENABLE_DAWN AND TARGET dawn::webgpu_dawn`.

**Verification**:
- Compile clean under strict flags
- Unit-test (host) creates `DawnGPUDevice`, queries capabilities, allocates a buffer, allocates a texture, submits empty command buffer

**Per-step abort signal**: Dawn doesn't expose IOSurface interop → BACKLOG entry; investigate Dawn upstream issue / patch path.

---

### 6.3a — Adapt Brush 4 viewer kernels (v2)

**Input**:
- 4 Brush kernels at `https://github.com/ArthurBrussee/brush/tree/master/crates/brush-render/src/shaders/`:
  - `project_forward.wgsl` (frustum cull + depth extraction with atomic compaction)
  - `project_visible.wgsl` (2D projection + Spherical Harmonics evaluation, degree 0–4)
  - `map_gaussian_to_intersects.wgsl` (tile mapping, TILE_WIDTH = 16 pixels)
  - `rasterize.wgsl` (tile-based alpha blending, workgroup-shared memory batched loads)
- `aether_cpp/include/aether/splat/splat_render_engine.h` (251 lines) for our binding layout.

**Action**:
1. Vendor the 4 .wgsl files into `aether_cpp/shaders/wgsl/`. Each file MUST start with the attribution header per spec (Apache-2.0, original path, math source = gSplat reference). LICENSE-Brush copied to repo root.
2. For each kernel, **the math is sacrosanct — keep Brush's math 1:1**. Only change:
   - Brush's Burn-tensor binding declarations → aether_cpp's `GPUBufferDesc` binding layout
   - Workgroup size constants if our renderer needs different (default = match Brush)
   - Push constants / uniform binding indices to match aether_cpp's bind group layout
3. Embed via new `aether_cpp/cmake/wgsl_embed.cmake` macro (build-time `xxd -i` → C++ string constants).
4. C++-side `static_assert` that any shared struct (Camera, Splat, etc.) has the same byte layout as Brush's WGSL definition — catches divergence at build time, not at first GPU run.
5. Compile via Dawn Tint at runtime; assert zero compilation warnings (`WGPUShaderModuleDescriptor.compilationInfoCallback`).

**Verification**: 4 shader modules build at runtime + render pipeline state objects create without error + sanity-render `synthetic_smoke.ply` looks like a splat (NaN-free, recognizable structure).

**Per-step abort signal**: any of the 4 kernels fails Tint compile → BACKLOG entry. **Do NOT translate the math to "fix" it** — Brush's math is the reference. If Tint reports an error, the binding layout adapter is wrong, not the math.

---

### 6.3b — Adapt Brush 3 training kernels (v2)

**Input**:
- Brush training kernels (in `crates/brush-render/src/shaders/`): forward + backward + densify
- `aether_cpp/include/aether/training/gaussian_training_engine.h` for our binding layout
- `aether_cpp/include/aether/training/mcmc_densifier.h` and `steepgs_densifier.h` for the densification API expected by aether_cpp

**Action**:
1. Vendor 3 .wgsl files into `aether_cpp/shaders/wgsl/training_*.wgsl` with attribution headers.
2. Same math-1:1 / binding-only-rewrite principle as 6.3a.
3. Atomic-op audit: list every `atomicAdd`, `atomicCompareExchangeWeak`, etc. in Brush's training shaders. WGSL atomic surface is well-defined (no MSL-specific atomics needed because we're starting from WGSL). Should be a clean compile.
4. Embed via `wgsl_embed.cmake`.
5. Runtime smoke: pass a dummy gradient buffer through `aether_train_step` FFI; verify GPU buffer shape preserved + no crash + no NaN. **Convergence not validated this phase per C.**

**Per-step abort signal**: WGSL atomic op missing in Tint's lowering for a target backend (Metal-specific issue) → split kernel pass + BACKLOG entry. Not phase降级.

---

### 6.4 — Wire to PocketWorld (v2 with 3 file formats)

**iOS** (`pocketworld_flutter/ios/Runner/`):
1. `MetalRenderer.swift`: replace direct `MTLDevice` / `MTLCommandQueue` creation with FFI call → opaque `DawnGPUDevice` handle.
2. `AetherTexturePlugin.swift`: add method-channel handlers:
   - `loadSplat(path, format)` where format ∈ {`ply`, `spz`, `splat`} → calls one of `aether_splat_load_ply`, `aether_splat_load_spz`, `aether_splat_load_splat`
   - `trainStep(args)` → calls `aether_splat_train_step`
3. `lib/main.dart`: file picker accepts `.ply` / `.spz` / `.splat`; render result in existing 256×256 Texture widget; expose splat scale to fullscreen.

**macOS** (`pocketworld_flutter/macos/Runner/MainFlutterWindow.swift`): symmetric port.

**Verification**: app launches, file picker opens, all 3 formats load without crash, Texture widget shows non-blank output for each format.

---

### 6.5 — Cross-validation against MetalSplatter (v2)

**Setup** (one-time):
1. Fork `scier/MetalSplatter` to user's GitHub. Pin commit hash in `CROSS_PLATFORM_STACK.md`.
2. In the fork, add IOSurface raw-RGBA dump path (Phase 4/5 IOSurface experience reusable). Approximate budget: 50–80 lines of Swift in MetalSplatter's view controller, gated by a debug build flag so the production App Store version stays untouched.
3. Build forked MetalSplatter for iPhone 14 Pro real device.

**Test matrix** (20 scene/camera pairs):
- 3 scenes: `synthetic_smoke.ply` (~100 Gaussians) + `garden_50k.ply` (Mip-NeRF 360 garden subset) + `garden_500k.ply` (full Mip-NeRF 360 garden)
- 20 camera angles per scene (12 azimuth at 0° elevation; 4 azimuth × 2 elevation at ±45°)

**Method per (scene, camera) pair**:
1. Render in MetalSplatter (forked) on iPhone 14 Pro → save raw RGBA dump from IOSurface
2. Render in PocketWorld (Dawn → adapted Brush WGSL → Metal-via-Tint) on the same iPhone → save raw RGBA dump
3. Run `scripts/cross_validate_vs_metalsplatter.py` → emit per-pixel max abs diff, PSNR, SSIM, splat-count match

**Per-step abort signal**: any pair fails any threshold (≤2/255 max diff, ≥50 dB PSNR, ≥0.9995 SSIM, exact splat-count match) → 6.3 regression. Diagnose which kernel differs by binary-searching the pipeline (cull only? project only? rasterize only?). Do NOT relax thresholds.

---

### 6.6 — Quality gate execution (v2 — 6 axes upgraded)

Run all 6 axes (Axis A pixel oracle / Axis B training plumbing / Axis C Mobile-GS perf / Axis D Phase 5 7-axis / Axis E architectural / Axis F docs). Each passes/fails independently, all must pass. Documented in `aether_cpp/PHASE6_DONE.md` mirror of Phase 5 DoD record.

---

## Definition of Done — 6-axis gate (v2 — industry SOTA bar)

| Axis | Threshold | Source |
|---|---|---|
| **A — Pixel cross-val vs MetalSplatter** | All 20 (scene, camera) pairs pass: per-pixel max abs diff ≤ 2/255 + PSNR ≥ 50 dB + SSIM ≥ 0.9995 + exact splat-count match | v2 user prompt; MetalSplatter App Store-shipped |
| **B — Training plumbing** | FFI buffer round-trip preserves shape, no crash, no NaN. Convergence DEFERRED per C | Phase 6 v2 user prompt |
| **C — Mobile-GS perf bar** | iPhone 14 Pro: ≥60 FPS × 60 s @ 50k Gaussians; ≥30 FPS × 30 s @ 500k; cold launch ≤2 s; GPU mem ≤250 MB @ 500k; app size ≤+50 MB vs Phase 5. iPhone 12: ≥30 FPS @ 50k | Mobile-GS paper (116 FPS @ 1600×1063 on Snapdragon 8 Gen 3) |
| **D — Phase 5 7-axis lifecycle** | All 7 axes from PHASE5_PLAN.md DoD re-executed with splat workload (frame stability / GPU mem leak / CPU+RAM leak / thermal / background / memory warning / cold launch) | Phase 5 PHASE5_PLAN.md DoD |
| **E — Architectural principles** | Zero new .metal files outside legacy; all new shader = WGSL adapted from Brush with attribution headers; zero algorithm math in .swift; zero `-Wno-*` added; Phase 4 4-axis + Phase 5 lifecycle patterns applied; Brush commit hash pinned in CROSS_PLATFORM_STACK.md | Phase 6 prerequisite locked in BACKLOG + v2 prompt Axis E |
| **F — Documentation** | PHASE6_DONE.md (Brush adaptation diary + cross-val PNG/diff evidence + Mobile-GS perf numbers + axis pass/fail) + BACKLOG updates with deferred-validation triggers + CROSS_PLATFORM_STACK.md (Brush pin + MetalSplatter pin + Phase 6 lessons) + LICENSE-Brush at repo root + per-file Brush attribution | Phase 5 docs precedent + v2 prompt Axis F |

---

---

## v3 architecture deep-dive (2026-04-26 user upgrade)

### Why v3 changes the viewer rasterizer (industry evidence)

**Trigger fact A — cross-platform mobile compute rasterizer is unstable:**

| GPU family | compute path status | Source |
|---|---|---|
| Apple A/M-series (TBDR) | works but 1.5–3× slower than vert+frag | papers + MetalSplatter App Store track record |
| Qualcomm Adreno (TBR) | **training crashes 5–750 steps** | [Brush Issue #77](https://github.com/ArthurBrussee/brush/issues/77) |
| ARM Mali (TBR) | unmeasured, TBR-architecture inferred | — |
| HiSilicon Maleoon (TBR) | **Vulkan compute disabled in Flutter** | [Flutter Issue #157811](https://github.com/flutter/flutter/issues/157811) |
| Web (WebGL2 fallback) | **no compute at all, only vert+frag** | WebGL2 spec |

**Trigger fact B — industry evidence is one-sided:**

| Source | Test | Result |
|---|---|---|
| GauRast (NVIDIA Research) | desktop vs custom raster | raster **23× faster** than compute |
| C3DGS (Niedermayr) | A5000 desktop | raster **3.5× faster** |
| WebSplatter (arxiv 2602.03207) | Snapdragon 8 Gen 3 + iPhone 15 | "raster substantially better" |
| PlayCanvas SuperSplat v2.17 | production viewer | **actively reverted from compute → instanced quads** |
| Spark.js / antimatter15-splat / MetalSplatter / Scaniverse | all production viewers | all chose vert+frag + instanced quads |

**Reverse evidence (compute beating vert+frag in any scenario): zero.**

**Conclusion**: viewer rasterizer = vertex+fragment + instanced quads.

### Viewer data flow (v3 — replaces v2's all-compute pipeline)

```
PLY/SOG file
  ↓
[CPU upload] splats → GPU storage buffers (means, quats, scales, opacities, sh_coeffs)
  ↓
[Compute] project_forward.wgsl
  ├─ in:  splat 3D data + camera RenderUniforms
  └─ out: depths[], xys[], conics[], colors[]    (small storage write, cross-platform stable)
  ↓
[Compute] project_visible.wgsl
  ├─ in:  depths/xys/conics/colors + frustum
  └─ out: compact_gid[]  (visible splats, frustum cull + opacity check)
  ↓
[Compute] Brush radix sort (5 kernels + 3 prefix_sum)
  ├─ in:  compact_gid[] + depths[]
  ├─ mod: sort key changes from (tile_id, depth) → depth-only (single 32-bit key)
  └─ out: sorted_compact_gid[]
  ↓
[Vertex+Fragment]  splat_render.wgsl   ← only new code, ~80 WGSL lines
  ├─ Vertex shader:
  │     - vertexID % 4 → emit instanced quad's 4 corners
  │     - instanceID → index sorted_compact_gid → fetch xy, conic, color
  │     - output quad-corner screen position + conic + color/opacity
  ├─ Fragment shader:
  │     - σ = 0.5(conic·Δ²) + conic_xy·Δx·Δy
  │     - α = opacity · exp(-σ),  min(0.999)
  │     - early discard if α < 1/255
  │     - output vec4(color * α, α)  → hardware ROP front-to-back blend
  └─ Render target: RGBA8 IOSurface-backed MTLTexture
  ↓
[GPU→CPU zero-copy] IOSurface ↔ Flutter Texture widget (reuse Phase 4/5 path)
  ↓
screen
```

**Note:** vert+frag path does NOT need `map_gaussian_to_intersects.wgsl` (tile mapping serves only the tile-based compute rasterizer). That file stays in repo as a training-path asset.

### Brush 14 file retention matrix (algorithm base preserved 100%)

| File | Mobile viewer (P6) | Mobile training (P7+) | Server training (P6.7) | Notes |
|---|---|---|---|---|
| project_forward.wgsl | ✅ | ✅ | ✅ | Small storage write — cross-platform stable |
| project_visible.wgsl | ✅ | ✅ | ✅ | Same |
| map_gaussian_to_intersects.wgsl | ❌ | ✅ | ✅ | Viewer skips (no tile mosaic in vert+frag); training needs it |
| rasterize.wgsl | ❌ | ✅ | ✅ | Viewer replaces with splat_render.wgsl; training keeps it |
| project_backwards.wgsl | — | ✅ | ✅ | Training-only, gradient backprop must be compute |
| rasterize_backwards.wgsl | — | ✅ | ✅ | Same; Adreno crash risk point (Phase 7 fallback to cloud) |
| 5 sort kernels | ✅ | ✅ | ✅ | General-purpose GPU radix sort primitives |
| 3 prefix_sum kernels | ✅ | ✅ | ✅ | Sort dependencies |
| 🆕 splat_render.wgsl | ✅ | — | — | New, vertex+fragment, ~80 lines (Aether3D-original) |

**Net result:** mobile WGSL count = 14 (Brush) + 1 (new) = **15 files**, **0 deletions**. Phase 7 on-device training enable triggers all 14 Brush files unchanged.

### Freemium training tier (v3 business model)

**Trigger:** Of 4 main competitors, **only Scaniverse trains on-device** (Niantic blog: "100% local"). Polycam / KIRI / Luma all cloud. Scaniverse quality < Polycam/Luma (1-min iteration vs H100-multiminute).

**PocketWorld dual tier:**

| Tier | Train where | Speed | Quality | Eligible devices | Cost |
|---|---|---|---|---|---|
| **Free** | on-device | ~1–3 min | Mid (compute limited) | See device matrix | User battery, zero marginal cost to us |
| **Paid** | cloud (vast.ai A100/H100) | ~30 s – 3 min | High (more iterations + bigger splat counts + higher SH) | Any net-connected device | ~$0.05–0.20/run |

**Why this is the national-grade path:**
- Free covers **new-device users** (~70% traffic, Scaniverse model)
- Paid serves **older devices + high-quality wants** (revenue path)
- Existing infra zero-new-cost: vast.ai A100/H100 worker already rented for VGGT pipeline; add Brush training stage
- Network-disconnect free-tier degrades gracefully (offline-album analogy)

### Device capability matrix (Phase 7 on-device training enable conditions)

| Device class | GPU | Status | Path | Notes |
|---|---|---|---|---|
| iPhone 12+ / iPad M1+ | Apple A14+ / M1+ | ✅ enable local | Brush full compute | macOS desktop already validated compute stable |
| Mac M1+ (dev/desktop) | Apple Silicon | ✅ enable local | Brush full compute | desktop high quality, no timebox |
| Snapdragon 8 Gen 2/3 (Adreno 740/750) | Adreno TBR | ⚠️ try-enable + fallback | Brush full compute, crash auto-fallback to cloud | Brush #77 risk, real-device gradual rollout |
| Snapdragon X Elite (Adreno 8xx) | Adreno new driver | ⚠️ try-enable + fallback | Same | Driver may have fixed; real-device test |
| Mid-range Snapdragon (Adreno 7xx older) | Adreno old | ❌ default cloud-only | — | UI: "local training needs newer device or choose cloud" |
| Mali (Galaxy / Pixel / Xiaomi) | Mali TBR | ⚠️ default cloud, P8 real-device test | — | No public 3DGS Mali measurements |
| HarmonyOS Maleoon (Mate 60+, Pura 70) | Maleoon TBR | ❌ default cloud-only | — | Vulkan compute disabled in Flutter |
| Old Android (Snapdragon 7xx and below) | Various older | ❌ cloud-only | — | Compute + memory insufficient |
| Web (Chrome/Safari/Edge) | WebGL2 / WebGPU | ❌ cloud-only | — | WebGL2 has no compute, WebGPU not yet ubiquitous |

### Phase 6.3a Step plan (v3 — replaces v2 step list)

| Step | Content | Timebox | DoD |
|---|---|---|---|
| Step 1 ✅ | DawnKernelHarness + project_forward smoke | done | 5-layer chain PASS (8ab52bbd) |
| Step 2 ✅ | project_visible smoke | done | xy/conic/color expected values PASS (9ac19b32) |
| Step 3 ✅ | map_gaussian_to_intersects smoke | done | num_intersections PASS (viewer skips, training needs) |
| Step 4 ✅ | 🆕 splat_render.wgsl + harness vert+frag extension | done | 4 splats → 256×256 RGBA8 — center=(162,162,162,254), corner=(0,0,0,0), Gaussian falloff confirmed |
| Step 5a ✅ | 5 sort kernels (count/reduce/scan/scan_add/scatter) | done | all 5 PASS — element conservation, monotone, multiset preserved |
| Step 5b ✅ | 3 prefix_sum kernels (scan/scan_sums/add_scanned_sums) | done | all 3 PASS — inclusive scan correct, sums-scan correct, per-WG add correct |
| Step 6 ✅ | rasterize.wgsl + rasterize_backwards.wgsl | done | forward center pixel matches splat_render within 1 LSB; backward atomic gradients flowed (v_splats 32/32, v_opacs 4/4) |
| Step 7 ✅ | project_backwards.wgsl | done | gradients reasonable (v_means RMS=62.35 matches pinhole chain rule, v_quats=0 at identity, no NaN) |

**Phase 6.3a DoD (v3): ✅ 14 + 1 = 15 WGSL files all 5-layer-chain PASS via host smoke (Apple Silicon Dawn iOS Metal).** Adreno crash mitigation cannot be validated on macOS smoke; that's Phase 7 real-device territory.

### Risk + fallback matrix

| Risk | Severity | Fallback |
|---|---|---|
| splat_render.wgsl math error → visual artifacts | High | Phase 6.5 cross-val vs MetalSplatter, diff thresholds locked |
| Mali / Maleoon real-device measurement still vert+frag-slow | Medium | Phase 7 real-device gradual rollout; current reverse evidence is zero |
| Brush sort key restructure introduces bug | Medium | Step 5 smoke covers (random input + verify sorted monotone) |
| Phase 7 Adreno on-device training crash unfixable | Medium | Device matrix retreat to cloud fallback; business model unaffected |
| Server training cost runaway | Medium | Limit free-tier monthly count, paid subscription amortizes; tier by splat count |
| Upload 50–200 photos bandwidth | Low | Client-side resize + WebP, drops to 50–100 MB |
| Brush upstream version bump → naga_oil re-process | Low | Path G ETL automated, `cargo run --release` re-runs |
| MetalSplatter App Store version drift breaks cross-val baseline | Low | Lock Phase 6.5 MetalSplatter commit hash in CROSS_PLATFORM_STACK.md |

### Locked decision pins (v3 — architectural; cannot regress)

1. ✅ viewer rasterizer = vertex+fragment + instanced quads (MetalSplatter style)
2. ✅ `splat_render.wgsl` is Phase 6's only new WGSL file
3. ✅ All 14 Brush WGSL files retained — algorithm base does not contract, only execution order shifts
4. ✅ Freemium training tier — local free (P7 enable) + cloud paid (P6.7 immediate)
5. ✅ Device capability matrix + cloud fallback — Adreno/Maleoon orchestrated to cloud, no forced on-device
6. ✅ Server training reuses vast.ai A100/H100 worker — zero new infrastructure cost
7. ✅ Cross-platform single codebase — iOS/Android/HarmonyOS/Mac/Web share the same 15 WGSL; glue is Swift/Kotlin per platform
8. ✅ WGSL is the single source of shader truth — no parallel .metal / .glsl / .hlsl path
9. ✅ Phase 6.5 cross-val baseline = MetalSplatter App Store version (architectural match → diff = FP rounding only)
10. ✅ National-grade principle non-negotiable: stability >> flexibility, quality >> speed, cross-platform >> single-platform optimization

### Decision audit (for future-self / handoff)

**Why not v2 (full Brush compute viewer)?**
> Brush #77 Adreno crash + Maleoon Vulkan compute disabled = cross-platform viewer dataflow broken. National-grade "不挑设备 + 多人在线稳定" principle violated. MetalSplatter App Store proven 1+ year + PlayCanvas SuperSplat actively reverted compute→instanced quads = industry-aligned conclusion.

**Why not abandon Brush entirely (only MetalSplatter style)?**
> Brush provides: (1) project + sort math validated; (2) backward training gradient kernels; (3) actively maintained algorithm base. Abandoning = losing Phase 7 on-device training + Phase 6.7 server training algorithm grounding, plus self-maintenance burden. "hybrid keep 14 + write 1" is minimum-cost cross-platform path.

**Why not cloud-only (drop on-device algorithm base)?**
> Business model needs freemium tier — Scaniverse proven free-on-device is user-acquisition entry. Removing backward kernels = permanently shutting off free tier = business model castrated. Algorithm-base preservation cost is tiny (smoke 1.5h × 2 step), benefit is future commercial flexibility.

**Why this timing: viewer P6, cloud-train parallel P6.7, on-device-train deferred P7?**
> Hot-path priority: viewing >> creating. All users view, only some create. Phase 6 done = product immediately usable (cloud training already in place). On-device training waits for real-device gradual data + business metric proving free tier has value, avoiding sunk cost.

---

## Out of scope (Phase 6 explicitly excludes)

- ❌ Cross-validation against TestFlight Aether3D (deprecated per A; replaced by MetalSplatter)
- ❌ Training convergence verification (deferred per C — waits for Phase 7+ UI + real test data captured by user)
- ❌ Android Vulkan / HarmonyOS port (Phase 7+; Phase 6 closes the iOS WGSL→Dawn→Metal path, sets architectural template for Android/HarmonyOS)
- ❌ HDR / wide-gamut color (Phase 7+ visual polish)
- ❌ App Store submission (Phase 6 = device-deploy quality, not store-ready)
- ❌ LoD streaming (Spark 2.0 reference; Phase 7+ scaling)
- ❌ Foveated rendering / pruning optimizations (RTGS / Fov-3DGS reference; Phase 8+ optimization)

---

## Cross-cutting risks

**R1: Dawn IOSurface interop may not exist publicly.** Phase 4 used IOSurface as the zero-copy bridge between Metal-rendered texture and Flutter. Dawn's public WebGPU API may not expose IOSurface; we may need Dawn-internal API or a Metal-Dawn interop side door. Mitigation: 6.2's per-step abort signal triggers BACKLOG entry; possible workaround is "fall back to plain `MTLTexture` interop, bypass Dawn's texture API for the Flutter handoff path only" (the renderer still uses Dawn for everything else).

**R2: WGSL atomic-op set is smaller than MSL.** GaussianTraining.metal uses Metal-specific atomic patterns (e.g. `metal::atomic_compare_exchange_weak_explicit` with memory orders). WGSL has fewer atomic primitives. Mitigation: 6.3b's atomic audit flags missing ops; workaround is re-architect that section (split kernel into multiple passes) — each missing op is a 1-day add to 6.3b.

**R3: Phase 5 BACKLOG entries cascade.** The Flutter `flutter clean` + `e283edd478f14e25f0fd14b4b118ed7e` symlink workaround, the `xattr -d` race-window codesign, the `-Wl,-u` dead-strip guard — these all lurk and may resurface during 6.0 / 6.4 builds. Mitigation: Phase 5 lessons learned section in `phase5_dod.md` is the lookup table.

**R4: Multi-session reality.** Per F, Phase 6 cannot complete in one session. Each session must end at a clean state (last commit pushed; current sub-step either fully done or rolled back). 04:00 hard stop applies per-session, not per-phase.

---

## Active execution log

(Newest at top. Updated as sub-steps complete.)

- **🎯 PHASE 6.4e MILESTONE REACHED 2026-04-27 (commit `7094854b`; verification PASS after follow-up fixes `438311b9`, `a4456fc9`, `b8c9f95f`)** — Lifecycle observer + persistence + future background interfaces landed for PocketWorld Batch 2. Dart now owns app lifecycle via `LifecycleObserver` (`AppLifecycleState` → save/restore + native `pauseRendering` / `resumeRendering`), using versioned SharedPreferences keys `pocketworld.orbit_state.v1` and `pocketworld.object_state.v1`. macOS plugin accepts pause/resume calls; iOS plugin routes the same calls through the existing Phase 5.3 displayLink lifecycle / thermal policy path, with existing memory-warning disposal preserved. `shared_preferences` macOS CocoaPods integration is committed (`Podfile`, `Podfile.lock`, generated plugin registrant, workspace/project pod phases). Phase 7/6.7 interface-freeze stubs added for background downloads and training checkpoints; both log loudly and return failure/no-op handles (no real BGURLSession/checkpoint serialization yet, by design). Verification: `flutter build macos --debug` ✅; `cmake --build .` ✅; full native smoke `PASS=28 FAIL=0` ✅; `flutter run -d macos` logs `LifecycleObserver restore complete`, RGBA16F scene renderer create, GLB load success, and steady 60 fps. User verified helmet appears, single-finger orbit direction is correct on both axes, pan/zoom are correct, background → foreground restores the pose, and Cmd+Q relaunch restores orbit/object state.
- **Batch 2 trail 2026-04-26 → 2026-04-27** — 6.4d.1 WCG/RGBA16F shipped in `d584a659`; direct-launch dylib and BGRA Flutter texture fallback fixes shipped in `46ad2898` and `c3dc7a2d`; 6.4d.2 DRS/MetalFX/tier detection shipped in `f036c8b6`. Runtime note: current app path keeps native render/display size at 256×256 to preserve smoothness while the DRS controller and MetalFX wrappers are staged; 8K/large-surface upscaling remains out-of-scope for Batch 2 and tracked separately. Review alignment: Flutter macOS compositor still requires BGRA8 display fallback, so WCG/RGBA16F is proven in Dawn/smoke but not visually observable in production UI yet; MetalFX is proven by `pocketworld_flutter/macos/Runner/SmokeTests/MetalFXInteropSmoke.swift`, while production 256×256 frames usually use simple blit because render size equals display size. The staged C++ `DrsController` / `DeviceCapabilities` headers were removed after review because Swift owns Batch 2 frame timing and macOS capability detection.
- **🎯 PHASE 6.4b stage 2 MILESTONE REACHED 2026-04-26 (commit pending)** — IOSurface scene renderer (mesh PBR + splat overlay) shipped. DamagedHelmet.glb renders + responds to single-finger orbit / two-finger dolly+pan+rotate gestures at 60 fps stable in PocketWorld macOS. **Splat overlay STAYS pinned** at hardcoded screen-space (128, 128) — splat world-space + gesture-responsiveness is locked in PHASE_BACKLOG.md as Phase 6.4f (Brush full pipeline integration); not in scope here. Stage breakdown:
  - Stage 2.A obsoleted: Phase 6.4b stage 2 originally planned to extend the GPUDevice virtual API (depth attachment, sampler binding, texture binding, vertex-buffer-layout) but doing so would have inflated the public surface for a single-call site. Decision: write `scene_iosurface_renderer.cpp` fully Dawn-direct via a narrow internal-only header `src/render/dawn_gpu_device_internal.h` that exposes 7 WGPU handle accessors (device/queue/instance/buffer/texture/render_pipeline/shader_module) under `aether::render::internal::`. App code can't include it (under `src/`); only same-library TUs do. The public GPUDevice abstraction stays unchanged.
  - Stage 2.B ✅ scene_iosurface_renderer.{h,cpp} (~1000 LOC) — 2-pass IOSurface render: pass 1 mesh PBR (mesh_render.wgsl Filament BRDF, sampling 5 PBR slots with 1×1 white/flat-normal/black fallbacks) writes color + depth; pass 2 splat overlay (splat_render.wgsl) loads color + depth, no depth write, premultiplied alpha. Mesh pipeline created via raw `wgpuDeviceCreateRenderPipeline` with explicit 48-byte MeshVertex layout. 4 mesh uniform buffers (camera 80B / model_xform 128B / light 48B / pbr_factors 48B). Per-frame: BeginAccess → mesh pass → splat pass → submit + WaitAny → EndAccess. Builds clean on host.
  - Stage 2.C ✅ Swift glue swap — MainFlutterWindow.swift dlsym'd symbols changed `aether_splat_renderer_*` → `aether_scene_renderer_*`. Time-based `_render(t)` dropped (only `render_full(view, model)` retained). Added `loadGlb(path)` method on SharedNativeTexture and a `loadGlb` MethodChannel handler (Dart sends `{textureId, path}`; failure returns FlutterError with stderr-pointing diagnostic).
  - Stage 2.D ✅ Dart loadGlb wiring — `_loadDefaultGlb` searches 4 candidate paths for DamagedHelmet.glb (cwd / cwd/.. / cwd/../.. / dev abspath), pushes via MethodChannel after texture create, surfaces success/failure as a small label above the texture. Initial `_pushMatrices()` call landed BEFORE first display-link tick so the renderer doesn't render with identity view (camera-inside-helmet → black) on frame zero — fix verified end-to-end by user.
  - Stage 2.E ✅ verification — `flutter run -d macos` builds clean, dlopen succeeds, `[Aether3D][scene_renderer] loaded GLB ...DamagedHelmet.glb (1 primitives, 1 materials, bounds [-0.95..0.94])` lands, `[AetherTexture] 60.0 fps` steady. setMatrices logs show distance changes (5 → 0.5 → 50 → 2.65 …) on real gestures. User confirmed helmet renders + is gesture-responsive.
  - Stage 2.F ✅ this entry + commit.
  - DawnGPUDevice tweak shipped en route: `create_texture` now skips CopySrc / CopyDst / TextureBinding usages for `kDepth32Float` and `kDepth32Float_Stencil8` (Dawn rejects those on depth formats). Refactor: extracted `dawn_device_singleton.{h,cpp}` from `splat_iosurface_renderer.cpp` so both renderers share the same refcounted singleton (acquire/release at create/destroy).
- **🎯 PHASE 6.2.G-K MILESTONE REACHED 2026-04-26 (commit pending)** — DawnGPUDevice production-path implementation complete. All 9 design steps shipped (limits/features → shader registry → compute pipeline → render pipeline w/ premultiplied alpha → texture w/ readback → DawnComputeEncoder → DawnRenderEncoder → DawnCommandBuffer + commit/wait → virtual readback_texture on GPUDevice). 3 sentinel smokes migrated through GPUDevice virtual API:
  - `project_forward_via_device`: depths=[2.000,4.000,6.000,8.000] BIT-EXACT match with harness smoke 1
  - `render_via_device`: center pixel (162,162,162,254) within 1 LSB of harness smoke 4
  - `cross_validate_via_device`: 99.9573% of 65536 pixels within 1 LSB, max diff 2 LSB, 0 pixels with diff > 2 — IDENTICAL to harness cross_validate result through production path
  All 16 harness smokes still PASS (no regression). Total 20/20 smokes PASS (16 harness + 4 production-path). Cross-platform `aether3d_core` (-fno-exceptions/-fno-rtti) builds clean. Bisect range for Phase 6.4: strictly the integration code wiring DawnGPUDevice into PocketWorld viewer; every WGSL kernel + GPUDevice virtual method now independently proven equivalent across paths.
- **🎯 PHASE 6.3a MILESTONE REACHED 2026-04-26 (commit `e3ab0fb3`)** — 15 of 15 WGSL files all 5-layer-chain validated end-to-end (Brush WGSL → naga_oil → Tint → Dawn → Apple Silicon Metal). Steps 4, 5a, 5b, 6, 7 all PASS in a single session. 5-layer bisect range proven workable: 4 distinct issues found and surfaced loudly by the harness's SetUncapturedErrorCallback abort path (atomic-in-readonly-storage, workgroup_size_512 cap, subgroups feature opt-in, subgroup uniformity strictness). Bug bisection range now strictly = "wrapper integration" for Phase 6.4. Commit log: 8ab52bbd (Step 1) → 9ac19b32 (Steps 2-3) → ad762f0c (Step 4) → e671713a (Step 5a) → 076da2b7 (Step 5b) → 5ddfd30c (Step 6) → [Step 7 + milestone].
- **Step 7 ✅ DONE 2026-04-26** — project_backwards.wgsl smoke (10 bindings, 4 splats, synthetic v_grads). Gradients ∂L/∂Gaussian land cleanly: v_means RMS=62.35 with first=(128, 128, ~0) — matches pinhole chain rule (∂projected_xy/∂mean_xy = focal/depth = 256/2 = 128 at unit gradient); v_quats=0 at identity quaternion (zero rotation gradient at optical axis is mathematically correct); v_scales RMS=0.0009; v_coeffs RMS=0.282. No NaN/Inf in any output. 32 nonzero entries.
- **Step 6 ✅ DONE 2026-04-26** (commit `5ddfd30c`) — Brush rasterize forward + rasterize_backwards backward smokes. Forward center pixel (162,162,162,253) matches splat_render.wgsl smoke (162,162,162,254) within 1 LSB FP rounding — Brush compute and Aether3D vert+frag agree on Gaussian math. Backward gradient atomic accumulation observable (v_splats 32/32, v_opacs 4/4 nonzero). Three Dawn-iOS issues surfaced + workarounds locked in: (1) `enable subgroups;` directive needs prepending, (2) `diagnostic(off, subgroup_uniformity);` for Tint's strict uniformity check, (3) bumped maxStorageBuffersPerShaderStage to 10, (4) FeatureName::Subgroups required.
- **Step 5b ✅ DONE 2026-04-26** (commit `076da2b7`) — 3 prefix_sum smokes. prefix_sum_scan: out=[1,2,...,64] for input=[1; 64] (inclusive scan correct). prefix_sum_scan_sums: input[511]=10, [1023]=20 → out[0..5]=[0,10,30,30,30] (scan-of-sums correct). prefix_sum_add_scanned_sums: WG0 stays at 1, WG1 becomes 101 (per-WG add correct). Workgroup_size 512 required harness::init() bump of maxComputeInvocationsPerWorkgroup + maxComputeWorkgroupSizeX.
- **Step 5a ✅ DONE 2026-04-26** (commit `e671713a`) — 5 Brush radix-sort smokes (count, reduce, scan, scan_add, scatter). 256 random u32 keys (mt19937 seed=42), 1 block. sort_count: 16 bin counts sum to 256. sort_scatter: full pipeline, multiset preserved + 4-bit window monotone (first 8 in bin 0, last 4 in bin 15). False alarm "Dawn auto-layout heisenbug" turned out to be my shell loop passing wrong WGSL paths per smoke argv contract; smokes themselves are correct.
- **Step 4 ✅ DONE 2026-04-26** (commit `ad762f0c`) — splat_render.wgsl (Aether3D-original, 116 lines, vertex+fragment + instanced quads, MetalSplatter/Spark/PlayCanvas-aligned) + DawnKernelHarness vert+frag extension (`alloc_render_target`, `load_render_pipeline` with premultiplied-alpha blend, `dispatch_render_pass`, `readback_texture` with 256-byte row alignment + unpadding) + smoke test (4 splats, hardcoded project_visible output, RGBA8Unorm 256×256 readback verifies non-black at center, black at corner, Gaussian falloff at mid-radius). PASS first-try after one Tint validation catch (`atomic<u32>` not allowed in `<storage, read>` binding — switched to plain `u32`, identical layout). Uncaptured-error callback caught it cleanly; harness P1 fix earned its place. Re-ran 3 prior smokes after harness changes — no regression.
- **PHASE6_PLAN v1 → v2 in-place upgrade 2026-04-26 ~10:35** — user issued v2 prompt: shader source = Brush adapt (Apache-2.0, gSplat-paper math); cross-val oracle = MetalSplatter (MIT, App Store-shipped); perf bar = Mobile-GS (60 FPS @ 50k on iPhone 14 Pro); 3 file formats (.ply + .spz + .splat); ≤50 MB app size; LICENSE compliance. v1 work (6.0/6.1/6.2.A-F) carries forward unchanged. v2-only sub-step changes: 6.3a/b (Brush adapt) + 6.5 (MetalSplatter cross-val) + 6.6 (upgraded 6-axis gate). Locked decisions A/B updated; G/H/I added.
- **6.2.F (DawnGPUDevice buffer impl) ✅ DONE 2026-04-26 ~10:30** (commit `4a8f2cc6`) — hybrid stability strategy locked by user: `update_buffer` = wgpuQueueWriteBuffer (HOT, zero-block); `map_buffer` for staging-read = wgpuBufferMapAsync + WaitAny spin (RARE); `map_buffer` for write = warn-once + nullptr (callers must use update_buffer). Factory init via wgpuCreateInstance with TimedWaitAny feature + sync RequestAdapter/RequestDevice via WaitAny. ~600 lines, host build clean. Telemetry: `spin_wait_count()` accessor.
- **PHASE6_PLAN v2 → v3 in-place upgrade 2026-04-26 ~12:30** — user issued v3 prompt: viewer rasterizer changes from "all Brush compute" to "vertex+fragment + instanced quads" (MetalSplatter / Spark.js / PlayCanvas SuperSplat industry alignment). Decisions A-I retained; J/K/L/M/N added. Brush 14 WGSL files all retained (algorithm base preserved for Phase 7+ on-device training); new `splat_render.wgsl` (~80-line vertex+fragment, Aether3D-original) is Phase 6's only new shader file. Freemium training tier locked (P7 local + P6.7 cloud A100/H100 via vast.ai). Industry evidence: GauRast 23× / C3DGS 3.5× / WebSplatter / PlayCanvas SuperSplat v2.17 (compute → instanced quads regression) / Brush #77 (Adreno crash) / Flutter #157811 (Maleoon Vulkan compute disabled). Phase 6.3a Steps 1-3 (project_forward / project_visible / map_gaussian) carry forward unchanged; map_gaussian smoke retained because it serves the training path even though viewer skips it.
- **Plan B Step 2+3 ✅ DONE 2026-04-26 ~12:00** (commit `9ac19b32`) — project_visible smoke (8-buffer bind, xy/conic/color bit-exact correct) + map_gaussian_to_intersects smoke (6-buffer bind incl read-only uniforms; num_intersections=16 matches cum[num_visible], all tile_ids/compact_gids in valid range). Shared C++ struct mirrors extracted to `aether_cpp/tools/aether_dawn_splat_test_data.h`.
- **Phase 6.3a P1+P2 review fixes ✅ DONE 2026-04-26 ~11:45** (commit `2657ee00`) — SetUncapturedErrorCallback registered on DawnGPUDevice descriptor (silent-validation-failure firewall) + RenderUniforms→RenderArgsStorage rename to disambiguate storage vs uniform.
- **Plan B Step 1 (DawnKernelHarness + project_forward smoke) ✅ DONE 2026-04-26 ~11:30** (commit `8ab52bbd`) — first 5-layer chain validation. Brush WGSL → naga_oil → binding layout → Tint → Apple Silicon Metal all proven. depths=2/4/6/8 bit-exact, num_visible=4 atomic correct, no NaN.
- **Path G (vendor-time WGSL preprocessor via naga_oil) ✅ DONE 2026-04-26 ~11:00** (commit `2afaaaaf`) — Cargo crate wgsl_preprocess emits 14 standalone WGSL files from 17 raw Brush vendored files. naga_oil 0.19 matches Brush v0.3.0 internal use. Demangling regex strips `X_naga_oil_mod_X<base32>X` type-name suffixes. Re-pin = `cargo run --release` + `git diff`.
- **Phase 6 v1 → v2 upgrade (Brush + MetalSplatter + Mobile-GS) ✅ DONE 2026-04-26 ~10:35** (commit `df20e564`) — locked decisions G/H/I added; A/B updated (oracle = MetalSplatter, test data = Mip-NeRF garden + synthetic_smoke).
- **6.2.F (DawnGPUDevice buffer impl, hybrid stability) ✅ DONE 2026-04-26 ~10:30** (commit `4a8f2cc6`) — update_buffer = wgpuQueueWriteBuffer hot path (zero-block); map_buffer staging-read = wgpuBufferMapAsync + WaitAny spin (rare); map_buffer write = warn-once + nullptr (callers must use update_buffer).
- **6.2.A-E (DawnGPUDevice skeleton + CMake wire) ✅ DONE 2026-04-26 ~10:25** — `kDawn` added to `GraphicsBackend` enum (runtime_backend.h); `aether/render/dawn_gpu_device.h` factory header written (mirror of metal_gpu_device.h shape); `src/render/dawn_gpu_device.cpp` skeleton (~330 lines) — class with all GPUDevice virtual overrides as stubs that warn-once via `stub_log_once` and return invalid handles; CMakeLists.txt conditionally adds `dawn_gpu_device.cpp` to `aether3d_core` when `AETHER_ENABLE_DAWN AND TARGET dawn::webgpu_dawn`; `target_link_libraries(aether3d_core PUBLIC dawn::webgpu_dawn)` propagates Dawn to consumers. **Host build verified clean** with full Dawn dep chain compiled. iOS arm64-device `dawn_gpu_device.o` compiles clean too; iOS `aether3d_core` end-to-end blocked on PRE-EXISTING `depth_inference_coreml.mm` iOS 16 availability issue (NOT new from this commit). Phase 6.2.F-K (real impls of buffer/texture/shader/pipeline/command-buffer) replace stubs in subsequent commits.
  - **Side effect handled**: flipping `AETHER_ENABLE_DAWN=ON` in `scripts/build_ios_xcframework.sh` (Phase 6.0 step 1) caused Abseil's CMake C++17 compile-feature probe to fail on iphonesimulator sysroot. Rolled back to `=OFF` so the Phase 5 vendored_libraries deploy path stays green; Dawn iOS still builds via direct `cmake --build aether_cpp/build-ios-{device,sim} --target webgpu_dawn` (proven 2026-04-26 02:49). New BACKLOG entry tracks the Abseil probe regression — needs fix before 6.4 wires Dawn into iOS Pod.
- **6.1 (kWGSL enum) ✅ DONE 2026-04-26 ~03:15** — `kWGSL = 3u` added to `ShaderLanguage` in `aether_cpp/include/aether/render/shader_source.h`. 5 switch statements in `aether_cpp/src/render/shader_source.cpp` (BRDF / BRDF-LUT / BRDF-Poly / SH-eval / flip-rotation utility shaders) given explicit `case ShaderLanguage::kWGSL:` falling through to GLSL with `// TODO Phase 6+: translate <utility> to WGSL` comments — exhausts the switch without breaking `-Werror -Wswitch`. The utility shaders are not yet WGSL-translated; that's deferred to Phase 6+ if/when those utilities are needed in the WGSL pipeline (likely Phase 7+ once basic splat WGSL works). Clean `aether3d_core` build verified on host.
- **6.0 (Dawn iOS unblock) ✅ SUBSTANTIALLY DONE 2026-04-26 ~03:00** — Dawn now compiles for iOS arm64 device + arm64-simulator. Specifics:
  - **Step 1 ✅**: `scripts/build_ios_xcframework.sh` flipped `-DAETHER_ENABLE_DAWN=OFF` to `=ON`; build configures cleanly with Dawn submodule pulled into iOS build tree.
  - **Step 2 ✅**: `cmake --build … --target webgpu_dawn` produces `libwebgpu_dawn_objects.a` (both arches). MetalBackend.mm + webgpu_dawn_native_proc.cpp compile clean for arm64-apple-ios14.0.
  - **Step 3 🟡 PARTIAL**: CMake metadata for iOS app bundle (`MACOSX_BUNDLE`, `XCODE_ATTRIBUTE_PRODUCT_BUNDLE_IDENTIFIER`, `XCODE_ATTRIBUTE_DEVELOPMENT_TEAM`) added to `aether_dawn_hello*` targets in `CMakeLists.txt`. iOS `.app` bundle now produces from CMake. Hello link step fails because Dawn's `webgpu_dawn` umbrella target on iOS doesn't produce `libwebgpu_dawn.a` at the path the linker expects — only the `webgpu_dawn_objects.a` archive exists. This is a Dawn upstream packaging quirk for static-only iOS targets, not a fundamental Dawn-iOS block.
  - **Per-step abort signal**: NOT triggered — Dawn iOS itself works, only the standalone-hello packaging path is blocked. 6.1+ can proceed because 6.2's `DawnGPUDevice` will link via `aether3d_core` (which uses `dawn::webgpu_dawn` interface target, not the umbrella library directly).
  - **Trigger to revisit step 3**: when a CLI verification of Dawn iOS on real device is genuinely needed (e.g. to root-cause a Dawn runtime issue). Workaround: a tiny Swift `dawnHello()` button inside the existing PocketWorld plugin reaches the same goal more naturally — it's already an iOS .app with bundle ID and provisioning.
- **Phase 6 KICKOFF 2026-04-26 ~01:55** — pre-kickoff audit done; PHASE6_PLAN.md written; locked decisions A–F resolved; 6.0 begins next.

---

## Kickoff prompt for next session (when resuming mid-phase)

> "Phase 6 resume. Read PHASE6_PLAN.md execution log + PHASE_BACKLOG.md 'Phase 6 prerequisite (locked)' entry. Continue from the topmost unfinished sub-step in the execution log. Apply the 6-axis quality gate when 6.6 reaches. Halt and dump diagnosis to BACKLOG if any termination condition triggers."

---

## Sources

### v2 references (2026-04-26 ~10:30 user upgrade)

- **Brush** (Apache-2.0) — primary WGSL kernel reference: https://github.com/ArthurBrussee/brush
  - Kernels at `crates/brush-render/src/shaders/`: project_forward / project_visible / map_gaussian_to_intersects / rasterize / training_*
  - Math: gSplat reference kernels (3DGS paper, Kerbl et al. 2023)
- **MetalSplatter** (MIT) — iOS oracle for cross-validation: https://github.com/scier/MetalSplatter
  - Production-validated by App Store review (Vision Pro viewer + OverSoul social app)
- **Mobile-GS** (research, 2024) — performance baseline: https://xiaobiaodu.github.io/mobile-gs-project/
  - 116 FPS @ 1600×1063 on Snapdragon 8 Gen 3 (≈ Apple A16 / iPhone 14 Pro)
- **Spark 2.0** (Phase 7+ scaling reference): https://github.com/sparkjsdev/spark
- **RTGS / Fov-3DGS** (Phase 8+ optimization reference): https://github.com/horizon-research/Fov-3DGS

### v1 sources (carried forward)

- v1 Phase 6 prompt (2026-04-26 ~01:50)
- v2 Phase 6 prompt (2026-04-26 ~10:30)
- `aether_cpp/PHASE_BACKLOG.md` "Phase 6 prerequisite (locked)" entry
- `aether_cpp/PHASE5_PLAN.md` (template for plan structure)
- Pre-kickoff audit findings (2026-04-26 ~01:35 — file existence verification, Dawn submodule iOS readiness check, training engine enumeration)
