# aether_cpp Phase backlog

Deferred non-blocking work, organized by **trigger condition** (not by priority or date).
Items here are NOT lost — they're parked until their trigger fires. If no trigger,
the item shouldn't be here.

This complements `PHASE3_BLOCKER.md`:
- `PHASE3_BLOCKER.md` = blocking work that **must** land before Phase 3 (xcframework)
- `PHASE_BACKLOG.md` = non-blocking polish parked behind a clear trigger

---

## Phase 2 blocker workarounds (Flutter SDK local patches — fragile)

### Two patches applied to global Flutter SDK at `/opt/homebrew/share/flutter/`
- **What**: Patched two files inside the user's Homebrew-installed Flutter 3.41.7 to work around a macOS 26 + Flutter codesign incompatibility:
  1. `packages/flutter_tools/lib/src/ios/mac.dart` `removeFinderExtendedAttributes()` — changed from `xattr -r -d com.apple.FinderInfo <path>` to `xattr -c -r <path>` (clear all xattrs, not just FinderInfo). Flutter only handles the old FinderInfo xattr; macOS 14+ adds `com.apple.provenance` to every copied file which breaks ad-hoc codesign with "resource fork ... detritus not allowed".
  2. `packages/flutter_tools/lib/src/build_system/targets/ios.dart` `_signFramework()` — added an early return for iOS Simulator builds (detected via `kSdkRoot` containing "iPhoneSimulator"). Reason: `com.apple.provenance` is **kernel-protected** on macOS 14+ — `xattr -c -r`, `xattr -d com.apple.provenance`, and `ditto --noextattr` all fail to remove it. Codesign then fails. Simulator doesn't enforce codesign at runtime, so skipping is safe; physical-device builds still go through codesign.
- **Why it's not cosmetic**: Without these patches, `flutter build ios --simulator` always fails with "Failed to codesign Flutter.framework/Flutter ... resource fork, Finder information, or similar detritus not allowed". Phase 2.2 (and any subsequent simulator deploy) cannot complete.
- **Verified result**: After patches, `flutter build ios --simulator --debug --no-codesign` succeeds, `Runner.app` produced, installed and launched on iPhone 17 Pro Simulator (booted), screenshot at `/tmp/pocketworld_p22.png` shows "Flutter Demo Home Page" + counter UI.
- **Trigger to revisit**:
  - **Before Phase 2.3 (real iPhone build)** — physical-device codesigning may hit the same provenance issue but with a real Apple Developer cert. Need to test, may need additional patch.
  - **Whenever Flutter SDK is upgraded** (`brew upgrade flutter`) — patches are silently lost. The flutter_tools snapshot is rebuilt to include them but only because we manually deleted the snapshot file. After upgrade: re-apply both patches OR pin Flutter version in `CROSS_PLATFORM_STACK.md` until upstream fix lands.
  - **When Flutter merges a real fix** for `com.apple.provenance` (track flutter/flutter#156098 and related). Revert these local patches.
- **Shape**: 2 small patches in flutter_tools .dart files + force-rebuild of `bin/cache/flutter_tools.snapshot` (delete `.stamp` and `.snapshot`, then run `flutter --version`). Total ~5 minutes if patches are lost.
- **Re-application recipe** (when needed):
  ```bash
  # Clear xattrs in mac.dart line ~715
  # Replace xattr -r -d com.apple.FinderInfo with xattr -c -r
  # Add early return in ios.dart _signFramework() for iPhoneSimulator sdkRoot
  rm /opt/homebrew/share/flutter/bin/cache/flutter_tools.{stamp,snapshot}
  flutter --version   # forces snapshot rebuild
  ```

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
