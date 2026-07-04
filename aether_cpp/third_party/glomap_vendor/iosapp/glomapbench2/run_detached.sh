#!/bin/bash
# run_detached.sh — UNPLUG-SAFE bench launch (standard template).
# Installs the app and launches it WITHOUT --console, so the app's lifetime is
# NOT tied to the USB tunnel: unplug mid-run and it keeps computing. All output
# lands in the app container (Documents/run.log, run_full.log, DONE) — collect
# with poll_result.sh. Usage:  ./run_detached.sh [device-udid]
set -e
DEV=${1:-1B290474-D354-5B4C-AAB0-0805AC5DC832}
BUNDLE=com.kyle.PocketWorld   # reuses main-app App ID (increased-memory-limit capability)
HERE="$(cd "$(dirname "$0")" && pwd)"
APP="$HERE/dd/Build/Products/Release-iphoneos/GlomapBench2.app"

echo "== install $APP"
xcrun devicectl device install app --device "$DEV" "$APP"

# --terminate-existing kills any previous instance (prevents double-run);
# NO --console → devicectl returns immediately, app runs standalone.
echo "== launch detached (survives USB unplug)"
xcrun devicectl device process launch --device "$DEV" --terminate-existing "$BUNDLE"
echo "== launched. Collect results with: ./poll_result.sh $DEV"
