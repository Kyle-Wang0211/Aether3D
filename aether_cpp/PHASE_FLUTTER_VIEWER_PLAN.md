# Phase Flutter Viewer Integration plan — replace thermion with aether_cpp

**Status**: SKELETON 2026-05-01. G1 design doc + G2 skeleton landed; G3–G9
implementation deferred to follow-up sessions per the staged plan below.

**Mission**: Replace thermion in `pocketworld_flutter`'s community-feed
viewer (`lib/ui/community/live_model_view.dart` + `_LiveInstanceRegistry`)
with a Dart-FFI binding layer over the already-shipped `aether_cpp` scene
renderer (`aether_scene_renderer_*` C API from Phase 6.4b stage 2) and
splat engine (`aether_splat_*` C API + Phase 6.3a `splat_render.wgsl`).

**This plan is the Flutter-side integration track**. The C++ side is
already done — Phase 6.4b stage 2 milestone (2026-04-26) ships the mesh
PBR + splat overlay 2-pass IOSurface renderer; Phase 6.4e milestone
(2026-04-27) wires the iOS Runner home screen to it via Swift C-ABI
direct-call. We are NOT touching that work; we are adding the missing
**Dart FFI bindings + ViewerImpl abstraction** so the community feed
(currently still on thermion) can sit on the same renderer.

## Why now (decision rationale)

- `thermion_dart 0.3.4` ships a `Engine_destroySwapChain` double-free
  RenderThread panic (`Object <no-rtti> at ... doesn't exist
  (double free?)`) that corrupts subsequent renders. Workaround in
  `pocketworld_flutter/lib/ui/community/post_card.dart` keeps unmount
  delay at 5 minutes to dodge the trigger, but this is mitigation,
  not fix. Long-term we own the stack.
- `aether_cpp` is the locked long-term renderer per the architecture
  decision in MEMORY.md → Aether3D 跨平台架构决策 (Flutter UI +
  Dawn/WebGPU + aether_cpp). Phase 6 has been executing on this for
  weeks; the scene renderer + GPU device + WGSL kernels are the
  core deliverable.
- Format coverage: thermion only does glTF/GLB. aether_cpp already
  supports GLB **and** PLY (3DGS Gaussian-Splat PLY, the gsplat
  standard format) **and** SPZ (compressed splat). Replacing thermion
  with aether_cpp directly unlocks the PLY/SPZ formats this app's
  schema (`works.format`) has had reserved since the Supabase
  migration on 2026-04-29.

## Scope (what's IN, what's OUT)

### IN (this plan owns)

- New Dart FFI bindings package (`pocketworld_flutter/lib/aether_view/`):
  - `scene_renderer_bindings.dart` — `aether_scene_renderer_*`
  - `splat_engine_bindings.dart` — `aether_splat_*`
  - `format_detect.dart` — `.glb` vs `.ply` (mesh vs 3DGS) vs
    `.spz` / `.splat` vs unknown, by extension + magic-byte sniff
- `ViewerImpl` interface (`lib/ui/community/viewer_impl.dart`) +
  two concrete impls:
  - `ThermionViewerImpl` — current behaviour, kept during transition
  - `AetherCppViewerImpl` — FFI-backed, replaces thermion incrementally
- Refactor `LiveModelView` to talk to a `ViewerImpl`, not directly to
  `ViewerWidget`. Both impls render into the same Flutter `Texture`
  the parent already wires through `ScanRecordCell`.
- Flutter `Texture` ↔ aether_cpp scene renderer wiring per platform:
  - iOS: re-use the `AetherTexturePlugin.swift` IOSurface bridge that
    already feeds the home-screen scene renderer (Phase 6.4e wired
    `loadGlb` + `setMatrices` MethodChannel handlers there).
  - Android: TODO in G6 — use `SurfaceTexture` ↔ Vulkan via Dawn.
  - Web: TODO in G8 — `<canvas>` + WebGPU via Dawn's emscripten path.
  - HarmonyOS: best-effort, follow whichever of Android / Web wins.

### OUT (Phase 6 owns, do NOT touch)

- `aether_cpp/src/render/dawn_gpu_device.{h,cpp,_internal.h}` — the
  Dawn GPU device class is locked by Phase 6.2.
- `aether_cpp/src/pocketworld/scene_iosurface_renderer.{h,cpp}` — the
  shipped 2-pass IOSurface renderer, locked by Phase 6.4b stage 2.
- `aether_cpp/shaders/wgsl/{mesh_render,splat_render}.wgsl` + the 14
  Brush kernels — locked by Phase 6.3a.
