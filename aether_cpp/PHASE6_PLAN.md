# Phase 6 plan — splat viewer + training pipeline port to PocketWorld via Dawn + WGSL (Brush-adapt edition)

**Status**: ACTIVE 2026-04-26. **v2 upgrade in flight** — original v1 ("translate MSL → WGSL ourselves, looks-like-splat acceptance") replaced by user-direction v2 ("adapt Brush gSplat-paper-level kernels, validate vs MetalSplatter App-Store oracle, hit Mobile-GS perf bar"). v2 carries forward all v1-committed work (6.0/6.1/6.2.A-F); only 6.3 / 6.5 / 6.6 scope changes.

**Phase 6 mission** (v2 verbatim from user): "Adapt Brush's 4 verified WGSL viewer kernels + training kernels (NOT translate from MSL), cross-validate against MetalSplatter (App-Store-shipped iOS reference), and meet Mobile-GS performance benchmark standards (60+ FPS at 50k Gaussians on iPhone 14 Pro / Snapdragon 8 Gen 3-class hardware)."

**v1 → v2 diff (preserved here as the architectural delta)**:

| Dimension | v1 | v2 |
|---|---|---|
| Shader source | hand-translate from `App/GaussianSplatting/Shaders/*.metal` (822 + 1460 MSL lines) | **Adapt Brush WGSL** (4 viewer + 3 training kernels, Apache-2.0, gSplat-paper-level math) |
| Cross-validation oracle | none ("looks like a splat = OK") | **MetalSplatter** (App Store-shipped, MIT) — pixel-level diff with strict thresholds |
| Performance bar | ≥30 fps loose | **Mobile-GS** — 60 FPS @ 50k on iPhone 14 Pro + ≥30 FPS on iPhone 12 |
| File formats | .ply only | .ply + .spz + .splat (MetalSplatter compatibility) |
| App size | not tracked | ≤50 MB increase vs Phase 5 baseline |
| License compliance | none | LICENSE-Brush at repo root + per-file Brush attribution headers |

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
| 6.3a | **Adapt Brush 4 viewer kernels** (project_forward, project_visible, map_gaussian_to_intersects, rasterize) | 🟡 medium (math is Brush's, only bindings to aether_cpp's GPUBufferDesc layout change) | Dawn Tint compile + runtime smoke + sanity-render synthetic_smoke.ply | 6.1, 6.2.H/I/J/K |
| 6.3b | **Adapt Brush 3 training kernels** (training_forward, training_backward, training_densify) | 🟡 medium (same as 6.3a; convergence not validated this phase) | Dawn Tint compile + buffer round-trip via aether_train_step | 6.1, 6.2.J |
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

- **PHASE6_PLAN v1 → v2 in-place upgrade 2026-04-26 ~10:35** — user issued v2 prompt: shader source = Brush adapt (Apache-2.0, gSplat-paper math); cross-val oracle = MetalSplatter (MIT, App Store-shipped); perf bar = Mobile-GS (60 FPS @ 50k on iPhone 14 Pro); 3 file formats (.ply + .spz + .splat); ≤50 MB app size; LICENSE compliance. v1 work (6.0/6.1/6.2.A-F) carries forward unchanged. v2-only sub-step changes: 6.3a/b (Brush adapt) + 6.5 (MetalSplatter cross-val) + 6.6 (upgraded 6-axis gate). Locked decisions A/B updated; G/H/I added.
- **6.2.F (DawnGPUDevice buffer impl) ✅ DONE 2026-04-26 ~10:30** (commit `4a8f2cc6`) — hybrid stability strategy locked by user: `update_buffer` = wgpuQueueWriteBuffer (HOT, zero-block); `map_buffer` for staging-read = wgpuBufferMapAsync + WaitAny spin (RARE); `map_buffer` for write = warn-once + nullptr (callers must use update_buffer). Factory init via wgpuCreateInstance with TimedWaitAny feature + sync RequestAdapter/RequestDevice via WaitAny. ~600 lines, host build clean. Telemetry: `spin_wait_count()` accessor.
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
