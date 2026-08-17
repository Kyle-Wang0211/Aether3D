#!/bin/sh
set -eu

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
AETHER_CPP=$(CDPATH= cd -- "$SCRIPT_DIR/../.." && pwd)
EXTRACTOR="$AETHER_CPP/tools/sift_extract_dawn.cc"
GPU_OFFICIAL="$AETHER_CPP/official_pipeline/src/official_dsp_sift_gpu_c.cc"
GPU_BENCH="$AETHER_CPP/third_party/glomap_vendor/bench/dsp_sift_gpu_c.cc"
SESSION="$AETHER_CPP/official_pipeline/src/official_aether_sfm_c.cc"
VENDOR_CMAKE="$AETHER_CPP/third_party/glomap_vendor/CMakeLists.txt"
REPLAY_DRIVER="$AETHER_CPP/official_pipeline/src/official_preclamp_replay_driver_v1.cc"

require_text() {
  needle=$1
  file=$2
  /usr/bin/grep -F -q "$needle" "$file" || {
    echo "FAIL P1 source chain: missing '$needle' in $file" >&2
    exit 1
  }
}

/usr/bin/cmp -s "$GPU_OFFICIAL" "$GPU_BENCH" || {
  echo "FAIL P1 source chain: GPU entry copies differ" >&2
  exit 1
}

require_text 'UpdateLegacyClampResult(n_desc);' "$EXTRACTOR"
if /usr/bin/grep -F -q 'FinalizeAcceptedFrame' "$EXTRACTOR"; then
  echo "FAIL P1 source chain: extractor publishes a session row" >&2
  exit 1
fi
require_text 'ClearPendingAtGpuEntry();' "$GPU_OFFICIAL"
require_text 'kGpuFailureOrFallback' "$GPU_OFFICIAL"
require_text 'kCanonicalRoute' "$GPU_OFFICIAL"
require_text 'if (deterministic_selection_requested != deterministic_selection ||' "$GPU_OFFICIAL"
require_text 'selection_policy.policy != res.selection_policy)' "$GPU_OFFICIAL"
require_text 'if (!deterministic_selection_requested && !deterministic_selection)' "$GPU_OFFICIAL"
require_text 'SealAcceptedLegacyGpuResult(' "$GPU_OFFICIAL"
require_text 'static_cast<uint32_t>(res.count),' "$GPU_OFFICIAL"
if /usr/bin/awk '
  /SealAcceptedLegacyGpuResult\(/ { in_seal = 1 }
  in_seal { print }
  in_seal && /;/ { exit }
' "$GPU_OFFICIAL" | /usr/bin/grep -F -q 'static_cast<uint32_t>(emitted)'; then
  echo "FAIL P1 source chain: ABI-emitted count used as descriptor-stage rows" >&2
  exit 1
fi
require_text 'SessionRecords preclamp_instr_records;' "$SESSION"
require_text 'FinalizeAcceptedFrame(' "$SESSION"
require_text 'AppendSessionRecord(' "$SESSION"
require_text 'ResetSessionRecords(' "$SESSION"
require_text 's->frames.push_back(std::move(rec));' "$SESSION"
require_text 'official_preclamp_instr_v1.cc' "$VENDOR_CMAKE"
require_text 'official_preclamp_replay_driver_v1.cc' "$VENDOR_CMAKE"
require_text 'AETHER_PRECLAMP_INSTR_ENV_OFFICIAL=1' "$VENDOR_CMAKE"
require_text 'add_executable(preclamp_instr_v1_production_integration_exe' "$VENDOR_CMAKE"
require_text 'bench/preclamp_instr_v1_production_integration.cc' "$VENDOR_CMAKE"

# Phase-B replay stays count-only. These production subsystems are forbidden
# dependencies until the separately gated Phase-C/D work begins.
if /usr/bin/grep -E -q '#include.*(database|matcher|tvg|mapper|triang|bundle|ply)|aether_sift_match|WriteMatches|TwoViewGeometry' \
    "$REPLAY_DRIVER"; then
  echo "FAIL P1 source chain: Phase-B replay driver imports a downstream production subsystem" >&2
  exit 1
fi

[ "$(/usr/bin/grep -F -c 'ClearPendingAtGpuEntry();' "$GPU_OFFICIAL")" -eq 1 ]
[ "$(/usr/bin/grep -F -c 'SealAcceptedLegacyGpuResult(' "$GPU_OFFICIAL")" -eq 1 ]
[ "$(/usr/bin/grep -F -c 'FinalizeAcceptedFrame(' "$SESSION")" -eq 1 ]
[ "$(/usr/bin/grep -F -c 'AppendSessionRecord(' "$SESSION")" -eq 1 ]

push_line=$(/usr/bin/grep -n -F 's->frames.push_back(std::move(rec));' "$SESSION" | /usr/bin/head -1 | /usr/bin/cut -d: -f1)
publish_line=$(/usr/bin/grep -n -F 'FinalizeAcceptedFrame(' "$SESSION" | /usr/bin/head -1 | /usr/bin/cut -d: -f1)
[ "$push_line" -lt "$publish_line" ] || {
  echo "FAIL P1 source chain: publication precedes accepted frame insertion" >&2
  exit 1
}

echo "PASS production source lifecycle chain and byte-identical GPU entries"
