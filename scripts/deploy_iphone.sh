#!/usr/bin/env bash
#
# Phase 5.2 — deploy pocketworld_flutter to a connected iPhone via Xcode-direct
# build path (NOT `flutter build ios`, which fails codesign on macOS 26.1).
#
# Workflow (worked 2026-04-26 to deploy on Kyle's iPhone iOS 26.3.1):
#
#   1. xcodebuild -workspace … -scheme Runner -configuration Release
#      -destination 'generic/platform=iOS' -allowProvisioningUpdates
#   2. Re-sign embedded frameworks with developer identity (xcodebuild's
#      deep-sign uses the team's distribution cert which the device rejects
#      as "identity no longer valid").
#   3. devicectl install + launch.
#
# See aether_cpp/PHASE_BACKLOG.md "Phase 5.2 iPhone real device deploy" for
# why `flutter build ios` doesn't work and why this workaround does.
#
# Prereqs:
#   - macOS 26.x, Xcode 26.x with iOS 26.x SDK
#   - Apple Development cert installed in Keychain
#   - Apple Developer team configured in Runner.xcodeproj (DEVELOPMENT_TEAM)
#   - Bundle ID provisioning registered (e.g. com.kyle.PocketWorld)
#   - iPhone connected (USB or wireless), trusted, and developer mode enabled
#
# Usage:
#   bash scripts/deploy_iphone.sh <iphone-udid> [Debug|Release]
#
# Defaults to Release because Debug requires Flutter tooling attached to
# create the FlutterEngine — standalone Debug launch crashes (signal 11)
# with "Cannot create a FlutterEngine instance in debug mode without
# Flutter tooling or Xcode."

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

DEVICE_UDID="${1:?usage: deploy_iphone.sh <iphone-udid> [Debug|Release]}"
CONFIG="${2:-Release}"

if [ "$CONFIG" != "Debug" ] && [ "$CONFIG" != "Release" ]; then
    echo "ERROR: configuration must be Debug or Release, got '$CONFIG'" >&2
    exit 1
fi

# ─── Find Apple Development signing identity ────────────────────────
IDENTITY=$(security find-identity -v -p codesigning \
    | grep "Apple Development" \
    | head -1 \
    | awk '{print $2}')

if [ -z "$IDENTITY" ]; then
    echo "ERROR: no 'Apple Development' identity in keychain" >&2
    echo "Run: security find-identity -v -p codesigning" >&2
    exit 1
fi

echo "==> Signing identity: $IDENTITY"

# ─── 1. Build via xcodebuild ────────────────────────────────────────
echo "==> Building (xcodebuild $CONFIG, generic iOS device)..."
cd pocketworld_flutter/ios
LANG=en_US.UTF-8 LC_ALL=en_US.UTF-8 xcodebuild \
    -workspace Runner.xcworkspace \
    -scheme Runner \
    -configuration "$CONFIG" \
    -destination 'generic/platform=iOS' \
    -allowProvisioningUpdates \
    > /tmp/deploy_iphone_xcodebuild.log 2>&1 \
    || { echo "ERROR: xcodebuild failed; see /tmp/deploy_iphone_xcodebuild.log"; exit 1; }
cd "$REPO_ROOT"

# ─── 2. Locate the .app, re-sign frameworks ─────────────────────────
APP=$(find ~/Library/Developer/Xcode/DerivedData/Runner-* \
    -path "*Build/Products/${CONFIG}-iphoneos/Runner.app" \
    -type d | head -1)

if [ -z "$APP" ] || [ ! -d "$APP" ]; then
    echo "ERROR: built Runner.app not found under DerivedData" >&2
    exit 1
fi

echo "==> .app at: $APP"

ENT_PATH=$(find ~/Library/Developer/Xcode/DerivedData/Runner-* \
    -path "*Intermediates.noindex/Runner.build/${CONFIG}-iphoneos/Runner.build/Runner.app.xcent" \
    | head -1)

if [ -z "$ENT_PATH" ]; then
    echo "ERROR: entitlements (.xcent) not found" >&2
    exit 1
fi

# Phase 5.2 diagnosis 3: macOS 26.1 file provider re-tags files under
# ~/Documents/ with com.apple.FinderInfo + fileprovider.fpfs#P
# continuously. codesign rejects FinderInfo, hence "resource fork ...
# detritus not allowed". xattr -d removes them, but the file provider
# re-tags within ms. Race-window: clear xattrs and codesign IN THE SAME
# shell invocation — codesign reads xattrs faster than the provider
# re-tags. xcodebuild's default DerivedData path (~/Library/...) is
# NOT file-provider-tracked, so the .app there is xattr-clean to begin
# with — but flutter build ios redirects to <project>/build/ios/, which
# IS in Documents tree. This script handles either build path.
clean_xattrs_then_sign() {
    local target="$1"; shift
    find "$target" -exec xattr -d com.apple.FinderInfo {} + 2>/dev/null || true
    find "$target" -exec xattr -d "com.apple.fileprovider.fpfs#P" {} + 2>/dev/null || true
    codesign --force --sign "$IDENTITY" "$@" "$target"
}

echo "==> Re-signing embedded frameworks..."
for FW in "$APP"/Frameworks/*; do
    [ -e "$FW" ] || continue
    echo "    sign $(basename "$FW")"
    clean_xattrs_then_sign "$FW" --timestamp=none
done

echo "==> Re-signing Runner.app top level..."
clean_xattrs_then_sign "$APP" --entitlements "$ENT_PATH" --timestamp=none

# ─── 3. Install + launch via devicectl ──────────────────────────────
echo "==> Installing on device $DEVICE_UDID..."
xcrun devicectl device install app --device "$DEVICE_UDID" "$APP"

echo "==> Launching com.kyle.PocketWorld..."
xcrun devicectl device process launch --device "$DEVICE_UDID" com.kyle.PocketWorld

echo "==> Done. App should now be on the device's home screen + launched."
echo "==> If Debug config, the app crashed (Flutter tooling needed); use Release."
