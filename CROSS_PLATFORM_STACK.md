# Cross-platform stack — locked versions

Locked at Phase 1.4 milestone (`aether_dawn_hello` printed Apple M3 Pro / Metal). Bump these versions deliberately, not implicitly.

## Versions

| Component | Version | Pin location |
|---|---|---|
| **Flutter SDK** | `3.41.7` exact (channel stable, commit `cc0734ac716`, 2026-04-15) — **see "DO NOT brew upgrade flutter" warning below** | `flutter --version`; `git -C $(flutter --version --machine \| python3 -c "import sys,json; print(json.load(sys.stdin)['flutterRoot'])") rev-parse --short HEAD` |
| **Dart SDK** | `3.11.5` (bundled with Flutter, 2026-04-15) | `dart --version` |
| **Dawn (WebGPU)** | commit `12ee391c7411285895f4289a3d889a182c093014` (v20260423.175430-13) | `aether_cpp/third_party/dawn` submodule + `.gitmodules` |

## Toolchain (current Mac dev box)

| Component | Version |
|---|---|
| macOS | 26.1 (Build 25B78) |
| Xcode | 26.2 |
| AppleClang | 17.0.0.17000603 |
| CMake | 3.22+ (required by Dawn) |
| CocoaPods | 1.16.2 |

## How to verify

```bash
# Flutter / Dart
flutter --version
dart --version
flutter doctor   # iOS toolchain + CocoaPods must be ✓

# Dawn pin
git -C aether_cpp/third_party/dawn rev-parse HEAD
# expect: 12ee391c7411285895f4289a3d889a182c093014

# End-to-end: Dawn talks to Metal
cmake -S aether_cpp -B aether_cpp/build
cmake --build aether_cpp/build -j --target aether_dawn_hello
./aether_cpp/build/aether_dawn_hello
# expect: BackendType: Metal, Vendor: apple, Device: Apple M3 Pro (or your M-series)
```

## ⚠️ DO NOT `brew upgrade flutter` without re-validating

The Flutter SDK at `cc0734ac716` has **two local patches applied** to work around a macOS 14+ `com.apple.provenance` xattr / codesign incompatibility (see [`scripts/flutter_sdk_patches/`](scripts/flutter_sdk_patches/) and [`aether_cpp/PHASE_BACKLOG.md`](aether_cpp/PHASE_BACKLOG.md)).

If you `brew upgrade flutter` blindly:
1. Flutter source files move / change → patches stop applying cleanly.
2. `bash scripts/flutter_sdk_patches/apply.sh` exits 1 with a clear error.
3. Simulator builds fail again.

Correct upgrade ritual:
```bash
# 0. Check whether upstream Flutter has merged a com.apple.provenance fix.
#    If yes, the patches can be deleted (debt repaid). Track flutter/flutter#156098.
# 1. Bump intentionally; new commit hash goes into this file:
brew upgrade flutter
flutter --version --machine | python3 -c "import sys,json; print(json.load(sys.stdin)['flutterVersion'], json.load(sys.stdin)['frameworkRevisionShort'])"
# 2. Run apply.sh:
bash scripts/flutter_sdk_patches/apply.sh
# 3a. apply.sh succeeds → patches still apply. Update version + commit hash here, commit.
# 3b. apply.sh fails → either upstream fixed it (great, delete patches) or the patches need to be regenerated against the new Flutter:
#     - regenerate: `cd $FLUTTER_ROOT && git diff <file> > /path/to/000X-*.patch` for each
#     - update apply.sh's EXPECTED_FLUTTER_HEAD constant
#     - update this file's pin
```

## Bumping rules

- **Flutter / Dart**: bump together (Flutter ships its own Dart). Re-run `flutter doctor` after bump. Update this file's pinned versions atomically with the SDK switch. **AND** run the upgrade ritual above to re-validate patches.
- **Dawn**: `git -C aether_cpp/third_party/dawn fetch && git -C aether_cpp/third_party/dawn checkout <new-sha>` → commit the submodule pointer change → update this file.
- Never bump opaquely. Each bump = one commit that updates this file + one commit (or same) that updates the source-of-truth (`flutter` install / submodule pointer).

## Why these specific versions

- **Flutter 3.41.7** = latest stable as of P0.1 install (2026-04-25). Provides `dart:ffi` + `Texture` widget needed for Phase 3/4.
- **Dawn `12ee391c74`** = HEAD of `google/dawn` `main` at P1.2 add (2026-04-25). New enough to have the modern callback API (StringView + lambda capture, no `void* userdata`).
- **CMake 3.22+** = Dawn's minimum. We bumped `aether_cpp/CMakeLists.txt` from 3.16 → 3.22 in P1.3.

---

## Lessons learned (Phase 0 → Phase 3)

Things future-Kaidong / future-collaborators should know that aren't obvious from reading the code.

### Dart FFI validation pattern: macOS Dart CLI before iOS

