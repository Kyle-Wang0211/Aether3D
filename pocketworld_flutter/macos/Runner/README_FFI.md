# macOS FFI Linking — Phase 6.4a

The macOS Flutter plugin (`MainFlutterWindow.swift`) calls into
`aether3d_ffi.dylib` (built by `aether_cpp/build/`) at runtime via
`dlopen` + `dlsym`. There is intentionally **no static link** to
`libaether3d_ffi.dylib` from the Xcode project — the dynamic-loading
approach avoids needing `project.pbxproj` modifications and gracefully
falls back to a Flutter `FFI_UNAVAILABLE` error if the dylib is missing.

## Dev workflow

```bash
# 1. Build the C++ library (one-time + after any .wgsl or C++ change).
cd aether_cpp/build
cmake --build . --target aether3d_ffi

# 2. Run the Flutter macOS app FROM REPO ROOT so the relative
#    `aether_cpp/build/libaether3d_ffi.dylib` path resolves.
cd /path/to/Aether3D-cross
flutter -d macos run

# Alternative: set DYLD_LIBRARY_PATH if running from elsewhere.
DYLD_LIBRARY_PATH=$PWD/aether_cpp/build flutter -d macos run
```

The Swift FFI binding tries these paths in order (see `FFI.shared` in
MainFlutterWindow.swift):
  1. `RTLD_DEFAULT` — symbols already in the process namespace.
  2. `aether_cpp/build/libaether3d_ffi.dylib` (relative to CWD)
  3. `../aether_cpp/build/libaether3d_ffi.dylib`
  4. `../../aether_cpp/build/libaether3d_ffi.dylib`
  5. `Bundle.main.bundlePath/Contents/Frameworks/libaether3d_ffi.dylib`
  6. `libaether3d_ffi.dylib` (generic dyld search path)

`Console.app` shows `[AetherFFI]` log lines indicating which path
resolved (or which all failed).

## Production install (Phase 6.5+ / TestFlight)

Copy `libaether3d_ffi.dylib` into `Runner.app/Contents/Frameworks/`
either via an Xcode "Run Script" build phase or post-build CMake step.
Path 5 above will resolve it. Codesigning the embedded dylib is required
for Gatekeeper-allowed distribution; for dev (`CODE_SIGNING_ALLOWED=NO`
in `Configs/Debug.xcconfig`) no codesign needed.

## Troubleshooting

| Symptom | Root cause |
|---|---|
| Widget shows `FFI_UNAVAILABLE` | dylib not found in any candidate path |
| Widget shows `RENDERER_FAILED` | dylib loaded but `aether_splat_renderer_create` returned NULL — check stderr for Dawn diagnostic |
| Widget shows `IOSURFACE_FAILED` | Apple-platform IOSurface allocation failed (rare; OOM territory) |

Run the FFI smoke directly to bypass Flutter and verify the C++ side:

```bash
cd /path/to/Aether3D-cross
./aether_cpp/build/aether_splat_iosurface_renderer_smoke
# Expected:
# === aether_splat_iosurface_renderer_smoke ===
# center (128,128) BGRA: B=162 G=162 R=162 A=255
# corner (0,0)     BGRA: B=0 G=0 R=0 A=255
# PASS
```
