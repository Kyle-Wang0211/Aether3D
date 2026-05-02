# aether_cpp Phase backlog

Deferred non-blocking work, organized by **trigger condition** (not by priority or date).
Items here are NOT lost — they're parked until their trigger fires. If no trigger,
the item shouldn't be here.

---

## Phase 6.2 deferred sub-items (within-phase, not blocked-on-user)

### Dawn iOS Abseil C++17 compile-feature probe regression
- **What**: When `AETHER_ENABLE_DAWN=ON` is set for iOS sim builds via `scripts/build_ios_xcframework.sh`, Abseil's CMake compile-feature probe (under `third_party/dawn/third_party/abseil-cpp/CMake/AbseilDll.cmake:753`) fails with `"compiler defaults to or is configured for C++ < 17. C++ >= 17 is required"`. Top-level project sets `CMAKE_CXX_STANDARD=20` so this is Abseil's probe not picking up the inherited standard from a parent scope.
- **Why this matters**: blocks the Phase 6.4 path of wiring Dawn into the iOS Pod chain. Phase 5 vendored_libraries deploy currently works because `build_ios_xcframework.sh` keeps `AETHER_ENABLE_DAWN=OFF`. Rolling that flag forward without fixing Abseil's probe regresses iOS deploy.
- **Status as of 2026-04-26 ~10:25**: `AETHER_ENABLE_DAWN=OFF` is the script's current setting (rolled back from ON to preserve Phase 5 path). Dawn iOS build itself works via `cmake --build aether_cpp/build-ios-{device,sim} --target webgpu_dawn` (libwebgpu_dawn_objects.a produced both arches, 2026-04-26 02:49).
- **Trigger to fix**: before Phase 6.4 wires Dawn into iOS Pod chain. Without this, 6.4 can't link against Dawn from the iOS app.
- **Plausible directions**:
  - Set `CMAKE_CXX_STANDARD` explicitly inside Abseil subdir scope before `add_subdirectory`
  - Set `set(CMAKE_CXX_COMPILE_FEATURES cxx_std_20)` per-target on the subdir
  - Patch `AbseilDll.cmake` to recognize C++20 implies C++17
  - Force probe ENV var (`set(ENV{CXX_STANDARD} 20)`) before `add_subdirectory`
- **Shape**: 1-2 hours of CMake debugging. Likely ends up as an `EXCLUDE_FROM_ALL` flag tweak or a 1-line scope hack.

---

## Phase 6 prerequisite — LOCKED, NOT DEFERRED

### Dawn iOS unblock + WGSL single-source shader pipeline
- **Status**: HARD PREREQUISITE. Phase 6 cannot start until this is resolved. Not a defer.
- **What**: Before Phase 6 real splat shader work begins, Dawn must build for iOS xcframework (Phase 4 D1 path, deferred under Phase 4 D2 macOS-first decision). That deferral has expired — Phase 6 splat shaders need a WGSL → Dawn → Metal/Vulkan/D3D path live so the same shader source runs on iOS, Android, HarmonyOS without per-platform forks.
- **Why it's not cosmetic**: Without Dawn iOS, real splat shaders fall back to per-platform MSL/GLSL/HLSL (Phase 4 architectural option A from D1's failure-mode table). **Per-platform shader is a violation of the user's stated cross-platform-algorithm principle (audit 2026-04-26), not a graceful degradation.** Shader code is algorithm; algorithm must be cross-platform per the architecture principle that drives this whole project. A per-platform shader split would mean the same splat-rasterizer math is hand-written 3-4 times across Swift/Kotlin/ArkUI codebases — exactly the technical debt this architecture refuses.
- **Triggers**:
  - **Phase 6 kickoff** (mandatory — Phase 6 cannot start until this is done)
  - Or: discovery that real splat math benefits >2× from Metal-3-specific features Dawn doesn't expose (would force re-evaluation, but the default answer is still "stay WGSL, accept feature lag" per Brush / gsplat-rs precedent — both vendor-able into aether_cpp later precisely because they're WGSL)