- Anything in `aether_cpp/include/aether/splat/` or
  `aether_cpp/include/aether/pocketworld/` headers: locked C-API
  surface; we consume it as-is.
- iOS Runner native side (`pocketworld_flutter/ios/Runner/*.swift`) is
  already calling these C APIs directly for the home screen — we do
  not change that pattern; we **mirror** it from Dart for the feed.

### NOT YET (later phases of this plan, separate sessions)

- Glass-plate compositor shader. Detail page's `_GlassInfoPlate` uses
  `liquid_glass_renderer` to refract underlying pixels; aether_cpp
  needs a parallel shader that samples Flutter's compositor color
  attachment. Tracked as G7. Strictly later than full feed migration.
- Gaussian Splat training inside this app (Phase 7 freemium local
  tier). Phase 6.3b ships training kernels; this plan only consumes
  pre-trained PLYs/SPZs at view time.

## Architecture

### Layer diagram

```
┌──────────────────────────────────────────────────────────────┐
│ Flutter UI                                                   │
│  PostCard                                                    │
│   └─ LiveModelView ── uses ──▶ ViewerImpl (interface)        │
│                                  ▲       ▲                   │
│                       impl by ──┘       └── impl by          │
│                  ThermionViewerImpl   AetherCppViewerImpl    │
│                  (transition only)    (target)               │
│                                          │                   │
│                                          ▼                   │
│                            lib/aether_view/ FFI bindings     │
│                              scene_renderer_bindings.dart    │
│                              splat_engine_bindings.dart      │
│                              format_detect.dart              │
│                                          │                   │
│                                          ▼  dart:ffi         │
└──────────────────────────────────────────┼───────────────────┘
                                           │ extern "C"
                                           ▼
┌──────────────────────────────────────────────────────────────┐
│ aether_cpp (shipped, do not modify)                          │
│  aether_scene_renderer_*    ◀── GLB path                     │
│   └─ scene_iosurface_renderer.cpp                            │
│       ├─ mesh_render.wgsl  (Filament BRDF)                   │
│       └─ splat_render.wgsl (Phase 6.3a vertex+fragment)      │
│  aether_splat_*             ◀── PLY / SPZ path               │
│   └─ splat_render_engine.cpp                                 │
│       └─ Brush 14 WGSL + sort + project kernels              │
│  DawnGPUDevice              ◀── shared GPU abstraction       │
└──────────────────────────────────────────────────────────────┘
```

### Format dispatch

`AetherCppViewerImpl.load(url)` does:

1. download bytes via existing `GlbCache.fetch(url)` (no change)
2. `format_detect.detect(bytes)` returns one of:
   - `Format.glb` — magic `glTF` (0x46546C67) at byte 0
   - `Format.plyMesh` — `ply\n` header AND no `f_dc_*` properties
   - `Format.plyGsplat` — `ply\n` header AND `f_dc_0` / `f_dc_1` /
     `f_dc_2` / `scale_*` / `rot_*` / `opacity` properties present
     (the 3DGS/gsplat convention)
   - `Format.spz` — magic `SPZ\0` at byte 0
   - `Format.splat` — Niantic compressed; same C API as SPZ
3. dispatch:
   - `glb` → `aether_scene_renderer_load_glb(handle, path)`
   - `plyGsplat` / `spz` / `splat` → `aether_splat_load_ply(engine, path)`
     (or `aether_splat_load_spz` once we expose that binding)
   - `plyMesh` → not supported v1; fall back to error UI

### Per-card lifecycle

`AetherCppViewerImpl` owns one `aether_scene_renderer_t*` (mesh+splat
2-pass) per `LiveModelView` instance. Mounted/unmounted from
`initState`/`dispose`:

- `initState` → `aether_scene_renderer_create(width, height)` →
  Texture id from native side → return to Flutter.
