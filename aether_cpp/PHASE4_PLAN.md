# Phase 4 plan — Flutter Texture widget ↔ Dawn render interop (skeleton draft)

**Status**: SKELETON. Drafted at end of Phase 3 productive pause as the next-phase preparation. NOT a kickoff — fresh kickoff session is intentional.

---

## ⚠️ PRE-KICKOFF CORRECTIONS PENDING

This skeleton has 3 internal contradictions + 1 missing piece, identified
during a post-draft review. **Do NOT execute as-is** — resolve these 4
items as the FIRST 30 min of the kickoff session, before touching any
sub-step. Then update the body of this plan accordingly.

### 1. Recommended execution order contradicts the "de-risk by validation chain" principle stated in the same plan

The plan body declares "order by 'can I verify cheaply', front-load
low-risk validations" — but the recommended order puts 4.0 (🔴 HIGH-risk
Dawn-iOS unblock) first.

Proposed fix (validate before adopting): swap to
**4.1 + 4.5 → 4.2 → 4.0 → 4.3 → 4.4 → 4.6**

Rationale: 4.1 + 4.5 (Flutter Texture widget plumbing with CPU pixel
fallback) is low-risk + low-cost foundation. 4.2 (IOSurface bridge,
the real boss fight) goes next since 4.0/4.3 depend on its output.
4.0 (Dawn-iOS) goes mid-Phase so a 4.0 abort still leaves
4.1+4.2+4.5 = "Flutter ↔ native GPU bridge with CPU data" landed
as Phase 4 value, instead of Phase 4 dying on day-1 toolchain debug.

### 2. Timebox inconsistency between body and kickoff prompt

- Body: "Per sub-step: 1 working day"
- Kickoff prompt at end: "set a 2-hour timer on enabling Dawn for iOS"

Proposed fix: split per sub-step character.
- **2-hour timebox for 4.0 specifically** — toolchain-spiral-prone, 2h
  is enough to distinguish "trivial flag tuning" vs "deep
  incompatibility"; longer means infinite-rabbit-hole risk.
- **1-day timebox for 4.2** — IOSurface bridge is real engineering,
  needs hours of focused implementation + testing; 2h is too short to
  reach a confident yes/no.
- Kickoff prompt and body must match after the fix; right now reading
  one then the other causes execution-time hesitation.

### 3. Implicit prereq: Phase 3.5 status is assumed unblocked, but BACKLOG marks it deferred

Phase 4 sub-steps 4.0 / 4.1 / 4.2 / 4.3 / 4.5 all need iOS deploy to
verify. But Phase 3.5 (CocoaPods static xcframework integration) is
deferred — without it, no iOS deploy works.

Proposed fix (validate before adopting): **do Phase 4 on macOS desktop
first** (Flutter macOS supports Texture widget, Metal works natively
on macOS). All sub-steps validated on macOS first, then port to iOS
once Phase 3.5 unblocks. This decouples Phase 4 progress from Phase 3.5.

Open question: does Flutter macOS desktop's Texture widget have
feature parity with iOS for IOSurface-equivalent shared-texture
mechanics? Apple's IOSurface is cross-platform (macOS + iOS) but
the Flutter binding API may differ — research item before kickoff.

### 4. Missing Definition of Done

Sub-step 4.6 finishing doesn't equal Phase 4 finishing — there's no
explicit measurable exit criterion in the plan, so "is this done yet?"
becomes a judgment call.

Proposed fix (validate the specific numbers): add a DoD section like

> Phase 4 done = Flutter widget displays a 256×256 native-GPU-rendered
> animated content, sustained 60 fps for 30 s on iPhone 17 Pro Simulator
> (or, in macOS-first variant, on macOS desktop), with no frame drops
> or crashes. Screenshot + 30-second screen recording filed alongside
> the verification ritual.

Numbers can be tuned (60 fps may be ambitious, 30 fps may be enough;
30 s may be unnecessary). Pick numbers explicitly so kickoff has a
falsifiable yes/no exit.

### Why these are pre-kickoff corrections, not "fix now"

