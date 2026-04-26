# Phase 4 plan — Flutter Texture widget ↔ native GPU interop

**Status**: KICKED OFF (corrections resolved, executing).

**Phase 4 mission**: from Flutter UI (Dart), render native-GPU-produced
content onto a Flutter widget. The user's stated goal: "Flutter Texture
widget ↔ native GPU 互通". This is the deepest cross-language /
cross-platform plumbing in the entire roadmap.

---

## Decisions made at kickoff

(These resolved the 4 PRE-KICKOFF CORRECTIONS that were pending after
the post-draft self-review.)

### D1. Execution order (de-risk by validation chain, not dependency order)

| # | Step | Risk | Validation env | Timebox |
|---|---|---|---|---|
| 1 | **4.1 + 4.5** Flutter Texture widget + dummy CPU pixels | 🟡 + 🟢 | macOS desktop | **3 hours** (abort → reset) |
| 2 | **4.2** IOSurface-backed shared `MTLTexture` (replaces CPU pixels) | 🔴 highest | macOS desktop | **8 hours hard / 1 working day soft** (abort → UiKitView/AppKitView fallback) |
| 3 | **4.0** Dawn-iOS unblock (re-enable Dawn for iOS xcframework build) | 🔴 high | iOS Simulator (eventually) | **2 hours strict** (abort → CPU/Metal-direct, skip step 4) |
| 4 | **4.3** Dawn renders triangle to shared texture (P1.7 workload as render source) | 🟡 medium | macOS desktop or iOS Sim | hours (only if step 3 passed) |
| 5 | **4.4** `markFrameAvailable(textureId)` plumbing | 🟢 low | same | 30 min |
| 6 | **4.6** Per-frame animation + DoD verification | 🟢 low | same | 30 min |

**Rationale**: 4.1+4.5 (Flutter Texture mechanics with CPU fallback) is
low-risk + low-cost foundation. 4.2 (IOSurface bridge, the real boss
fight) goes next since 4.0/4.3 depend on its output. 4.0 (Dawn-iOS) goes
mid-Phase so a 4.0 abort still leaves 4.1+4.2+4.5 = "Flutter ↔ native
GPU bridge with CPU data" landed as Phase 4 value, instead of Phase 4
dying on day-1 toolchain debug.

### D2. Phase 3.5 prereq → macOS-desktop-first

Phase 3.5 (CocoaPods static xcframework integration on iOS) is deferred
in BACKLOG. iOS deploy of any plugin will hit the same wall.

**Decision**: do all of Phase 4 on **Flutter macOS desktop** first.
Flutter macOS supports the Texture widget; Metal is native on macOS;
IOSurface is cross-platform (macOS + iOS) so the bridge code transfers.
iOS port becomes a separate Phase 4.7 follow-up once Phase 3.5 unblocks.

This **decouples Phase 4 from Phase 3.5** — Phase 4 doesn't have to
wait. The architectural goal ("Flutter ↔ native GPU bridge") is
proven on macOS; the iOS port is mechanical once both Phase 3.5 and
Phase 4-on-macOS land.

### D3. Timebox split (per character of each sub-step)

- **4.0 = 2 hours strict**. Toolchain-spiral-prone — 2h is enough to
  distinguish "trivial flag tuning" vs "deep incompatibility"; longer
  means infinite-rabbit-hole risk.
- **4.2 = 8h hard / 1 day soft**. IOSurface bridge is real engineering,
  needs hours of focused implementation + testing; 2h is too short to
  reach a confident yes/no.
- **4.1 = 3h**. Flutter Texture widget plumbing is well-trodden ground;
  if 3h doesn't yield a CPU-rendered gradient on screen, something
  fundamental is wrong (Flutter macOS desktop broken, plugin API
  changed, etc.) — better to reset and investigate than push.
- **Whole phase = 1 working week soft cap**.

### D4. Definition of Done

> **Phase 4 done** = Flutter widget displays a 256×256 native-GPU-
> rendered animated content, sustained 60 fps for 30 seconds on macOS
> desktop (or, post Phase 3.5 unblock + iOS port, on iPhone 17 Pro
> Simulator), with no frame drops or crashes. Screenshot + 30-second
> screen recording filed alongside the verification ritual.