- `dispose` → `aether_scene_renderer_destroy(handle)` → free.
- Per-frame (driven by Flutter's vsync via `Ticker`): camera matrices
  computed in Dart, passed via `aether_scene_renderer_render_full(
  handle, viewMat, projMat)`. Same Ticker pattern that the existing
  thermion path uses; nothing new there.

The thermion swap-chain double-free issue does NOT recur here — that
bug is in `Engine_destroySwapChain` of Filament, which we don't link
in once thermion is removed. aether_cpp's Dawn device is its own
lifecycle.

### `ViewerImpl` interface (Dart)

```dart
abstract class ViewerImpl {
  /// Allocate a renderer instance sized to the card.
  Future<int /*textureId*/> create({
    required double width,
    required double height,
    required Color background,
  });

  /// Load the model. Returns the actual half-extents + center so the
  /// caller can drive its own camera fit (the existing model-viewer
  /// formula in live_model_view.dart already does this; that math
  /// stays in Dart).
  Future<ModelBounds> load(String url);

  /// Push view + projection matrices for this frame. Called from the
  /// auto-rotate Ticker / orbit gesture handler.
  Future<void> render({
    required Matrix4 viewMatrix,
    required Matrix4 projMatrix,
  });

  Future<void> dispose();
}
```

`ThermionViewerImpl` keeps the current code path, gated behind
`useAetherCpp = false`. `AetherCppViewerImpl` is the FFI route; G3+
flips the gate.

## Sequencing (G2 → G9)

**G2 (this commit)**: skeleton only — interface + FFI binding stubs +
plan doc. No call sites change; thermion still drives every render.
Goal: a clean handoff point so subsequent sessions know exactly which
files to fill in.

| Step | Description | Lines | Risk | Validation |
|---|---|---|---|---|
| **G2** | This skeleton: design doc + Dart FFI stubs + ViewerImpl interface + 2 empty concrete classes | ~400 | 🟢 trivial | `flutter analyze` clean |
| **G3** | Fill Dart FFI bindings — load `libaether3d_ffi` → bind `aether_scene_renderer_*` (4 functions) + `aether_splat_*` (5 functions). Macos `dart run` smoke (no Flutter) calls `create + destroy`. | ~250 | 🟡 medium (FFI ABI) | macOS Dart CLI smoke per CROSS_PLATFORM_STACK.md "Dart FFI validation pattern" |
| **G4** | `AetherCppViewerImpl` MVP — `create + load(GLB only) + render + dispose`. Behind `kAetherCppViewerEnabled` const, default false. Wire `LiveModelView` to choose. | ~300 | 🟡 medium (texture-id plumbing per platform) | flip gate locally, run on iPhone, GLB visible |
| **G5** | Format detect + PLY (3DGS) path via `aether_splat_*` | ~200 | 🟡 medium (PLY parser memory) | seed a PLY, verify renders |
| **G6** | SPZ + SPLAT path. Android wiring via `SurfaceTexture` | ~250 | 🔴 high (Android Dawn) | Android emulator GLB renders |
| **G7** | Glass-plate compositor parity for detail page | ~400 | 🔴 high (sampling Flutter compositor) | detail page visual parity |
| **G8** | Web wiring via Dawn emscripten | ~500 | 🔴 high (different texture mechanism) | `flutter run -d chrome` |
| **G9** | Remove thermion dependency from `pubspec.yaml`. `ThermionViewerImpl` deleted. | ~200 | 🟢 low | full smoke on each platform |

Estimated total: 3–5 months of focused work, multi-session, per the
plan's sequencing principle.

## Risks + mitigations

- **Per-card `aether_scene_renderer_t*` not multi-instance ready** —
  Phase 6.4e's Swift wiring uses one renderer for the home screen.
  Multi-instance (one per PostCard) is untested. Mitigation: G4
  validates 1 instance first; G6 stress-tests 5 (matches L3 cap).
  If multi-instance is broken, fall back to a singleton + swap-glb on
  card focus change (acceptable — only the focused card autorotates,
  per VaultPage's existing focus logic).
- **FFI threading** — `aether_scene_renderer_render_full` runs on
  Dawn's render thread. Calling from Dart's main isolate is fine
  (FFI is thread-safe; Dawn handles dispatch internally). No need
  for `Isolate` workers v1.
- **Flutter `Texture` widget across platforms** — iOS uses
  `FlutterTexture` (already wired), Android uses `SurfaceTexture`,
  Web uses `<canvas>`. Each needs a small platform shim. That's
  why G6/G7/G8 are estimated heavier.

## Cross-references

- `aether_cpp/PHASE6_PLAN.md` — splat viewer + training (parallel
  track, do not touch)
- `aether_cpp/include/aether/pocketworld/scene_iosurface_renderer.h` —
  the C API this plan binds to
- `aether_cpp/include/aether/splat/aether_splat_c.h` — the splat C API
- `aether_cpp/include/aether/pocketworld/glb_loader.h` — GLB loader
  internals (read-only reference)
- `pocketworld_flutter/ios/Runner/AetherTexturePlugin.swift` — the
  shipping iOS native binding pattern for `aether_scene_renderer_*`;
  G3+ Dart FFI mirrors this from the Flutter side
