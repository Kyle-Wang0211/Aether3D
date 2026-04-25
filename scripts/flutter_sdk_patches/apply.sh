#!/usr/bin/env bash
#
# Apply Aether3D's local Flutter SDK patches.
#
# Why this exists: macOS 14+ adds the kernel-protected com.apple.provenance
# extended attribute to every copied file. Flutter's ad-hoc codesign of
# Flutter.framework then fails with "resource fork ... detritus not allowed".
# Two patches in this directory work around it. See README.md for the lifecycle.
#
# Behavior:
#   - Idempotent: if both markers are already present, exits 0 silently.
#   - Strict: if any patch fails to apply (Flutter version drift), exits 1.
#   - Self-verifying: greps for the patch markers post-apply.
#   - Forces flutter_tools.snapshot rebuild so changes take effect immediately.
#
# Designed to be safe to run from CI (idempotent + clear exit codes).

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# ---------------------------------------------------------- locate Flutter SDK
if ! command -v flutter >/dev/null 2>&1; then
    echo "ERROR: 'flutter' not found on PATH" >&2
    exit 1
fi

FLUTTER_ROOT="$(flutter --version --machine 2>/dev/null \
    | python3 -c "import sys,json; print(json.load(sys.stdin)['flutterRoot'])")"

if [ -z "$FLUTTER_ROOT" ] || [ ! -d "$FLUTTER_ROOT" ]; then
    echo "ERROR: cannot resolve Flutter SDK root" >&2
    exit 1
fi

# ------------------------------------------------------------------ targets
MAC_DART="$FLUTTER_ROOT/packages/flutter_tools/lib/src/ios/mac.dart"
IOS_DART="$FLUTTER_ROOT/packages/flutter_tools/lib/src/build_system/targets/ios.dart"

MARKER_MAC='Local patch (2026-04-25): clear ALL xattrs'
MARKER_IOS='Local patch (2026-04-25): skip codesign entirely for iOS Simulator'

# Patches were authored against this Flutter commit. If Flutter has been
# upgraded past it, the patch may not apply cleanly.
EXPECTED_FLUTTER_HEAD="cc0734ac716"

# ---------------------------------------------------------- idempotency check
mac_applied="false"
ios_applied="false"
if grep -q "$MARKER_MAC" "$MAC_DART" 2>/dev/null; then mac_applied="true"; fi
if grep -q "$MARKER_IOS" "$IOS_DART" 2>/dev/null; then ios_applied="true"; fi

if [ "$mac_applied" = "true" ] && [ "$ios_applied" = "true" ]; then
    echo "Flutter SDK patches already applied (markers found in both files)."
    exit 0
fi

# ----------------------------------------------------------- version check
ACTUAL_HEAD="$(git -C "$FLUTTER_ROOT" rev-parse --short HEAD 2>/dev/null || echo "?")"
if [ "$ACTUAL_HEAD" != "${EXPECTED_FLUTTER_HEAD:0:${#ACTUAL_HEAD}}" ]; then
    echo "WARNING: Flutter HEAD is $ACTUAL_HEAD, patches were authored against $EXPECTED_FLUTTER_HEAD" >&2
    echo "         git apply --check below will reveal whether the patches still apply." >&2
fi

# ---------------------------------------------------------- apply each patch
apply_one() {
    local marker="$1"
    local target_file="$2"
    local patch_file="$3"

    if grep -q "$marker" "$target_file" 2>/dev/null; then
        echo "  [skip] $(basename "$patch_file") (already applied)"
        return 0
    fi

    if ! git -C "$FLUTTER_ROOT" apply --check "$patch_file" 2>&1; then
        echo "ERROR: patch $(basename "$patch_file") does not apply cleanly." >&2
        echo "       Flutter HEAD: $ACTUAL_HEAD" >&2
        echo "       Patch authored against: $EXPECTED_FLUTTER_HEAD" >&2
        echo "       Pin Flutter to the expected version, or update the patch." >&2
        return 1
    fi
    git -C "$FLUTTER_ROOT" apply "$patch_file"
    echo "  [ok]   $(basename "$patch_file")"
}

cd "$SCRIPT_DIR"
apply_one "$MARKER_MAC" "$MAC_DART" "$SCRIPT_DIR/0001-clear-all-xattrs.patch"
apply_one "$MARKER_IOS" "$IOS_DART" "$SCRIPT_DIR/0002-skip-codesign-on-simulator.patch"

# ---------------------------------------------------------- verify markers
if ! grep -q "$MARKER_MAC" "$MAC_DART"; then
    echo "ERROR: post-apply verification failed — marker missing in mac.dart" >&2
    exit 1
fi
if ! grep -q "$MARKER_IOS" "$IOS_DART"; then
    echo "ERROR: post-apply verification failed — marker missing in ios.dart" >&2
    exit 1
fi

# ---------------------------------------------------------- rebuild snapshot
rm -f "$FLUTTER_ROOT/bin/cache/flutter_tools.stamp" \
      "$FLUTTER_ROOT/bin/cache/flutter_tools.snapshot"
flutter --version >/dev/null 2>&1

echo "Flutter SDK patches applied + flutter_tools snapshot rebuilt."
exit 0
