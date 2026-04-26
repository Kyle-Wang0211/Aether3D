# aether_cpp Phase backlog

Deferred non-blocking work, organized by **trigger condition** (not by priority or date).
Items here are NOT lost — they're parked until their trigger fires. If no trigger,
the item shouldn't be here.

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

## Phase 3.5 iOS Pod integration (deferred, non-blocking)

### CocoaPods 1.16 vendored static xcframework: extraction script missing
- **What**: `pod 'aether3d_ffi', :path => '../../aether_cpp'` integrates the podspec successfully (`pod install` passes), and the xcframework path is wired into Pods-Runner.debug.xcconfig at `$(PODS_XCFRAMEWORKS_BUILD_DIR)/aether3d_ffi/libaether3d_ffi.a`. But CocoaPods does **not** generate a script_phase to actually extract the slice from `dist/aether3d_ffi.xcframework`. Build fails: "Build input file cannot be found: .../XCFrameworkIntermediates/aether3d_ffi/libaether3d_ffi.a".
- **Why it's not cosmetic**: This is the last mile of Phase 3.5 — without it, Dart `DynamicLibrary.process().lookupFunction('aether_version_string')` fails at runtime with `dlsym(RTLD_DEFAULT, ...): symbol not found`, and the UI shows a red Flutter error screen instead of the version string.
- **Why it's safe to defer**: Phase 3's architectural goal — "Dart can call C++ on iOS via FFI" — is **proven feasible** by P3.4 (macOS Dart CLI runs the FFI binding cleanly against `libaether3d_ffi.dylib`). The iOS-specific tooling friction doesn't invalidate the design. P2.4's placeholder `'v0.1.0-phase2'` continues to render correctly.
- **Things tried (none worked)**:
  - `s.static_framework = true` in podspec → adds `-ObjC` to OTHER_LDFLAGS, no extraction script
  - `use_frameworks!` removed from Podfile → same missing-extraction-script error
  - Force-load via post_install hook → `-force_load` references the same nonexistent path
- **Trigger to revisit**:
  - When ready to wire iOS device FFI (likely paired with Phase 2.3 real-iPhone deploy)
  - When upstream CocoaPods publishes a fix for vendored static xcframework + Flutter integration
  - If a Flutter-iOS-FFI tutorial / community pattern is published showing the canonical path
- **Plausible directions to investigate then**:
  - Manually add the .a to Runner.xcodeproj's "Link Binary With Libraries" build phase, bypassing CocoaPods entirely
  - Switch from `s.vendored_frameworks` to `s.vendored_libraries` (per-arch .a files) — older but simpler mechanism
  - Custom `script_phase` in podspec that extracts the xcframework slice manually
  - Distribute as a pre-built `.framework` (dynamic) instead of static `.xcframework`, accepting the codesign + dev-team requirement
- **What's already in place** (don't redo): `dist/aether3d_ffi.xcframework` builds cleanly via `scripts/build_ios_xcframework.sh`; podspec at `aether_cpp/aether3d_ffi.podspec`; pre-positioned UI hook in `pocketworld_flutter/lib/main.dart` (still showing placeholder); `pocketworld_flutter/tool/aether_ffi_smoke.dart` proves the binding side works on macOS.

---

## Phase 4 polish (deferred, non-blocking)

