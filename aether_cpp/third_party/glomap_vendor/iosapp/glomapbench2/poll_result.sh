#!/bin/bash
# poll_result.sh — UNPLUG-SAFE result collection (standard template).
# Polls the app container for Documents/DONE via `devicectl copy from`. While the
# cable is unplugged the copy fails — we silently retry; the bench keeps running
# on-device regardless. On DONE: prints the RESULT line, pulls run.log +
# run_full.log, and exports the written colmap model (Documents/glomap_out).
# Usage:  ./poll_result.sh [device-udid] [poll-interval-s] [out-dir]
DEV=${1:-1B290474-D354-5B4C-AAB0-0805AC5DC832}
INTERVAL=${2:-30}
OUT=${3:-/tmp/glomap_device_result}
BUNDLE=com.kyle.PocketWorld
mkdir -p "$OUT"

cp_from() {  # cp_from <container-rel-src> <dst>
  xcrun devicectl device copy from --device "$DEV" \
    --domain-type appDataContainer --domain-identifier "$BUNDLE" \
    --source "$1" --destination "$2" >/dev/null 2>&1
}

echo "== polling Documents/DONE every ${INTERVAL}s (unplug-safe: failures retried)"
while true; do
  rm -f "$OUT/DONE"
  if cp_from Documents/DONE "$OUT/DONE" && [ -s "$OUT/DONE" ]; then
    echo "== DONE found:"; cat "$OUT/DONE"; break
  fi
  # progress peek (best-effort, ok to fail while unplugged)
  if cp_from Documents/run.log "$OUT/run.log"; then
    tail -1 "$OUT/run.log" 2>/dev/null
  fi
  sleep "$INTERVAL"
done

echo "== pulling logs + model"
cp_from Documents/run.log      "$OUT/run.log"
cp_from Documents/run_full.log "$OUT/run_full.log"
xcrun devicectl device copy from --device "$DEV" \
  --domain-type appDataContainer --domain-identifier "$BUNDLE" \
  --source Documents/glomap_out --destination "$OUT/glomap_out" 2>/dev/null || \
  echo "(model export failed or absent — retry manually)"
echo "== all in $OUT"
