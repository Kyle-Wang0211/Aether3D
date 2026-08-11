#include "pair_policy_v2_c.h"

#include <cstddef>
#include <cstdint>

namespace {

constexpr int32_t kMaxSpatialK = 64;
constexpr int32_t kMaxTemporalLookback = 8;
constexpr int32_t kMaxRecentExclusion = 64;
constexpr int32_t kMaxLoopPeriod = 1000;
constexpr int32_t kMaxLoopTopup = 64;
constexpr int32_t kMaxLoopRetrieveCap = 1024;
constexpr int32_t kMaxLoopRecentExclusion = 100000;

bool InClosedRange(const int32_t value, const int32_t low,
                   const int32_t high) {
  return value >= low && value <= high;
}

}  // namespace

extern "C" void aether_pair_policy_config_v2_default(
    aether_pair_policy_config_v2* out_config) {
  if (out_config == nullptr) return;
  *out_config = {};
  out_config->struct_size = sizeof(*out_config);
  out_config->version = AETHER_PAIR_POLICY_CONFIG_V2_VERSION;
  out_config->mode = AETHER_PAIR_POLICY_MODE_S20_T2_CANDIDATE;
  out_config->spatial_k = 20;
  out_config->temporal_lookback = 2;
  out_config->spatial_recent_exclusion = 2;
  // L4/P10 is part of the spatial-first product policy. Retrieval only proposes
  // candidates; the exact matcher and TVG still decide whether an edge exists.
  out_config->visual_loop_enabled = 1;
  // [LOOP-P5 2026-08-06] 与 VisualLoopIndexConfigV1::query_period 同步改 5。
  // ⚠️ 本字段纯声明性,当前无代码消费(v1.1 战役勘误);真开关在
  // visual_loop_index_v1.h。两处同改只为避免文档性漂移。
  out_config->visual_loop_period = 5;
  // [LOOP-TOP8 2026-08-06] 与 VisualLoopIndexConfigV1::topup 同步改 8(声明性字段)。
  out_config->visual_loop_topup = 8;
  out_config->visual_loop_retrieve_cap = 50;
  out_config->visual_loop_recent_exclusion = 20;
}

extern "C" int32_t aether_pair_policy_config_v2_validate(
    const aether_pair_policy_config_v2* config) {
  if (config == nullptr) return AETHER_PAIR_POLICY_V2_ERR_NULL;
  if (config->struct_size != sizeof(*config)) {
    return AETHER_PAIR_POLICY_V2_ERR_SIZE;
  }
  if (config->version != AETHER_PAIR_POLICY_CONFIG_V2_VERSION) {
    return AETHER_PAIR_POLICY_V2_ERR_VERSION;
  }
  if (config->mode != AETHER_PAIR_POLICY_MODE_SHIPPING_LEGACY &&
      config->mode != AETHER_PAIR_POLICY_MODE_S20_T2_SHADOW &&
      config->mode != AETHER_PAIR_POLICY_MODE_S20_T2_CANDIDATE) {
    return AETHER_PAIR_POLICY_V2_ERR_MODE;
  }
  if (!InClosedRange(config->spatial_k, 0, kMaxSpatialK) ||
      !InClosedRange(config->temporal_lookback, 0,
                     kMaxTemporalLookback) ||
      !InClosedRange(config->spatial_recent_exclusion, 0,
                     kMaxRecentExclusion) ||
      config->visual_loop_enabled > 1U ||
      !InClosedRange(config->visual_loop_period, 1, kMaxLoopPeriod) ||
      !InClosedRange(config->visual_loop_topup, 0, kMaxLoopTopup) ||
      !InClosedRange(config->visual_loop_retrieve_cap, 1,
                     kMaxLoopRetrieveCap) ||
      !InClosedRange(config->visual_loop_recent_exclusion, 0,
                     kMaxLoopRecentExclusion)) {
    return AETHER_PAIR_POLICY_V2_ERR_RANGE;
  }
  if (config->flags != 0U) return AETHER_PAIR_POLICY_V2_ERR_RESERVED;
  for (const uint32_t value : config->reserved) {
    if (value != 0U) return AETHER_PAIR_POLICY_V2_ERR_RESERVED;
  }
  return AETHER_PAIR_POLICY_V2_OK;
}

static_assert(sizeof(aether_pair_policy_config_v2) == 80U,
              "pair-policy v2 ABI layout changed");
static_assert(offsetof(aether_pair_policy_config_v2, reserved) == 48U,
              "pair-policy v2 ABI reserved offset changed");
