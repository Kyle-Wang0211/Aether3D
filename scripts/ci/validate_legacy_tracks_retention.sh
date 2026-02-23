#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
MANIFEST_PATH="$ROOT_DIR/governance/pipeline_tracks_manifest.json"

if [[ ! -f "$MANIFEST_PATH" ]]; then
  echo "legacy-track-retention: FAIL missing manifest at $MANIFEST_PATH"
  exit 1
fi

ROOT_DIR="$ROOT_DIR" MANIFEST_PATH="$MANIFEST_PATH" python3 - <<'PY'
import json
import os
import sys

root_dir = os.environ["ROOT_DIR"]
manifest_path = os.environ["MANIFEST_PATH"]

with open(manifest_path, "r", encoding="utf-8") as f:
    manifest = json.load(f)

tracks = manifest.get("tracks")
if not isinstance(tracks, list) or not tracks:
    print("legacy-track-retention: FAIL invalid or empty tracks")
    sys.exit(1)

errors = []
checked_paths = 0
for track in tracks:
    track_id = str(track.get("id", "<unknown>"))
    required_paths = track.get("required_paths", [])
    if not isinstance(required_paths, list) or not required_paths:
        errors.append(f"{track_id}: required_paths missing or empty")
        continue

    for rel_path in required_paths:
        checked_paths += 1
        abs_path = os.path.join(root_dir, rel_path)
        if not os.path.exists(abs_path):
            errors.append(f"{track_id}: missing {rel_path}")

if errors:
    print("legacy-track-retention: FAIL")
    for err in errors:
        print(f"  - {err}")
    sys.exit(1)

print(
    f"legacy-track-retention: PASS tracks={len(tracks)} required_paths={checked_paths}"
)
PY
