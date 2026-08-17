#!/usr/bin/env bash
set -euo pipefail

test_dir="$(cd "$(dirname "$0")" && pwd)"
repo_dir="$(cd "$test_dir/../../.." && pwd)"
core="$repo_dir/aether_cpp/official_pipeline/src/official_aether_sfm_c.cc"
bench="$repo_dir/aether_cpp/third_party/glomap_vendor/bench/sfm_replay_bench.cc"
cmake="$repo_dir/aether_cpp/third_party/glomap_vendor/CMakeLists.txt"

require_literal() {
  local file="$1"
  local literal="$2"
  if ! rg -Fq -- "$literal" "$file"; then
    echo "FAIL tail-cache production fault contract missing: $literal" >&2
    exit 1
  fi
}

first_line_between() {
  local file="$1"
  local start="$2"
  local stop="$3"
  local needle="$4"
  awk -v start="$start" -v stop="$stop" -v needle="$needle" '
    index($0, start) { active = 1 }
    active && index($0, stop) && !index($0, start) { exit }
    active && index($0, needle) { print NR; exit }
  ' "$file"
}

assert_before() {
  local label="$1"
  local before="$2"
  local after="$3"
  if [[ -z "$before" || -z "$after" || "$before" -ge "$after" ]]; then
    echo "FAIL $label: before=$before after=$after" >&2
    exit 1
  fi
}

# The host gate must emit auditable epoch transitions and expose a bench-only
# public-ABI remove injection. Missing compare/event evidence must fail closed.
require_literal "$core" 'tail_cache_epoch_event_v1'
require_literal "$core" 'dirty_before_mutation'
require_literal "$core" 'rebuild_complete'
require_literal "$bench" '"--tail-fault-remove-frame"'
require_literal "$bench" '"--tail-fault-after-frame"'
require_literal "$bench" 'aether_sfm_remove_frame('
require_literal "$bench" 'TAIL_FAULT_REMOVE_OK'
require_literal "$core" 'AETHER_TAIL_CACHE_FAULT_TEST_HOOKS'
require_literal "$core" 'aether_sfm_test_tail_cache_inject_v1'
require_literal "$bench" '"--tail-fault-kind"'
require_literal "$bench" 'TAIL_FAULT_INJECT_OK'
require_literal "$bench" 'exception_retry'
require_literal "$core" 'kind == 4'
require_literal "$cmake" 'option(AETHER_TAIL_CACHE_FAULT_TEST_HOOKS'
require_literal "$cmake" 'if(AETHER_TAIL_CACHE_FAULT_TEST_HOOKS)'
require_literal "$cmake" 'AETHER_TAIL_CACHE_FAULT_TEST_HOOKS=1'

# Removal must invalidate the generation before the first DB mutation.
remove_dirty="$(first_line_between "$core" 'aether_sfm_result_t aether_sfm_remove_frame(' 'aether_sfm_result_t aether_sfm_finalize(' 'TailCacheMarkDirty')"
remove_mutation="$(first_line_between "$core" 'aether_sfm_result_t aether_sfm_remove_frame(' 'aether_sfm_result_t aether_sfm_finalize(' 'DeleteMatches')"
assert_before remove_dirty_before_db_mutation "$remove_dirty" "$remove_mutation"

# Model adoption must invalidate before replacing the authoritative model.
model_dirty="$(first_line_between "$core" 'bool AdoptAsyncPreviewRefinement(' 'bool MaybeStartAsyncPreviewBa(' 'TailCacheMarkDirty')"
model_mutation="$(first_line_between "$core" 'bool AdoptAsyncPreviewRefinement(' 'bool MaybeStartAsyncPreviewBa(' 's->live_recon = std::move(refined)')"
assert_before model_dirty_before_adoption "$model_dirty" "$model_mutation"

# Overwrite and late-pair classification must occur inside the same production
# first-write gate used by normal and repay/finalize pair writes.
require_literal "$core" 'TailCacheDirtyReasonV1::kPairOverwrite'
require_literal "$core" 'TailCacheDirtyReasonV1::kLatePair'
require_literal "$core" 'TailCacheBeginPairWrite(s, prev.image_id, image_id)'
require_literal "$core" 'TailCacheBeginPairWrite(s, img1, img2, /*late_write=*/true)'

# Exception-retry must be represented both in the host-only trigger and in the
# real production catch paths. Device reset is a passive teardown observation.
exception_calls="$(rg -F 'TailCacheDirtyReasonV1::kExceptionRetry' "$core" | wc -l | tr -d ' ')"
if [[ "$exception_calls" -lt 3 ]]; then
  echo "FAIL exception-retry production coverage: calls=$exception_calls" >&2
  exit 1
fi
require_literal "$core" 'TailCacheDirtyReasonV1::kDeviceReset'
require_literal "$core" 'void aether_sfm_free(aether_sfm_session_t* s)'

echo "PASS tail_cache_production_fault_contract"
