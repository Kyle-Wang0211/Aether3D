# Flutter SDK local patches

Two `.patch` files that work around a macOS 14+ kernel-level bug breaking
ad-hoc codesigning of `Flutter.framework`. Without them, `flutter build ios
--simulator` always fails with:

> Failed to codesign Flutter.framework/Flutter ... resource fork, Finder
> information, or similar detritus not allowed

## What the patches do

| File | Patch summary |
|---|---|
| `0001-clear-all-xattrs.patch` | In `flutter_tools/lib/src/ios/mac.dart`: `removeFinderExtendedAttributes()` was running `xattr -r -d com.apple.FinderInfo`. Changed to `xattr -c -r` (clear all xattrs). Flutter only handled the legacy FinderInfo xattr; macOS 14+ added `com.apple.provenance`. |
| `0002-skip-codesign-on-simulator.patch` | In `flutter_tools/lib/src/build_system/targets/ios.dart`: `_signFramework()` early-returns when `kSdkRoot` contains `iPhoneSimulator`. The provenance xattr is **kernel-protected** — `xattr -c`, `xattr -d`, and `ditto --noextattr` all silently fail to remove it. Simulator doesn't enforce codesign at runtime, so skipping is safe. Physical-device builds still go through codesign. |

## Lifecycle (where this debt sits)

This is **debt restructuring, not repayment**. The patches still exist;
they're now in repo and reproducible across machines / CI / brew upgrades.
Real repayment is upstream Flutter merging a fix.

| Status | Action needed |
|---|---|
| Tier 1 — patches in repo, applied via `apply.sh` | ← **You are here** |
| Tier 3 — Flutter merges upstream fix | Delete this whole directory + revert `_signFramework` change reference in `aether_cpp/PHASE_BACKLOG.md`. Track [flutter/flutter#156098](https://github.com/flutter/flutter/issues/156098) and the linked PRs. |

## How to apply

```bash
bash scripts/flutter_sdk_patches/apply.sh
```

Idempotent. Run after:
- `git clone` on a new machine
- `brew upgrade flutter` (warning: this likely breaks the patch — see below)
- A teammate pulls and is missing the patch

`apply.sh`:
1. Locates the Flutter SDK via `flutter --version --machine`.
2. Greps for our patch markers; if both present, exits 0 silently.
3. Runs `git apply --check` against the SDK; if patch doesn't apply cleanly (Flutter version drifted), exits 1 with a clear error.
4. Applies each patch via `git apply` and re-verifies the markers.
5. Force-rebuilds `bin/cache/flutter_tools.snapshot` (deletes the snapshot and stamp, runs `flutter --version`).

## When `brew upgrade flutter` happens

Bumping Flutter past the pinned version (`3.41.7` / commit `cc0734ac716`) is **likely** to break the patches:

- File paths might move
- Surrounding lines might change → `git apply` fuzz fails

If `apply.sh` exits 1 after a Flutter upgrade:
1. Do not blindly hand-edit. Pin Flutter back to `3.41.7` first (`flutter downgrade` or re-install via brew@3.41.7).
2. Re-validate that simulator builds work.
3. Then bump Flutter intentionally and regenerate patches against the new version.

The pin is documented in [`CROSS_PLATFORM_STACK.md`](../../CROSS_PLATFORM_STACK.md) at the project root.

## Upstream signal channel

`upstream_comment_draft.md` in this directory is a draft GitHub comment to post on
[flutter/flutter#156098](https://github.com/flutter/flutter/issues/156098) (or the
current canonical issue for the provenance xattr problem). Posting it:
- Captures our patch publicly so half-a-year-from-now we remember which upstream issue this maps to.
- Hooks us into the GitHub notification thread — when Flutter merges a fix, our comment is in the thread, GitHub pings us, and we know to delete this directory.

If you've already posted it, delete or annotate the draft file.

## CI integration (Phase 2 onwards)

When the Flutter app gets its own CI workflow, the **first step after Flutter setup must be**:

```yaml
- name: Apply Flutter SDK patches
  run: bash scripts/flutter_sdk_patches/apply.sh
```

`apply.sh` is idempotent and exits 1 on any failure — exactly what CI expects.

## When this directory can disappear

Delete the whole `scripts/flutter_sdk_patches/` directory and remove the apply step from CI when:
- Upstream Flutter has merged a fix that handles `com.apple.provenance` natively, AND
- The pinned Flutter version (`CROSS_PLATFORM_STACK.md`) is bumped to a release containing that fix.

That's the moment debt is **repaid**, not just restructured.
