# Cross-platform stack — locked versions

Locked at Phase 1.4 milestone (`aether_dawn_hello` printed Apple M3 Pro / Metal). Bump these versions deliberately, not implicitly.

## Versions

| Component | Version | Pin location |
|---|---|---|
| **Flutter SDK** | `3.41.7` (channel stable, revision `cc0734ac71`, 2026-04-15) | `flutter --version` |
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

## Bumping rules

- **Flutter / Dart**: bump together (Flutter ships its own Dart). Re-run `flutter doctor` after bump. Update this file's pinned versions atomically with the SDK switch.
- **Dawn**: `git -C aether_cpp/third_party/dawn fetch && git -C aether_cpp/third_party/dawn checkout <new-sha>` → commit the submodule pointer change → update this file.
- Never bump opaquely. Each bump = one commit that updates this file + one commit (or same) that updates the source-of-truth (`flutter` install / submodule pointer).

## Why these specific versions

- **Flutter 3.41.7** = latest stable as of P0.1 install (2026-04-25). Provides `dart:ffi` + `Texture` widget needed for Phase 3/4.
- **Dawn `12ee391c74`** = HEAD of `google/dawn` `main` at P1.2 add (2026-04-25). New enough to have the modern callback API (StringView + lambda capture, no `void* userdata`).
- **CMake 3.22+** = Dawn's minimum. We bumped `aether_cpp/CMakeLists.txt` from 3.16 → 3.22 in P1.3.
