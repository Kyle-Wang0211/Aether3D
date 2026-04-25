# Upstream comment — POSTED

**Status**: ✅ Posted 2026-04-25 → https://github.com/flutter/flutter/issues/185395#issuecomment-4320752280

**Target issue context**: We searched flutter/flutter for the canonical issue. Findings:
- `#181103` (closed COMPLETED 2026-01-17) — exact match in body, but auto-closed by github-actions bot for "no additional info" + thread locked. Can't comment.
- `#185395` (closed COMPLETED 2026-04-22) — same title, **closure was based on reporter's iCloud-Drive-specific cause**. Underlying provenance issue still affects non-iCloud setups on macOS 26.
- `#180351` (closed earlier) — earliest dup.
- `#172666` (open, 2025-07) — Sequoia upgrade scenario, different.
- `#183662` (open) — performance, not codesign.

We commented on `#185395` arguing the closure reason was incomplete (iCloud is one trigger, kernel-level provenance is another that affects local-disk projects too). If maintainers reopen or link a new issue, the GitHub notification reaches Kyle-Wang0211 → we know to delete `scripts/flutter_sdk_patches/` (Tier 3 repaid).

**The actual posted comment** (canonical source: see `git show` for this file's history; original draft kept below for reference and as spec for any follow-up comment):

---

## Original comment body (kept for reference)

Hitting this on macOS 26.1 (Build 25B78) + Xcode 26.2 + Flutter 3.41.7 (commit `cc0734ac716`).

`flutter build ios --simulator --debug --no-codesign` fails with:

```
Failed to codesign /<path>/Flutter.framework/Flutter with identity -.
/<path>/Flutter.framework/Flutter: replacing existing signature
/<path>/Flutter.framework/Flutter: resource fork, Finder information, or similar detritus not allowed
```

Confirmed root cause: every file in the unpacked `Flutter.framework` carries
the `com.apple.provenance` xattr (added by the kernel during file copies on
macOS 14+). It is **kernel-protected** — `xattr -c`, `xattr -d com.apple.provenance`,
and `ditto --noextattr` all silently fail to remove it.

### Why `removeFinderExtendedAttributes` doesn't fix it

In `flutter_tools/lib/src/ios/mac.dart`, the function only deletes
`com.apple.FinderInfo`:

```dart
'xattr', '-r', '-d', 'com.apple.FinderInfo', projectDirectory.path,
```

That misses `com.apple.provenance`. Even switching to `xattr -c -r` (clear all)
doesn't actually remove provenance — the kernel re-adds it.

### Local workaround (two patches)

We're shipping these locally as a workaround. Posting in case it helps others
or informs the upstream fix.

**Patch 1** — `flutter_tools/lib/src/ios/mac.dart`: switch
`removeFinderExtendedAttributes` to `xattr -c -r`. Mostly cosmetic since the
kernel-protected provenance still survives, but this addresses the FinderInfo
case more aggressively.

**Patch 2** — `flutter_tools/lib/src/build_system/targets/ios.dart`,
`_signFramework()`: early-return when `kSdkRoot` contains `iPhoneSimulator`.
Simulator doesn't enforce codesign at runtime, so skipping is safe. Device /
IPA builds still go through codesign (and would still hit this issue with a
real signing identity — separate problem).

```dart
final String? sdkRoot = environment.defines[kSdkRoot];
if (sdkRoot != null && sdkRoot.contains('iPhoneSimulator')) {
  return;
}
```

After both patches: simulator builds succeed, app installs and launches on
booted simulator with the correct bundle identifier.

### Reproduction

```
$ sw_vers -productVersion   # 26.1
$ xcodebuild -version       # Xcode 26.2
$ flutter --version         # 3.41.7
$ touch /tmp/foo && xattr -l /tmp/foo
com.apple.provenance:        # <-- already there on a freshly-touched file
$ xattr -c /tmp/foo && xattr -l /tmp/foo
com.apple.provenance:        # <-- still there
```

Happy to share the actual `.patch` files if useful for the upstream fix.