If 4.0 aborts → "native GPU" is CPU pixels filled via Metal blit
encoder, still satisfies DoD architecturally (Flutter ↔ native GPU
bridge proven; the GPU just isn't producing the content for now).

If 4.2 aborts → use UiKitView/AppKitView wrapping a directly-rendering
Metal view; performance is worse but the DoD architectural goal still
ships.

---

## Three failure modes and their cascading degradation paths

| If this fails | Phase 4 still ships with |
|---|---|
| 4.0 (Dawn-iOS toolchain) | CPU/Metal-direct rendering instead of Dawn (same Flutter side) |
| 4.2 (IOSurface bridge) | UiKitView/AppKitView wrapping native Metal view (different Flutter side, no Texture widget) |
| Both 4.0 + 4.2 | macOS-only Phase 4 with Metal-direct via AppKitView, Dawn deferred to Phase 5+ |
| Whole phase blocks before any sub-step lands | Phase 4 architecture review session before retry |

Each fallback is **independently sufficient** to claim Phase 4
architectural value. Two compound to merge cleanly.

---

## Abort criteria (kept from prior plan, harmonized with D3 timeboxes)

- **Per sub-step**: timeboxes per D3 above. Strict — when timer fires,
  abort to the listed degradation path, do NOT extend.
- **Whole phase**: if both 4.0 AND 4.2 fail, Phase 4 ends with
  AppKitView fallback shipped + Dawn / IOSurface deferred to Phase 5+.
  The architectural goal still met via the fallback.
- **Time budget total**: 1 working week soft cap. Phase 4 is NOT
  permitted to consume 2 weeks; if it does, kick off Phase-4-
  architecture-review session before continuing.

---

## Pre-kickoff checklist (Step 0 — context load, ~30 min, must do)

- [ ] **Read** Flutter Texture widget API: https://api.flutter.dev/flutter/widgets/Texture-class.html
- [ ] **Read** at least one iOS plugin example using `FlutterTextureRegistry` for native GPU (not just video)
- [ ] **Read** Apple IOSurface + MTLTexture interop:
  - https://developer.apple.com/documentation/iosurface/iosurfaceref
  - https://developer.apple.com/documentation/metal/mtldevice/1433378-newtexturewithdescriptor
- [ ] **Verify** Flutter macOS desktop target is available + works on this machine

**Knowledge check before starting Step 1**: be able to describe how Flutter's Texture
widget reads pixels from native side without consulting docs. If you can't, Step 1
will burn time on fumbling instead of the actual plugin work.

---

## What stays out of Phase 4 scope (avoid scope creep)

- ❌ Dawn-iOS performance tuning beyond "renders correctly"
- ❌ Multi-touch / gesture handling on the Texture widget (Phase 5+)
- ❌ Multi-render-target / G-buffer / deferred shading (Phase 5+)
- ❌ HDR / wide-gamut color management (Phase 5+)
- ❌ Android Vulkan equivalent (Phase 5+ once iOS path proven)
- ❌ iOS port of Phase 4 work — defer to Phase 4.7 after Phase 3.5 unblock

---

## What's already in place (don't redo)

- Phase 3 architecture (Dart ↔ aether_cpp via dart:ffi) verified on macOS Dart CLI
- Phase 1 Dawn `aether_dawn_hello_triangle` proves Dawn renders to a Metal texture (PPM output)
- iOS xcframework build script (`scripts/build_ios_xcframework.sh`) ready for the eventual iOS port
- iOS toolchain quirks documented (CROSS_PLATFORM_STACK.md "Lessons learned")

---

## Commit strategy (atomic per sub-step, matches prior phases)

| Commit | Content |
|---|---|
| `feat(pocketworld): Phase 4.1 Flutter Texture widget + dummy CPU pixels` | Step 1 done |
| `feat(pocketworld): Phase 4.2 IOSurface-backed shared MTLTexture` | Step 2 done |
| `feat(aether_cpp): Phase 4.0 Dawn-iOS xcframework support` | Step 3 done (only if passed) |
| `feat(pocketworld): Phase 4.3 Dawn renders triangle to shared texture` | Step 4 done |
| `feat(pocketworld): Phase 4.4 + 4.6 frame signaling + 60fps animation + DoD verification` | Step 5+6 done |

Verify each sub-step's validation passing before committing.

---

## Active execution log

(Updated as steps complete — current cursor at top.)

- **Step 0 in progress**: context load + macOS desktop target enable