These 4 items are **decision-load** work — choosing the right execution
order, the right timebox split, the right prereq strategy, the right
DoD numbers. Doing them tired-from-Phase-3 risks introducing fresh
mistakes that the next round of review catches. Per "productive pause
covers low-decision actions only" principle, **plan corrections deserve
the same fresh-head treatment as execution itself**.

After corrections land at kickoff start (~30 min), the rest of this
file (sub-step inventory, abort criteria, scope, pre-kickoff checklist,
out-of-scope list, kickoff prompt) still applies — the bones are
sound, only ordering / prereq / timebox / DoD need decision.

---

**Phase 4 mission**: from Flutter UI (Dart), render Dawn-produced GPU content onto a Flutter widget. The user's stated goal: "Flutter Texture widget ↔ Dawn IOSurface 互通". This is the deepest cross-language / cross-platform plumbing in the entire roadmap.

---

## Why Phase 4 deserves its own kickoff

User-defined property: Phase 4 is **the highest-risk phase in the roadmap**. Three risks compounding:

| Layer | Risk | Why |
|---|---|---|
| Flutter Texture widget | medium | Standard but each plugin has gotchas |
| iOS IOSurface ↔ MTLTexture ↔ CVPixelBuffer | **HIGH** | Documentation sparse, Apple frameworks interact awkwardly, subtle ownership rules |
| Dawn-on-iOS render-to-Metal-texture | high | Dawn's iOS path untested in our project (P3.1 deferred) |

Three high-risk layers in one phase = three independent failure modes that look identical from Flutter's red-screen viewpoint. Without disciplined sub-step decomposition, debugging is brutal.

---

## Sub-step decomposition (de-risk by validation chain, not dependency order)

Per established de-risk principle (memory: feedback_phase_ordering_by_risk): order by "can I verify cheaply", front-load low-risk validations.

### Sub-step inventory + risk + validation environment

| # | Description | Risk | Validation env | Cost-to-fail |
|---|---|---|---|---|
| 4.0 | Cross-platform Dawn-iOS unblock — re-enable Dawn for iOS xcframework | 🔴 HIGH | iOS Sim | days (own sub-phase) |
| 4.1 | Flutter plugin scaffold: register external Texture, get textureId | 🟡 medium | iOS Sim | hours |
| 4.2 | iOS plugin: IOSurface-backed `MTLTexture` + bridge into `CVPixelBuffer` for Flutter Texture | 🔴 HIGHEST | iOS Sim → real device | day(s) |
| 4.3 | Dawn renders to that shared `MTLTexture` (P1.7 triangle hello becomes the workload) | 🟡 medium | iOS Sim (depends on 4.0) | hours |
| 4.4 | `markFrameAvailable(textureId)` plumbing — Dawn frame done → Flutter sees update | 🟢 low | iOS Sim | hour |
| 4.5 | Flutter widget renders the Texture | 🟢 low | iOS Sim | min |
| 4.6 | Per-frame animation (rotate triangle, ~60fps) | 🟢 low | iOS Sim | min |

### Recommended execution order (de-risk first, save high-risk for after foundation)

1. **4.0 (Dawn-iOS unblock)** — but ONLY if it doesn't immediately consume a 1-day budget. If it does, abort and use降级 path: skip 4.0, do 4.1+4.2+4.5+4.6 with a CPU-rendered demo image (no Dawn). Phase 4's core value is "Flutter ↔ native GPU bridge proven"; the actual GPU content can be Dawn (preferred) or just CPU pixels (fallback) without changing the architectural validation.
2. **4.1 + 4.5** — empty Flutter plugin + dummy texture → widget shows placeholder. Validates Flutter Texture binding mechanics in isolation.
3. **4.2 — the real boss fight** — with 4.1 in place, focus debugging on IOSurface bridge alone. 1-day timebox.
4. **4.3** (post 4.2) — point Dawn at the shared MTLTexture, render P1.7's triangle.
5. **4.4 + 4.6** — frame signaling + animation. Mostly mechanical.

### Dependency note

