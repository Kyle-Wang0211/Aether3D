# Upstream comment draft

**Target issue**: [flutter/flutter#156098](https://github.com/flutter/flutter/issues/156098) (or whichever issue is currently tracking the `com.apple.provenance` codesign break — verify before posting).

**Action**: copy the body below, paste as a new comment, post. Then delete this file (or annotate at top: "posted YYYY-MM-DD").

**Why post this**: the Tier 3 transition signal channel. Half a year from now we may not remember which upstream issue our local patches map to. Posting lets GitHub notify us when a fix lands, so we know to delete `scripts/flutter_sdk_patches/`.

---

## Comment body (copy from here)

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
