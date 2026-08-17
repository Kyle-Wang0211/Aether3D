#!/usr/bin/env bash
set -euo pipefail

test_dir="$(cd "$(dirname "$0")" && pwd)"
repo_dir="$(cd "$test_dir/../../.." && pwd)"
core="$repo_dir/aether_cpp/official_pipeline/src/official_aether_sfm_c.cc"
matcher="$repo_dir/aether_cpp/official_pipeline/src/official_gpu_match.mm"
mapper="$repo_dir/aether_cpp/third_party/glomap_vendor/colmap-src/colmap/sfm/incremental_mapper.cc"
include_dir="$repo_dir/aether_cpp/include"
tmp_dir="$(mktemp -d /private/tmp/aether-speed-arms-v1.XXXXXX)"
trap 'rm -rf "$tmp_dir"' EXIT

require_literal() {
  local file="$1"
  local literal="$2"
  if ! rg -Fq -- "$literal" "$file"; then
    echo "FAIL missing contract literal in $file: $literal" >&2
    exit 1
  fi
}

# Descriptor residency must stay an explicit default-off sibling of the
# existing matcher and retain every lifecycle invalidation boundary.
require_literal "$matcher" 'OFFICIAL_AETHER_DESCRIPTOR_RESIDENCY_V1'
require_literal "$matcher" 'aether_gpu_match_gemm_pairs_resident'
require_literal "$matcher" 'ClearAllDescriptorResidencyForDeviceError();'
require_literal "$core" 'DescriptorResidencyEnabledCore()'
require_literal "$core" 'aether_gpu_match_descriptor_residency_invalidate('
require_literal "$core" 'aether_gpu_match_descriptor_residency_clear_session('

# Tail cache must retain the fresh route, an isolated shadow comparison, exact
# ordered bundle tracing, and fail-closed dirty epochs.
require_literal "$core" 'OFFICIAL_AETHER_TAIL_CACHE_V1'
require_literal "$core" 'cache = colmap::DatabaseCache::Create(*s->db, cache_options);'
require_literal "$core" 'std::make_shared<colmap::Reconstruction>(*s->live_recon)'
require_literal "$core" 'INVALID_TAIL_BUNDLE_SEQUENCE'
require_literal "$core" 'tail_match_candidates_v1'
require_literal "$core" 'match_candidate_ids'
require_literal "$core" 'TailCacheDirtyReasonV1::kRemoveFrame'
require_literal "$core" 'TailCacheDirtyReasonV1::kFinalizeMove'
require_literal "$core" 'TailCacheDirtyReasonV1::kModelReplacement'
require_literal "$core" 'TailCacheDirtyReasonV1::kLatePair'
require_literal "$core" 'TailCacheDirtyReasonV1::kExceptionRetry'
require_literal "$core" 'TailCacheDirtyReasonV1::kDeviceReset'
require_literal "$mapper" 'aether_ilr_bundle_trace_neighbors'
require_literal "$mapper" 'const std::vector<image_t> local_bundle = FindLocalBundle(options, image_id);'

xcrun clang++ -std=c++20 -Wall -Wextra -Werror -I"$include_dir" \
  "$repo_dir/aether_cpp/tests/sift/test_descriptor_residency_policy_v1.cpp" \
  -o "$tmp_dir/test_descriptor_residency_policy_v1"
"$tmp_dir/test_descriptor_residency_policy_v1"

xcrun clang++ -std=c++20 -Wall -Wextra -Werror -I"$include_dir" \
  "$repo_dir/aether_cpp/tests/sfm/test_tail_cache_epoch_v1.cpp" \
  -o "$tmp_dir/test_tail_cache_epoch_v1"
"$tmp_dir/test_tail_cache_epoch_v1"

bash "$test_dir/test_tail_cache_production_fault_contract.sh"

# The dynamic evidence validator is executed by the host replay gate because it
# needs a real injected-run JSONL and log. Its source must stay present here.
require_literal "$test_dir/test_tail_cache_fault_evidence_v1.sh" \
  'tail_cache_epoch_event_v1'

echo "PASS portable_speed_arms_v1_contract"
