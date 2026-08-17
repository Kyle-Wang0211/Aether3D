#!/usr/bin/env bash
set -euo pipefail

if [[ $# -lt 4 || $# -gt 5 ]]; then
  echo "usage: $0 <sfm_match_fail.jsonl> <run.log> <trigger_after_frame> <last_frame> [dirty_reason]" >&2
  exit 64
fi

jsonl="$1"
run_log="$2"
trigger="$3"
last_frame="$4"
dirty_reason="${5:-remove_frame}"

command -v jq >/dev/null || {
  echo "FAIL jq is required for fail-closed JSONL validation" >&2
  exit 1
}
[[ -s "$jsonl" ]] || { echo "FAIL missing/nonempty JSONL: $jsonl" >&2; exit 1; }
[[ -s "$run_log" ]] || { echo "FAIL missing/nonempty run log: $run_log" >&2; exit 1; }
if [[ "$dirty_reason" == "remove_frame" ]]; then
  success_marker='TAIL_FAULT_REMOVE_OK'
else
  success_marker="TAIL_FAULT_INJECT_OK kind=$dirty_reason"
fi
rg -Fq "$success_marker" "$run_log" || {
  echo "FAIL fault injection did not attest success: $success_marker" >&2
  exit 1
}

jq -e -s --argjson trigger "$trigger" --argjson last "$last_frame" \
  --arg dirty_reason "$dirty_reason" '
  (to_entries) as $rows |
  [$rows[] | select(.value.type == "tail_cache_epoch_event_v1" and
                    .value.phase == "dirty_before_mutation" and
                    .value.dirty_reason == $dirty_reason)] as $dirty |
  [$rows[] | select(.value.type == "tail_cache_epoch_event_v1" and
                    .value.phase == "rebuild_complete")] as $rebuilt |
  [$rows[] | select(.value.type == "tail_shadow_compare_v1" and
                    .value.fid > $trigger and .value.fid <= $last)] as $post |
  ($dirty | length) == 1 and
  ($rebuilt | length) >= 1 and
  ($rebuilt | map(select(.key > $dirty[0].key)) | length) >= 1 and
  (($rebuilt | map(select(.key > $dirty[0].key))[0].value.generation) >
   $dirty[0].value.invalidated_generation) and
  (($rebuilt | map(select(.key > $dirty[0].key))[0].value.rebuild_parent_generation) ==
   $dirty[0].value.invalidated_generation) and
  ($post | length) == ($last - $trigger) and
  ([$post[] | select(.value.status != "EXACT" or
                     .value.fresh_calls <= 0 or
                     .value.mutable_calls <= 0)] | length) == 0 and
  ([.[] | select(.type == "tail_shadow_compare_v1" and
                 .status == "INVALID_TAIL_BUNDLE_SEQUENCE")] | length) == 0
' "$jsonl" >/dev/null || {
  echo "FAIL tail-cache fault/rebuild/exact evidence contract: $dirty_reason" >&2
  exit 1
}

echo "PASS tail_cache_fault_evidence_v1"