4.3 depends on 4.0 (Dawn-iOS) AND 4.2 (shared texture). If both fail, the降级 chain is:
- 4.0 fails → use software rendering (CPU pixels) instead of Dawn
- 4.2 fails → use `UiKitView` wrapping `MTKView` directly (Phase 4 user spec listed this as fallback). Performance worse but architecturally proves Flutter ↔ native UI mixing.

---

## Abort criteria (per phase, separate from prior bitrot criteria)

- **Per sub-step**: 1 working day. If not making progress on 4.2 IOSurface after 1 day, fall back to UiKitView path (降级).
- **Whole phase**: if both 4.0 AND 4.2 fail, Phase 4 ends with the UiKitView fallback shipped + Dawn / IOSurface deferred to a future phase. The architectural goal (Flutter ↔ native GPU on iOS) still proven via UiKitView+MTKView.
- **Time budget total**: 1 working week soft cap. Phase 4 is NOT permitted to consume 2 weeks; if it does, kick off Phase-4-architecture-review session before continuing.

---

## Pre-kickoff checklist (do BEFORE Phase 4 first session)

- [ ] **Re-read** Phase 4 user spec from prior conversation (they had specific sub-tasks already)
- [ ] **Review** how Polycam / Brush / production 3DGS apps do Flutter ↔ native GPU on iOS (if any do — Brush is Rust+wgpu+egui, not Flutter)
- [ ] **Read** Flutter `Texture` widget docs + at least one Flutter plugin tutorial that uses `FlutterTextureRegistry` for iOS native GPU rendering (not just video)
- [ ] **Read** Apple's IOSurface + CVPixelBuffer + MTLTexture interop docs — at minimum the "creating textures from CVPixelBuffer" section
- [ ] **Check** whether the Phase 3.5 unblock has happened in the meantime (CocoaPods static xcframework integration) — if yes, P3.5 finishes first; if no, Phase 4 proceeds with a separate Pod for iOS-side Texture plugin (different problem space)
- [ ] **Set** explicit 1-day timebox on calendar for sub-step 4.2 specifically — this is where the project will spend most of Phase 4

---

## What stays out of Phase 4 scope (avoid scope creep — per memory: feedback_bitrot_recovery_playbook + feedback_layered_risk_validation)

- ❌ Dawn-iOS performance tuning beyond "renders correctly"
- ❌ Multi-touch / gesture handling on the Texture widget (Phase 5+)
- ❌ Multi-render-target / G-buffer / deferred shading (Phase 5+ when actual product graphics)
- ❌ HDR / wide-gamut color management (Phase 5+ visual polish)
- ❌ Android Vulkan equivalent (Phase 5+ when iOS path proven)

---

## Open questions for kickoff session

1. Does Flutter 3.41.7 on macOS 26 / iOS 26 have any Texture widget regressions vs older versions? (Quick search before kickoff)
2. Is Dawn's iOS Metal path tested upstream by Google? Or is iOS in Dawn's "best effort" tier?
3. Does our 1.16 CocoaPods quirk (PHASE_BACKLOG.md, Phase 3.5) recur for the iOS Texture plugin if we use a Pod? Or is the plugin handling different enough to bypass it?

---

## What's already in place (don't redo)

- Phase 3 architecture (Dart ↔ aether_cpp ↔ Dawn) verified at the binding level on macOS
- iOS xcframework build script ready (`scripts/build_ios_xcframework.sh`)
- iOS toolchain quirks documented (CROSS_PLATFORM_STACK.md "Lessons learned")
- Phase 4 user spec from earlier conversation has the sub-step skeleton
- iPhone 17 Pro Simulator is the standard test device

---

## Kickoff prompt for next session

> Phase 4 kickoff. Read PHASE4_PLAN.md top-to-bottom. **First 30 min**:
> resolve the 4 items in "PRE-KICKOFF CORRECTIONS PENDING" — pick an
> execution order, pick timebox split, decide macOS-first vs wait-for-3.5,
> pick DoD numbers. Edit the plan body to reflect those decisions, then
> delete the corrections-pending section. **Then** execute the (now
> corrected) sub-step 1 of the new order, with that sub-step's timebox.
