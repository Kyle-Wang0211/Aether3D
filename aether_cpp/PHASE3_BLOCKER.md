# Phase 3 Blocker: Restore 3 bitrot sources before xcframework

**Status**: Active blocker for Phase 3 (Dart FFI / iOS xcframework packaging).
**Created**: 2026-04-25 during Phase 1 setup (Flutter + Dawn cross-platform base).
**Trigger**: A clean `cmake --build` of `aether_cpp/` under Xcode 26 / AppleClang 17 fails on 3 source files. The original local builds at `~/Documents/Aether3D/aether_cpp/build/` were incremental + older toolchain, so the bitrot never surfaced until a fresh worktree compile.

---

## What's commented out

Currently excluded from `aether_cpp/CMakeLists.txt`:

| File | Errors | Severity |
|---|---|---|
| `src/pipeline/pipeline_coordinator.cpp` | 1× `try` in `-fno-exceptions` (line 5393) + 1× set-but-not-used (`divergent_count`, line 5821) + 1× set-but-not-used (`sum_w`, line 6423) + 3× unused params (`gx`, `gy`, `gz`, line 6475) | Real bug + 5 trivial |
| `src/render/metal_gpu_device.mm` | 2× `dynamic_cast` in `-fno-rtti` (lines 921, 933) | Real bug |
| `src/splat/splat_render_engine.cpp` | 3× `try` in `-fno-exceptions` (lines 939, 954, 995) + 2× unused vars (`dominant_bottom_p20` line 581, `old_size` line 978) | Real bug + 2 trivial |

**Total**: 3 files, ~13 errors (6 real bugs + 7 trivial).

The commented-out lines in `CMakeLists.txt` are tagged `WIP:` for grep:
```bash
grep -n "WIP:" aether_cpp/CMakeLists.txt
```

---

## Why it's safe to defer

- The original `~/Documents/Aether3D/aether_cpp/build/libaether3d_core.a` was produced **without** these `.o` files (verified — no `pipeline_coordinator.o` / `metal_gpu_device.o` / `splat_render_engine.o` in original `CMakeFiles/aether3d_core.dir/`). So the current state matches reality, not regresses from it.
- `libaether3d_c.a` and `libaether3d_core.a` still link cleanly as static archives. Symbols referenced from `coordinator_c_api.cpp`, `streaming_c_api.cpp`, `splat_c_api.cpp`, `metal_c_api.mm` become unresolved-at-link-time, but archives don't enforce that — only final executable linking does, and we don't link any executable in Phase 1.

---

## What Phase 3 needs to do

Phase 3 = Dart FFI bridging to iOS xcframework. The xcframework MUST link a final binary, so unresolved symbols become real failures. Before Phase 3 starts:

### Real bug fixes (6 errors)

1. **`pipeline_coordinator.cpp:5393`** — `try` block under `-fno-exceptions`. Convert to error-code style return (likely a `aether_status_t` or `std::optional<>` pattern). Read the catch handler to know what failure modes need surfacing.
2. **`splat_render_engine.cpp:939, 954, 995`** — same pattern, 3 try blocks. Same conversion.
3. **`metal_gpu_device.mm:921, 933`** — `dynamic_cast` under `-fno-rtti`. Replace with one of:
   - Tag-based dispatch (`type_id` enum field on the base class)
   - `static_cast` if the static type is known at the call site
   - Visitor / variant pattern

### Trivial cleanups (7 errors)

Per [feedback memory: dead-code policy](../../../../.claude/projects/-Users-kaidongwang-Documents-progecttwo/memory/feedback_dead_code_policy.md), default to **delete** unless there's a concrete sprint plan to use:

- `pipeline_coordinator.cpp:5821` — `divergent_count` set but unused → delete
- `pipeline_coordinator.cpp:6423` — `sum_w` set but unused → delete
- `pipeline_coordinator.cpp:6475` — params `gx`, `gy`, `gz` unused → delete params or use them
- `splat_render_engine.cpp:581` — `dominant_bottom_p20` unused → delete
- `splat_render_engine.cpp:978` — `old_size` unused → delete

### Re-enable in CMakeLists.txt

Uncomment the 3 source lines + the `metal_gpu_device.mm` line in `set_source_files_properties` (search `WIP:`).

### Verify

`cmake --build aether_cpp/build --clean-first` succeeds + CI workflow [`.github/workflows/aether-cpp-clean-build.yml`](../.github/workflows/aether-cpp-clean-build.yml) passes.

---

## Anti-bitrot guard (now in place)

`.github/workflows/aether-cpp-clean-build.yml` runs `cmake --build --clean-first` on every PR touching `aether_cpp/`. After Phase 3 fixes land, this guard prevents the same bitrot from re-accumulating.