(From the Phase 4 code-review pass — issues #3 + #6–#10 of 10 total. Issues
#1, #2, #4, #5 were fixed inline as a separate chore commit.)

### #3 — `passRetained` contract assertion
- **What**: `GradientTexture.copyPixelBuffer()` in `pocketworld_flutter/macos/Runner/MainFlutterWindow.swift` returns `Unmanaged.passRetained(pixelBuffer)` assuming Flutter's texture compositor releases it. Currently a code comment documents the contract. Add a runtime assertion (e.g. weak ref tracking) or unit test that catches a Flutter SDK regression that silently changes the contract.
- **Why it's not cosmetic**: silent CVPixelBuffer leak on Flutter SDK upgrade. Activity Monitor would eventually show climbing memory but no crash, no error — invisible regression.
- **Trigger to do**: any Flutter SDK bump (currently pinned to 3.41.7 in CROSS_PLATFORM_STACK.md).
- **Shape**: ~30 min — add weak-ref tracking around CVPixelBuffer + assertion that count drops over time, OR a unit test that mocks the Flutter compositor.

### #6 — Dart-side retry mechanism on texture create failure
- **What**: `_HomeScreenState._textureError` in `pocketworld_flutter/lib/main.dart` is set on failure and never retried. UI shows the error string until app relaunch. Add a retry button or auto-retry with backoff.
- **Why it's not cosmetic**: any transient failure (GPU temporarily busy, OS resource pressure during create) bricks the widget for the session. Production needs a recovery path.
- **Trigger to do**: before this surface is exposed to non-developer users.
- **Shape**: ~15 min Dart change — wrap `_textureError` reset + invokeMethod retry in a button; or `Timer(Duration(seconds: 2), _requestTexture)` for auto.

### #7 — RCA the 57.1 fps dip in DoD verification run
- **What**: During Phase 4.6 DoD verification, 27 of 28 one-second windows logged 60.0 fps; one mid-run window logged 57.1 fps. Cause unknown. Possibilities: macOS Spotlight indexing tick, scheduler interrupt, GC of an unrelated process, momentary thermal throttle.
- **Why it's not cosmetic**: Phase 5 splat rendering will run GPU at 5–10 ms/frame instead of <1 ms; an analogous interrupt under load could drop frames in a way the user sees. Identifying the cause now lets the fix (whatever it is) inform Phase 5 design.
- **Trigger to do**: before Phase 5 starts, or on first reported frame-stutter complaint.
- **Shape**: ~30 min — re-run with `os_signpost` or Instruments Time Profiler attached, identify the 57.1 fps frame, decode the cause from the trace.

### #8 — Rename `GradientTexture` → `SharedNativeTexture`
- **What**: The class still named `GradientTexture` from the Step 1 CPU-gradient era; it now renders a triangle, not a gradient.
- **Why it's not cosmetic**: code-search misleading. Anyone grepping for "where does the triangle live" hits no result; anyone reading `GradientTexture` thinks it produces a gradient.
- **Trigger to do**: any time `pocketworld_flutter/macos/Runner/` gets touched again.
- **Shape**: 1-line rename + class signature update + plugin reference. ~5 min. Also rename `kTriangleShaderSource` to drop the `Triangle` prefix when content varies (Phase 5+).

### #9 — Parametrize 256×256 hardcoded size
- **What**: `GradientTexture.init(device:width:height:)` defaults are `256, 256` and the Dart side never passes anything. For Phase 5 splat-render the size will need to be window/device-pixel-ratio responsive.
- **Why it's not cosmetic**: Phase 5 onwards needs the texture to match the rendering region (typically full window, retina-aware).
- **Trigger to do**: Phase 5 first sub-step (when splat actually renders).
- **Shape**: ~15 min — pass `{width, height}` via `createGradientTexture` method args; Dart sends device-pixel-ratio-aware size on widget build.

### #10 — Unit / integration tests
- **What**: Phase 4 verification was manual: build, run, eyeball screenshots, scrape stderr for fps. No automated regression catch.
- **Why it's not cosmetic**: any of the 4 fixes from the code-review chore could regress and only surface 3 weeks later when someone re-runs the manual ritual.
- **Trigger to do**: when Phase 4 surface stabilizes (post-Phase 5 integration when texture content flow is real).
- **Shape**: ~2 hours — Flutter widget test for the Texture mount path (mock plugin); Swift unit test for GradientTexture init throwing the right error per failure point; integration test that boots the app and asserts frame count > N over T seconds.

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