**Problem**: iOS toolchain failures during FFI bring-up are hard to debug because the failure mode is "red Flutter screen with `dlsym ... symbol not found`" — could be ABI mistake, dart:ffi mistake, codesign issue, Pod integration issue, or library packaging issue all causing the same symptom.

**Pattern (proven in P3.4)**: build a tiny shared library on macOS (`libaether3d_ffi.dylib`), write a pure-Dart CLI script using `dart:ffi` + `package:ffi` that opens it and calls one function, run via `dart run tool/aether_ffi_smoke.dart`. **All FFI binding mechanics are bit-for-bit identical to iOS** — only the library-loading mechanism differs (`DynamicLibrary.open(<path>)` for macOS dev vs `DynamicLibrary.process()` for iOS app where the static lib is linked in).

If this passes on macOS but fails on iOS, the bug is **necessarily** in iOS-specific tooling (Pod / xcframework / codesign / etc.), not the design. Hugely narrows the bisect.

### iOS xcframework slice naming

`xcodebuild -create-xcframework` outputs use these directory names:
- `ios-arm64/` — iOS device (iPhoneOS SDK)
- `ios-arm64-simulator/` — iOS Simulator on Apple Silicon (iPhoneSimulator SDK)
- (historical) `ios-x86_64-simulator/` — Intel Mac Simulator, no longer relevant on M-series

The platform marker in each slice's library can be verified with `otool -l <lib> | grep platform` — `platform 7` = iPhoneSimulator, `platform 2` = iPhoneOS.

### CMake quirks for iOS builds

1. **`target_compile_features(<t> PRIVATE cxx_std_20)` breaks under `iphonesimulator` sysroot** — CMake's compiler-feature probe returns empty there. Workaround: use the top-level `set(CMAKE_CXX_STANDARD 20)` exclusively, don't add per-target feature requirements.
2. **`add_library(<t> SHARED ...)` on iOS requires a development team** — Xcode wants to codesign every dylib. For library targets that should ship as static, gate behind a build option (e.g., `AETHER_FFI_BUILD_STATIC=ON`) and switch between `STATIC` / `SHARED` accordingly. Default to `SHARED` for macOS dev (so `dart:ffi DynamicLibrary.open` works), `STATIC` for iOS xcframework (so codesign isn't required).
3. **iOS configure invocation**:
   ```bash
   cmake -S aether_cpp -B aether_cpp/build-ios-device \
     -G Xcode \
     -DCMAKE_SYSTEM_NAME=iOS \
     -DCMAKE_OSX_ARCHITECTURES=arm64 \
     -DCMAKE_OSX_DEPLOYMENT_TARGET=14.0 \
     -DAETHER_ENABLE_DAWN=OFF \
     -DAETHER_FFI_BUILD_STATIC=ON
   ```
   For simulator, add `-DCMAKE_OSX_SYSROOT=iphonesimulator`.
4. **`if(APPLE)` is true on both macOS and iOS**. Don't assume it means macOS.

### CocoaPods 1.16 + vendored static .xcframework + Flutter (UNRESOLVED, see PHASE_BACKLOG.md)

The standard CocoaPods integration path for vendored static xcframeworks fails to generate the xcframework slice-extraction `script_phase`. Build fails with `Build input file cannot be found: .../XCFrameworkIntermediates/<pod>/lib<pod>.a`. Tried 3 angles (`s.static_framework = true`, removing `use_frameworks!`, `post_install` force_load) — none worked. Deferred per Phase 3.5 abort. See `aether_cpp/PHASE_BACKLOG.md` "Phase 3.5 iOS Pod integration" for full diagnosis + 4 plausible directions to try next.

### Dawn-on-iOS — also unresolved

Dawn's CMake doesn't have an iOS code path tested. Phase 3.1 deliberately disabled Dawn (`AETHER_ENABLE_DAWN=OFF`) for iOS xcframework. Re-enabling Dawn for iOS is its own substantial task (likely Phase 4+). For Phase 3 scope (Dart calls C++ on iOS), Dawn isn't needed.

### `aether3d_core` — also currently iOS-disabled

`metal_gpu_device.mm` + `depth_inference_coreml.mm` use Metal/CoreML APIs that have iOS-vs-macOS differences. Phase 3.1 ships `aether3d_ffi` (just version.cpp) for iOS, NOT the full `aether3d_core`. Re-enabling these for iOS is a Phase 4 task.

### CocoaPods locale gotcha

CocoaPods 1.16 on macOS requires UTF-8 locale or fails with `Encoding::CompatibilityError` deep in unicode normalization, masquerading as a Ruby/Podfile issue. Workaround: always invoke as `LANG=en_US.UTF-8 LC_ALL=en_US.UTF-8 pod install`. (Or set in shell profile, but explicit per-invocation is more reproducible.)

### macOS provenance xattr (already documented above)

The Flutter SDK patches at `scripts/flutter_sdk_patches/` work around macOS 14+'s kernel-protected `com.apple.provenance` xattr breaking ad-hoc codesign of `Flutter.framework`. See PHASE_BACKLOG.md for the full Tier 1 lifecycle.
