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

## Phase 5.2 iPhone 17 Pro real device deploy (DEFERRED — codesign blocker)

### macOS 26.1 + Xcode 26.2 + `com.apple.provenance` xattr blocks every codesign path
- **What**: `flutter build ios` (release, not simulator) fails at Xcode's `CodeSign /path/Runner.app` step with `resource fork, Finder information, or similar detritus not allowed`. Same root cause as the Phase 2 macOS-desktop codesign issue: `com.apple.provenance` xattr is **kernel-generated on every file write** on macOS 26 and **kernel-protected** (cannot be removed). codesign refuses to sign files carrying it.
- **Status as of 2026-04-25 23:58**: Phase 5.0/5.1/5.4 verified on iPhone 17 Pro Simulator (which doesn't enforce codesign — Patch 0002 skips it there). Real device deploy blocked. Kyle's iPhone IS connected and visible in `flutter devices`; the block is purely host-side codesign, not device-side.
- **Things tried (none worked)**:
  - `xattr -c` (Patch 0001 in scripts/flutter_sdk_patches/): exits 0 but xattr remains
  - `xattr -d com.apple.provenance`: same — kernel rejects silently
  - `ditto --noextattr` to a fresh path: target file STILL gets xattr (kernel applies on write)
  - `cp -X` to a fresh path: same as ditto
  - `cat src > dst`: even shell redirection produces a file with the xattr
  - Even `/tmp` and `/private/var/tmp` get the xattr — system-wide
  - Skipping Flutter tool's `_signFramework` pre-codesign (extended Patch 0002 live, then reverted): only delays the failure; Xcode's downstream codesign during Embed Frameworks hits the same xattr error on `Runner.app/Runner` (the Swift-compiled main binary)
  - `codesign --remove-signature` then `--force --deep --options=runtime` with full entitlements: same "detritus not allowed"
- **Why this is a hard block, not a Flutter issue**: the same codesign command would fail on a non-Flutter Swift project under macOS 26.1. The xattr is on every file, and codesign predates this xattr's existence so its sanity check rejects unknown xattrs. Apple presumably has internal infrastructure that strips xattrs before codesign, but it's not exposed to user-side codesign.
- **What unblocks this**:
  - Apple Xcode/codesign update that recognizes `com.apple.provenance` as known-safe (most likely path; track via macOS 26.x point releases)
  - Boot from a different macOS install (older 14.x or 15.x) that doesn't generate this xattr — invasive, last resort
  - Run iOS build inside a VM with macOS 14.x — extra infra, may be feasible via tart / orbstack
  - Submit Apple Feedback Assistant ticket arguing for a `codesign --allow-provenance-xattr` flag — long lead time
- **Trigger to retry**: any of:
  - macOS 26.x point release where `xattr -d com.apple.provenance` actually works
  - Discovery of an undocumented codesign flag (rg through Xcode binaries / man pages periodically)
  - User decision to build on a different machine
- **Why deferring is acceptable for Phase 5**: Phase 5 mission was "iOS port of Phase 4 bridge". Phase 5.0/5.1/5.4 prove the iOS port architecturally — IOSurface bridge, Metal pipeline, FFI all run on iPhone 17 Pro Simulator (which is real iOS code on real iOS Metal stack, just running on host CPU). Real device deploy is a build-environment problem, not an architectural one. The Phase 5 architectural goal is met; the deploy step waits.
- **Shape**: when codesign is fixed, the deploy step is `flutter run -d <iphone-udid> --release`. ~5 min. The build settings are already correct (DEVELOPMENT_TEAM = 26AH7V448L, PRODUCT_BUNDLE_IDENTIFIER = com.kyle.PocketWorld, automatic signing).

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
