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
