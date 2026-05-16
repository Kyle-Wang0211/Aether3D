#!/usr/bin/env bash
# pull_capture_frames.sh
#
# After user finishes dome capture in PocketWorld app, this helper:
#   1. Lists PocketWorld's app data container on iPhone 14 Pro
#   2. Finds recent capture frames (scan-pending-* / capture cache / etc.)
#   3. Pulls them to local /tmp/da3_d5_capture_frames/
#   4. Reports what it found
#
# Then user can run:
#   python da3_quality_check.py /tmp/da3_d5_capture_frames --max-frames 6
#
# Usage: ./pull_capture_frames.sh

set -e

DEVICE_ID="1B290474-D354-5B4C-AAB0-0805AC5DC832"
BUNDLE_ID="com.kyle.PocketWorld"
LOCAL_DIR="/tmp/da3_d5_capture_frames"

mkdir -p "$LOCAL_DIR"
rm -f "$LOCAL_DIR"/*.jpg "$LOCAL_DIR"/*.png "$LOCAL_DIR"/*.mp4 2>/dev/null || true

echo "=== Listing PocketWorld app sandbox ==="
xcrun devicectl device info files \
  --device "$DEVICE_ID" \
  --domain-type appDataContainer \
  --domain-identifier "$BUNDLE_ID" \
  --source / \
  --recursive 2>&1 | grep -iE "\.jpg|\.jpeg|\.png|\.mp4|scan-pending|capture|frame" | head -50

echo ""
echo "=== Searching for recent frames ==="
# Common PocketWorld paths to check
for SUBPATH in \
  "Library/Caches" \
  "tmp" \
  "Documents" \
  "Documents/aether_captures" \
  "Documents/captures" \
  "Library/Caches/captures" \
  "Library/Caches/upload_frames" \
  "Library/Application Support/captures"; do
  echo "--- $SUBPATH ---"
  xcrun devicectl device info files \
    --device "$DEVICE_ID" \
    --domain-type appDataContainer \
    --domain-identifier "$BUNDLE_ID" \
    --source "$SUBPATH" 2>/dev/null | head -20
done

echo ""
echo "=== Done listing. Use the paths above to manually copy frames: ==="
echo "  xcrun devicectl device copy from \\"
echo "    --device $DEVICE_ID \\"
echo "    --domain-type appDataContainer \\"
echo "    --domain-identifier $BUNDLE_ID \\"
echo "    --source <PATH_FROM_ABOVE> \\"
echo "    --destination $LOCAL_DIR/"