- **Method**: revisit Phase 4 D1 plan (CMake → `arm64-ios` + `arm64-iossimulator` xcframework build of Dawn). P3 prep done means more of aether_cpp builds clean for iOS now than 4 weeks ago, so the dependency graph is less hostile.
- **What's NOT acceptable as fallback**: per-platform shader (option A from Phase 4 D1). Per-platform shader is a violation, not a graceful degradation. If Dawn iOS unblock fails:
  - **Phase 6 ABORTS**
  - Does NOT fall back to per-platform MSL
  - Goes back to architecture review session before retry
- **Shape**: 1-2 days of Dawn iOS xcframework debugging. Could trigger BACKLOG cascade similar to P3.5 CocoaPods quirk — that's expected, Phase 6 has time budget for it.
- **Why this entry exists despite Phase 5 G having "deferred"**: Phase 5 G was the right LOCAL decision for Phase 5 (don't add Dawn complexity while porting Phase 4 to iOS). It is NOT the right decision for Phase 6+ (real shader code lands). Entry filed 2026-04-26 immediately after the Phase 5 user audit so the deferral can't quietly re-emerge in Phase 6 plan as an "easy A fallback".
- **Architectural note** (consequence of B): shader source location going forward is `aether_cpp/shaders/*.wgsl` — single-truth-point under aether_cpp, alongside the C++ algorithm source it complements. Future Phase 7+ Brush / gsplat-rs vendoring is zero-friction because both are WGSL natives.

**Phase 3 blocker resolved 2026-04-25** — all 3 previously-deferred bitrot files (`pipeline_coordinator.cpp`, `metal_gpu_device.mm`, `splat_render_engine.cpp`) re-enabled and compiling cleanly. See git log for the 5-commit Phase 3 prep cycle (chore trivials → refactor dynamic_cast → refactor try/catch → build re-enable → docs clear). The companion `PHASE3_BLOCKER.md` was deleted in this cycle since the work it tracked is complete.

---

## Phase 2 blocker workarounds (Flutter SDK local patches — restructured to repo)

### Status: Tier 1 done (debt restructured, not repaid)

**What**: Two patches against Flutter 3.41.7 work around macOS 14+ kernel-protected `com.apple.provenance` xattr breaking ad-hoc codesign of `Flutter.framework`. Detail in [`scripts/flutter_sdk_patches/README.md`](../../scripts/flutter_sdk_patches/README.md).

**Lifecycle position**:
- **Tier 1 (done)**: patches live in [`scripts/flutter_sdk_patches/*.patch`](../../scripts/flutter_sdk_patches/) + idempotent [`apply.sh`](../../scripts/flutter_sdk_patches/apply.sh) + Flutter version pin in [`CROSS_PLATFORM_STACK.md`](../../CROSS_PLATFORM_STACK.md). Reproducible across machines / CI / fresh checkouts.
- **Tier 3 (target)**: upstream Flutter merges a fix → delete the whole `scripts/flutter_sdk_patches/` directory.

**Why this is restructure, not repay**: patches still exist; they just moved from "only on Kaidong's Mac" to "in the repo". Solo dev's laptop dying no longer = lost project setup knowledge. But every brew upgrade or new Flutter version = re-validate cycle. Real repayment is upstream merge.

**Triggers to act**:
- **After any `brew upgrade flutter`**: run `bash scripts/flutter_sdk_patches/apply.sh`. If exits 1, patches need regenerating (see CROSS_PLATFORM_STACK.md upgrade ritual).
- **Before Phase 2.3 (real iPhone build)**: physical-device codesigning with a real Apple Developer cert may hit the same provenance issue. Currently patch only handles simulator. May need a separate patch.
- **When CI for Flutter is added (Phase 2+)**: first step in workflow must be `bash scripts/flutter_sdk_patches/apply.sh` (idempotent, exit 1 on failure).
- **When upstream merges fix** (track [flutter/flutter#185395](https://github.com/flutter/flutter/issues/185395) where we posted our reproduction + workaround comment, also see related [#181103](https://github.com/flutter/flutter/issues/181103) — both reference [`scripts/flutter_sdk_patches/upstream_comment_draft.md`](../../scripts/flutter_sdk_patches/upstream_comment_draft.md)): delete `scripts/flutter_sdk_patches/` entirely + drop the brew warning from CROSS_PLATFORM_STACK.md.

**Tier 3 signal channel**: ✅ established 2026-04-25. Commented on flutter/flutter#185395: https://github.com/flutter/flutter/issues/185395#issuecomment-4320752280. Argued the closure was iCloud-specific while the kernel-protected provenance still affects non-iCloud setups. If maintainers reopen / link a new issue / merge a fix, GitHub notifies Kyle-Wang0211 → we delete `scripts/flutter_sdk_patches/` and bump CROSS_PLATFORM_STACK.md.

---

## Phase 3.5 iOS Pod integration ✅ RESOLVED in Phase 5.0

### CocoaPods 1.16 vendored static xcframework: extraction script missing
- **Status**: ✅ RESOLVED 2026-04-25 in Phase 5.0 by switching from `s.vendored_frameworks = '../dist/aether3d_ffi.xcframework'` to per-arch `vendored_libraries` (D2 attack direction from Phase 4 productive-pause discussion). Implementation:
  - `scripts/build_ios_xcframework.sh` extended to extract per-arch `.a` from each xcframework slice into `dist/libs/{ios-arm64,ios-arm64-simulator}/`
  - `aether_cpp/aether3d_ffi.podspec` rewritten with `LIBRARY_SEARCH_PATHS[sdk=…]` + `OTHER_LDFLAGS[sdk=…] = -force_load <slice>/libaether3d_ffi.a` (per-sdk conditional, idiomatic CocoaPods pattern)
  - `pocketworld_flutter/ios/Podfile` re-enabled the previously-commented `pod 'aether3d_ffi', :path => '../../aether_cpp'`
  - Verified: `nm Runner.app/Runner.debug.dylib | grep _aether_version_string` returns `T _aether_version_string` (debug-build symbol lives in dylib not Runner — release build moves it back to Runner per Flutter AOT layout)
- **Plan doc**: `aether_cpp/PHASE5_PLAN.md` decision A
- **Surprise during execution** (not in plan): Plan's literal `s.vendored_libraries = 'dist/libs/**/libaether3d_ffi.a'` glob fails because both slices are non-fat arm64 (Apple Silicon sim dropped x86_64) — Xcode would auto-link both → "object file built for iOS Simulator, but linking for iOS" mismatch. Refined to `LIBRARY_SEARCH_PATHS[sdk=…] + -force_load` in podspec (still squarely D2, no D1 fallback). Also: `OTHER_LDFLAGS[sdk=…]` requires `$(inherited)` prefix or it strips CocoaPods's own `-ObjC` and Pod link flags.

---

## Phase 4 polish (deferred, non-blocking)

(From the Phase 4 code-review pass — issues #3 + #6–#10 of 10 total. Issues
#1, #2, #4, #5 were fixed inline as a separate chore commit.)

### #3 — `passRetained` contract assertion ✅ DONE Phase 5 polish (commit `a915f59b`)
- Resolved by adding always-on `CFGetRetainCount`-based watchdog inside `copyPixelBuffer()` on both iOS (`MetalRenderer.swift`) and macOS (`MainFlutterWindow.swift`) plugins. Samples once per second (every 60th call at 60fps) and logs `passRetained contract WARNING` if retain count exceeds threshold (5 — covers normal pipelining slack). Cost: < 0.01 ms / frame.
- The original "trigger = Flutter SDK bump" was changed to always-on after the user audit pointed out solo-dev SDK upgrades don't reliably remember dormant invariant checks. Always-on assertion shifts detection horizon from "user complaint after 30 min of use" to "log line within 1 second of leak".

### #6 — Dart-side retry mechanism on texture create failure ✅ DONE Phase 5 polish
- Resolved by wrapping `_HomeScreenState._requestTexture` with `_isRetrying` guard + ElevatedButton in the error path. Manual-only (no auto-retry — auto would mask GPU resource contention; explicit user click is the right product behavior for a dev surface). See `pocketworld_flutter/lib/main.dart`.

### #7 — RCA the 57.1 fps dip in DoD verification run
- **What**: During Phase 4.6 DoD verification, 27 of 28 one-second windows logged 60.0 fps; one mid-run window logged 57.1 fps. Cause unknown. Possibilities: macOS Spotlight indexing tick, scheduler interrupt, GC of an unrelated process, momentary thermal throttle.
- **Why it's not cosmetic**: Phase 5 splat rendering will run GPU at 5–10 ms/frame instead of <1 ms; an analogous interrupt under load could drop frames in a way the user sees. Identifying the cause now lets the fix (whatever it is) inform Phase 5 design.
- **Trigger to do**: before Phase 5 starts, or on first reported frame-stutter complaint.
- **Shape**: ~30 min — re-run with `os_signpost` or Instruments Time Profiler attached, identify the 57.1 fps frame, decode the cause from the trace.

### #8 — Rename `GradientTexture` → `SharedNativeTexture` ✅ DONE Phase 5 polish
- Resolved by `replace_all` rename across both `pocketworld_flutter/macos/Runner/MainFlutterWindow.swift` and `pocketworld_flutter/ios/Runner/AetherTexturePlugin.swift`. Channel method also renamed `createGradientTexture` → `createSharedNativeTexture` (Dart side updated to match). `kTriangleShaderSource` kept — content is still triangle in Phase 5; rename when content varies in Phase 6+.

### #9 — Parametrize 256×256 hardcoded size ✅ DONE Phase 5 polish
- Resolved by adding `parseTextureDimension(args["width"], default: 256)` helpers to both plugins, threaded into `SharedNativeTexture(device:, width:, height:)`. Dart still sends no size (256×256 default) — the path is now ready for Phase 6+ to pass `MediaQuery.of(context).devicePixelRatio`-aware values. Validation: positive ints, capped at 4096 (bigger than max MTLTexture for any iPhone shipped through 2026).

### #10 — Unit / integration tests
- **What**: Phase 4 verification was manual: build, run, eyeball screenshots, scrape stderr for fps. No automated regression catch.
- **Why it's not cosmetic**: any of the 4 fixes from the code-review chore could regress and only surface 3 weeks later when someone re-runs the manual ritual.
- **Trigger to do**: when Phase 4 surface stabilizes (post-Phase 5 integration when texture content flow is real).
- **Shape**: ~2 hours — Flutter widget test for the Texture mount path (mock plugin); Swift unit test for GradientTexture init throwing the right error per failure point; integration test that boots the app and asserts frame count > N over T seconds.

---

## Phase 5.2 iPhone real device deploy ✅ RESOLVED in Phase 5.2 (xcodebuild bypass)

### Three diagnoses, three reframings; here's what's actually true

- **Diagnosis 1 (WRONG)** — "macOS 26.1 + provenance xattr is a fundamental codesign block." Conclusion was that no command can strip `com.apple.provenance` and codesign refuses every file. Reframed when `xcodebuild` direct (without Flutter's wrapping) signed the same project successfully.
- **Diagnosis 2 (CLOSER)** — "The block is in Flutter's tool wrapper, not macOS's codesign." `xcodebuild -workspace ... -configuration Release -destination 'generic/platform=iOS' -allowProvisioningUpdates` signs successfully on the same machine; `flutter build ios` doesn't. Used this as the basis for `scripts/deploy_iphone.sh`. Reframed again 2026-04-26 01:00 when reproduced the failure with `xcodebuild` PLUS Flutter's `BUILD_DIR=<repo>/pocketworld_flutter/build/ios` flag.
- **Diagnosis 3 (CORRECT, 2026-04-26 01:10)** — The codesign block is **macOS file-provider system re-tagging files under `~/Documents/` with `com.apple.FinderInfo` + `com.apple.fileprovider.fpfs#P` continuously**. The `~/Documents/` tree is tracked by the file provider (because Apple thinks it's user-content); the file provider re-applies these xattrs within milliseconds even after `xattr -d` removes them. codesign rejects files with `FinderInfo`. `~/Library/Developer/Xcode/DerivedData/` is NOT file-provider-tracked, so codesign works there.
  - Repro: `xcodebuild -workspace ... -allowProvisioningUpdates BUILD_DIR=<documents-tree-path>` reproduces the failure exactly. Without the `BUILD_DIR=` override, builds go to DerivedData and codesign succeeds.
  - The `com.apple.provenance` xattr is a red herring — present in both working and failing paths, kernel-protected, but not what codesign rejects. The actual rejection is on `FinderInfo`.
  - The `xattr -c`/`xattr -d` strip ALL appear to "succeed" (exit 0) but the file provider re-tags within a few ms. **Race-windowing works: `find $APP -exec xattr -d com.apple.FinderInfo {} +; codesign ...` in a SINGLE shell invocation succeeds because codesign reads xattrs faster than the file provider can re-tag.** This is what `scripts/deploy_iphone.sh` now embeds.
- **Working deploy workflow (Phase 5.2 actual)**:
  ```bash
  # 1. Build via xcodebuild directly (NOT `flutter build ios`):
  cd pocketworld_flutter/ios
  xcodebuild -workspace Runner.xcworkspace -scheme Runner \
    -configuration Debug -destination 'generic/platform=iOS' \
    -allowProvisioningUpdates

  # 2. Re-sign embedded frameworks with the user's developer identity
  #    (xcodebuild's deep-sign signs with the team's Apple-Distribution
  #    cert which the device rejects with "identity no longer valid"):
  APP=~/Library/Developer/Xcode/DerivedData/Runner-*/Build/Products/Debug-iphoneos/Runner.app
  IDENTITY=$(security find-identity -v -p codesigning | grep "Apple Development" | head -1 | awk '{print $2}')
  for FW in $APP/Frameworks/*; do
      codesign --force --sign $IDENTITY --timestamp=none $FW
  done
  codesign --force --sign $IDENTITY \
    --entitlements ~/Library/Developer/Xcode/DerivedData/Runner-*/Build/Intermediates.noindex/Runner.build/Debug-iphoneos/Runner.build/Runner.app.xcent \
    --timestamp=none $APP

  # 3. Install + launch on connected iPhone via devicectl:
  xcrun devicectl device install app --device <iphone-udid> $APP
  xcrun devicectl device process launch --device <iphone-udid> com.kyle.PocketWorld
  ```
- **Why `flutter build` fails but `xcodebuild` succeeds**: still not fully diagnosed. The Flutter tool's xcconfig assembly likely passes a different signing identity context. The fact that this didn't reveal itself until step 3 (after Phase 5.0/5.1/5.4 all passed via simulator-only) is why the BACKLOG entry was wrong-rooted at first. Two-line Tier 1 fix candidate: invoke `xcodebuild` for device builds instead of `flutter build`, OR sniff the flutter tool's exact xcodebuild invocation diff.
- **Status as of 2026-04-26 00:15**: app installed + launched on Kyle's iPhone (UDID `00008120-00146C4A1AEBC01E`, iOS 26.3.1). Phase 5.2 ✅ DONE.
- **Trigger to deepen the fix**: when this becomes painful (frequent device deploys), file Tier 1 patch / wrapper script. Not urgent now — first-time setup is paid; subsequent deploys reuse the workflow.

---

## Phase 5 polish (deferred, non-blocking)

### Flutter 3.41.7 frontend_server `--output-dill` bug — literal-hash-dirname is cursed after `flutter clean`
- **What**: After `flutter clean` (or any state where `.dart_tool/flutter_build/<hash>/app.dill` is missing), `flutter build ios|macos` fails with `PathNotFoundException: Cannot open file, path = '…/app.dill'`. **Confirmed reproducible standalone** invoking `frontend_server_aot.dart.snapshot` directly with `--output-dill .dart_tool/flutter_build/<hash>/app.dill`.
- **Surprising specific finding (Phase 5.1)**: the failing path is the LITERAL hash directory name. Renaming the dir to `<hash>_alt` (or any other name) makes frontend_server's `--output-dill` succeed at the same depth, same parent, same xattrs (`com.apple.provenance` 11 on both), same perms (40755 on both), same owner. Some kernel-level state on macOS 26.1 is bound to that exact pathname. Symlink workaround: `ln -s <hash>_alt .dart_tool/flutter_build/<hash>` resolves writes via the symlink, frontend_server succeeds.
- **Why it's not cosmetic**: any `flutter clean` (a stock troubleshooting step) bricks every subsequent build forever. Fresh CI checkouts also hit this if `.dart_tool/` isn't seeded.
- **Workaround applied during Phase 5.1**: `mkdir -p .dart_tool/flutter_build/<hash>_alt && rm -rf .dart_tool/flutter_build/<hash> && ln -s <hash>_alt .dart_tool/flutter_build/<hash>`. Build then succeeds. Workaround is in `.dart_tool/` (gitignored) so doesn't pollute repo.
- **Why this is more than a frontend_server bug**: a frontend_server bug alone wouldn't be name-specific. The pattern (`com.apple.provenance` xattr blocking codesign on macOS 26 was the first instance, and now this) suggests macOS 26 is doing per-pathname tracking that surives `rm -rf`. The provenance xattr is identical between working and failing names — but maybe the kernel maintains a separate per-pathname blocklist that's NOT exposed via xattrs. Worth a focused investigation when bandwidth permits.
- **Trigger to do** (Tier 1 vs Tier 3):
  - **Tier 1** (next time the bug bites a teammate / new machine): wrap the `mkdir + symlink` workaround in `scripts/flutter_sdk_patches/apply.sh` so the existing patch infra picks it up. ~30 min.
  - **Tier 3** (root-cause fix): file an Apple Feedback Assistant ticket describing the per-pathname blocking + repro recipe. Long lead time. Document path forward in flutter#185395 thread.
- **Upstream**: not yet filed. Search needed: `flutter#PathNotFoundException output-dill 26.1` to dedupe.

---

## Phase 6.4f — Brush full pipeline → splat world-space + gesture-responsive  ✅ shipped 2026-05-02 (initial cut)

**Status**: shipped 2026-05-02. The new C ABI surface
(`aether_scene_renderer_load_ply` / `_load_spz`) is wired through to the
Brush kernels and produces real pixels from PLY/SPZ scenes via
`project_forward → project_visible → splat_render`. Offline smoke
(`tools/aether_dawn_scene_splat_smoke.mm`) renders a 1024-splat synthetic
sphere and verifies non-empty IOSurface output.

**Limitations of this initial cut** (tracked as Phase 6.4f.2 below):

- ~~No GPU depth sort. The 5 sort kernels (`sort_count → sort_reduce →
  sort_scan → sort_scan_add → sort_scatter`) and
  `map_gaussian_to_intersects` were not wired in this commit — splats
  render in atomic-write order from `project_forward`, producing correct
  silhouettes but minor transparency artifacts on heavy splat overlap.
  Add the 6-kernel sort+tile chain in 6.4f.2.~~ **Shipped in 6.4f.2.a
  (per-splat radix sort, see entry below).**
- ~~SH degree 0 only. Higher-order SH coeffs are parsed by the PLY loader
  but ignored at upload time. View-dependent shading is uniform.~~
  **Shipped in 6.4f.2.b/c (SH degrees 1, 2, 3 — see entry below).**
- No tile binning. The vert+frag `splat_render.wgsl` path overrenders
  vs. Brush's compute rasterizer but is 23× faster on mobile per the
  `splat_render.wgsl` docstring — accepted trade-off.

**What was kept verbatim from the original entry below for reference.**

---

- **What**: Replace the hardcoded screen-space `kBaselineSplats` in
  `aether_cpp/src/pocketworld/scene_iosurface_renderer.cpp` (the
  `make_baseline_uniforms` function and `kBaselineSplats` array; legacy
  `splat_iosurface_renderer.cpp` was retired in the Phase 6.4 cleanup)
  with a per-frame run of the full Brush pipeline:
    `project_forward → project_visible → sort_count/reduce/scan/scan_add/scatter
     → map_gaussian_to_intersects → splat_render`
  driven by world-space Gaussian primitives (means, log_scales, quats, opacities,
  SH coeffs) and the caller-supplied view+model matrices (already in the FFI).
- **Why it's not cosmetic**: 6.4c shipped the gesture FFI chain (Dart →
  MethodChannel → Swift → C ABI → GPU uniforms) end-to-end, verified by
  setMatrices NSLogs (`distance` mutated 5.0 → 0.50 → 9.26 in real time).
  But `splat_render.wgsl` reads `xy_x, xy_y` as PRE-projected screen
  coordinates, so the view matrix is uploaded but ignored — splats stay
  pinned at (128, 128) regardless of camera state. Phase 6.4b stage 2
  makes the **mesh** path gesture-responsive (PBR works fully through
  view+model); the **splat** path still pins the 4 hardcoded gray dots
  to the screen center while the mesh orbits around them. Visually wrong —
  splats should orbit with the mesh as if sharing one world. 6.4f fixes that.
- **Why it's deferred**: scope hygiene. 6.4b stage 2's SceneRenderer is
  a focused 2-pass mesh+splat-overlay design; bolting Brush full-pipeline
  into it would 60% the work + risk surface. 6.4f is a clean follow-up
  with its own SceneRenderer extension (per-frame compute pass chain
  before the render passes).
- **Why it's necessary anyway**: Phase 6.5 / 6.6 / 7 all require real
  `.ply` / `.spz` splat scenes loaded at runtime. Real splats are
  world-space primitives — there's no path forward without the full
  Brush pipeline. 6.4f is the moment that lands.
- **Trigger to do**: immediately after Phase 6.4b stage 2 lands AND
  before Phase 6.4d (WCG / DRS / 8K). Reason: 6.4d's DRS measures frame
  time and adapts resolution; the splat path needs to be the production
  pipeline (not 4 hardcoded dots) before DRS measurements are
  representative of real scenes.
- **Shape**: ~3-4h, single commit (or a 2-step split if compute pass
  scheduling has surprises). One new SceneRenderer method
  `set_splat_scene(ply_data)` that uploads world-space Gaussian
  primitives, then per-frame `render_full` runs the 8-9 kernel chain.
  Dart/Swift unchanged (decision pin 19: FFI ABI locked).
- **Decision pin reference**: ties into pin 1 (vertex+frag viewer
  rasterizer) and pin 2 (Brush 14 WGSL retained as algorithm base).
- **Upstream**: not applicable.

---

## Phase 6.4f.2 — depth sort + SH degree 1/2/3 polish  ✅ shipped 2026-05-02

**Status**: shipped 2026-05-02. The two correctness gaps from the 6.4f
initial cut (no depth sort, SH degree 0 only) are closed; the third
("no tile binning") is intentionally left as a perf trade-off.

**What shipped:**

- **6.4f.2.a — GPU depth sort.** New shader
  `shaders/wgsl/sort_prep_depth.wgsl` seeds 32-bit ascending-sort keys
  via `~bitcast<u32>(depths[i])` so the standard 5-kernel Brush radix
  sort (`sort_count → sort_reduce → sort_scan → sort_scan_add →
  sort_scatter`, 8 ping-pong passes for 4-bit-at-a-time / 32-bit
  keys) produces a back-to-front splat permutation. `splat_render.wgsl`
  gained a 3rd binding (`order: array<u32>`) and now reads
  `splats[order[ii]]` for hardware-blend-correct alpha compositing
  under the existing One/OneMinusSrcAlpha OVER blend mode.
  Per-splat sort (not per-tile) is the natural fit for our vert+frag
  instanced-quad rasterizer; production splat viewers (Spark.js,
  MetalSplatter, splaTV) all use this same approach. The Brush sort
  kernels are untouched and could be reused for tile binning later.
- **6.4f.2.b/c — SH degrees 1, 2, 3.** PLY loader (`include/aether/
  splat/ply_loader.h`) now auto-detects f_rest_* count → degree (9 →
  1, 24 → 2, 45 → 3) and stores raw coefficients in
  `PlyLoadResult.sh_rest` (PLY-native channel-major basis-major
  layout). Renderer
  (`src/pocketworld/scene_iosurface_renderer.cpp::build_splat_scene_from_gaussians`)
  repacks into Brush's basis-major-vec3 GPU layout matching
  `project_visible.wgsl`'s `read_coeffs` order. `RenderUniforms.
  camera_position` is now populated from inverse-view per-frame —
  required for view-dependent SH evaluation. SPZ retains DC-only
  (header-defined sh_degree is overridden to 0 because the SPZ
  decoder doesn't unpack higher-order coeffs yet — separate
  follow-up).

**New artefacts:**

- `shaders/wgsl/sort_prep_depth.wgsl` (1 new compute kernel)
- 6 new compute pipelines (sort_prep_depth + 5 brush radix kernels)
- 7 new GPU buffers per scene (keys×2, values×2, counts, reduced,
  num_keys + 8 small per-pass config buffers)
- ~20 new bind groups per scene (8 per-pass for sort_count + 8 for
  sort_scatter + 4 pass-invariant for prep/reduce/scan/scan_add)
- Total `libaether3d_ffi.a` size: 643MB → 676MB (+5%, mostly Brush
  WGSL-derived .o files from the additional baked sort_prep_depth)

**Validation:**

- `aether_dawn_scene_splat_smoke.mm` now has two modes:
  - `--mode=sort` (default): same 1024-Fibonacci-sphere fixture as the
    initial-cut smoke — 7997 opaque pixels (12.20%) PASS.
  - `--mode=sh1`: synthetic deg-1 SH ball with directional R/G/B
    coefficients tuned so viewdir.x → R, viewdir.y → G, viewdir.z →
    B. Camera looks at +z, expects B-dominant output. Verified
    `B=1874074 > R=901539 = G=901539` (R=G is correct: viewdir.x and
    .y average to 0 over the visible hemisphere, viewdir.z ≈ +1 →
    pure b1c1 contribution).
- Both smokes PASS, no Dawn validation errors.
- `cmake --build . --target aether3d_ffi` clean.
- `flutter analyze lib/aether_view/ lib/ui/community/` clean.
- `flutter build ios --debug --no-codesign` clean.

**What's deliberately deferred:**

- **Tile binning** (`map_gaussian_to_intersects` + per-tile rasterize
  loop) — same trade-off as the 6.4f initial cut. The vert+frag path
  is 23× faster on mobile per the splat_render.wgsl docstring;
  switching to brush's compute rasterizer would slow shipping. The
  shader and CPU dispatch infra for tile binning are vendored; flip
  to it when a real workload demonstrates the overdraw cost
  outweighs the speedup.
- **SPZ higher-order SH** — SPZ decoder skips f_rest_* streams. PLY
  is the dominant production format; SPZ extension is a separate
  follow-up.

---

## Phase 1 polish (deferred, non-blocking)

### device-lost callback on all 3 Dawn hello binaries
- **What**: Add `wgpu::DeviceDescriptor::SetDeviceLostCallback(...)` (or modern equivalent) to:
  - `aether_cpp/tools/aether_dawn_hello.cpp` (P1.4 adapter)
  - `aether_cpp/tools/aether_dawn_hello_compute.cpp` (P1.5 compute)
  - `aether_cpp/tools/aether_dawn_hello_triangle.cpp` (P1.7 triangle)
- **Why it's not cosmetic**: device-lost is GPU-disconnect / hot-unplug / driver-crash. Currently emits "Warning: No Dawn device lost callback was set" — Dawn says "this is probably not intended" because production code MUST handle it. Phase 1 hellos run for <1s in isolation so it's harmless **for these specific binaries**.
- **Trigger to do** (escalated 2026-04-25 from Phase 4+ to before-next-merge): the parallel Metal device-error handler in `pocketworld_flutter/macos/Runner/MainFlutterWindow.swift` (`cb.addCompletedHandler`) was added in the Phase 4 polish chore commit; the Dawn-side equivalent is now the lagging gap. Before any commit that adds a long-running Dawn compute path (Phase 5+), wire `SetDeviceLostCallback` on the surviving hellos so failures aren't silent.
- **Shape**: 1 chore commit. Parallel edit, ~20 min.

---

## How to add an item here

Each entry needs:
1. **What** — concrete, file-level pointer if applicable
2. **Why it's not cosmetic** — what real problem this prevents (or "is cosmetic" honestly)
3. **Trigger to do** — phase number / user-count threshold / runtime duration / platform expansion / etc. Specific, falsifiable.
4. **Shape** — rough commit/PR shape so future-you knows the cost

If you can't write a clear Trigger, the work isn't actually deferred — it's either dropped or it should be done now.
