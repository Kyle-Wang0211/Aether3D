# aether_cpp Phase backlog

Deferred non-blocking work, organized by **trigger condition** (not by priority or date).
Items here are NOT lost — they're parked until their trigger fires. If no trigger,
the item shouldn't be here.

This complements `PHASE3_BLOCKER.md`:
- `PHASE3_BLOCKER.md` = blocking work that **must** land before Phase 3 (xcframework)
- `PHASE_BACKLOG.md` = non-blocking polish parked behind a clear trigger

---

## Phase 1 polish (deferred, non-blocking)

### device-lost callback on all 3 Dawn hello binaries
- **What**: Add `wgpu::DeviceDescriptor::SetDeviceLostCallback(...)` (or modern equivalent) to:
  - `aether_cpp/tools/aether_dawn_hello.cpp` (P1.4 adapter)
  - `aether_cpp/tools/aether_dawn_hello_compute.cpp` (P1.5 compute)
  - `aether_cpp/tools/aether_dawn_hello_triangle.cpp` (P1.7 triangle)
- **Why it's not cosmetic**: device-lost is GPU-disconnect / hot-unplug / driver-crash. Currently emits "Warning: No Dawn device lost callback was set" — Dawn says "this is probably not intended" because production code MUST handle it. Phase 1 hellos run for <1s in isolation so it's harmless **for these specific binaries**.
- **Trigger to do**: before any long-running Dawn compute job (Phase 4+ when training-kernel iterations run for minutes, or sustained render loops). The hellos themselves can stay loud-warn; the real targets that come later cannot.
- **Shape**: 1 chore commit. Parallel edit, ~20 min.

---

## How to add an item here

Each entry needs:
1. **What** — concrete, file-level pointer if applicable
2. **Why it's not cosmetic** — what real problem this prevents (or "is cosmetic" honestly)
3. **Trigger to do** — phase number / user-count threshold / runtime duration / platform expansion / etc. Specific, falsifiable.
4. **Shape** — rough commit/PR shape so future-you knows the cost

If you can't write a clear Trigger, the work isn't actually deferred — it's either dropped or it should be done now.
