# Draft: Apple Feedback Assistant — file provider re-tags `~/Documents/` files breaking codesign

**Status**: DRAFT, not filed. Stored locally as the upstream-signal counterpart to the
`scripts/flutter_sdk_patches/upstream_comment_draft.md` (which targets Flutter for the
related `com.apple.provenance` issue). File when:

- Phase 6 kickoff confirms this is still biting daily, OR
- Apple ships a macOS 26.x point release that we can verify-against, OR
- Find time during a Phase 6 productive pause

---

## Title (suggested)

> macOS 26.1: `com.apple.fileprovider.fpfs#P` re-tags `~/Documents/` files within milliseconds, breaking `codesign` on iOS builds with `BUILD_DIR` redirected into Documents

## Area / Component

- File System
- Code Signing
- File Provider

## OS / Hardware

- macOS 26.1 (build 25B78), Apple M3 Pro
- Xcode 26.2 (build 17C52)

## Description

When iOS builds redirect `BUILD_DIR` to a path under `~/Documents/`
(common for cross-platform tools like Flutter, which use
`<project>/build/ios/`), the macOS file provider system continuously
re-applies `com.apple.FinderInfo` and `com.apple.fileprovider.fpfs#P`
extended attributes to files under that tree. `codesign` rejects files
carrying `com.apple.FinderInfo` with the error:

```
resource fork, Finder information, or similar detritus not allowed
```

The xattrs ARE removable via `xattr -d com.apple.FinderInfo` and
`xattr -d com.apple.fileprovider.fpfs#P`, but the file provider re-tags
within milliseconds. Verified by:

1. Run `xattr -lr <BUILD_DIR>` immediately after `xattr -d` recursive removal
2. xattrs already back

The same `xcodebuild` invocation, with the default DerivedData output
path (`~/Library/Developer/Xcode/DerivedData/...`), succeeds — DerivedData
is NOT file-provider-tracked.

## Reproduction

```bash
# 1. Clone any SwiftUI / iOS project. Place at ~/Documents/.
# 2. Run:
xcodebuild -workspace <Workspace>.xcworkspace -scheme <Scheme> \
  -configuration Debug -destination 'generic/platform=iOS' \
  -allowProvisioningUpdates \
  BUILD_DIR=<absolute-path-under-Documents>

# Expected: Build succeeds.
# Actual: codesign fails with "resource fork, Finder information, or similar detritus not allowed".

# 3. Run the same WITHOUT BUILD_DIR override (defaults to DerivedData):
xcodebuild -workspace <Workspace>.xcworkspace -scheme <Scheme> \
  -configuration Debug -destination 'generic/platform=iOS' \
  -allowProvisioningUpdates

# Expected and actual: succeeds.
```

The differentiator is purely the BUILD_DIR location. Same files, same
team, same identity — only the output path differs.

## Workaround we've adopted

Race-window: `xattr -d com.apple.FinderInfo` recursively + `codesign` in
the same shell invocation completes before the file provider re-tags.

```bash
find $APP -exec xattr -d com.apple.FinderInfo {} +
find $APP -exec xattr -d "com.apple.fileprovider.fpfs#P" {} +
codesign --force --sign $IDENTITY ...  $APP
```

Workaround is fragile (depends on the file provider's re-tag latency,
which may shrink in future macOS updates). Codified in our project at
`scripts/deploy_iphone.sh`.

## Why this matters beyond our project

- Any cross-platform mobile build tool that redirects `BUILD_DIR` into
  the project source tree will hit this. Flutter (`flutter build ios`)
  is the obvious case; React Native, Capacitor, Cordova use similar
  patterns.
- Solo developers who keep their projects under `~/Documents/` (the
  default Mac convention) pay this cost on every iOS build.
- The xattr is documented as file-provider provenance tracking, but
  applying it to plain build artifacts in user-content directories
  seems like over-application — build artifacts aren't user content
  in the file-sync sense.

## Suggested Apple-side fix

One of:

1. Have `codesign` ignore `com.apple.FinderInfo` if it's empty (which
   it is — `xattr -l` shows zero-length value). Empty FinderInfo is
   metadata-presence, not actual resource fork data.
2. Have file provider not re-tag files actively being written to (the
   build pipeline writes thousands of files in seconds; tagging them
   while still being written corrupts the codesign step).
3. Add an opt-out attribute (e.g. an `.fileprovider-ignore` marker
   file in the BUILD_DIR root, similar to `.gitignore`).

## Cross-references

- Our paired Flutter-side workaround: `scripts/flutter_sdk_patches/`
  + `upstream_comment_draft.md` (Flutter SDK xattr clearing)
- Project `PHASE_BACKLOG.md` "Phase 5.2 iPhone real device deploy" —
  full diagnosis history (3 reframings before landing on this root
  cause)

---

## Notes for filing day

- Apple Feedback Assistant requires macOS app to file (no web). Run
  `Feedback Assistant.app` from Applications.
- Reference this file's timestamp + the commit hash that introduced
  the workaround (`16f7e011`) for traceability.
- Attach the build log diff (BUILD_DIR=Documents vs DerivedData) so
  Apple's reproduction is one command away.
