// SPDX-License-Identifier: LicenseRef-Aether3D-Proprietary
// Copyright (c) 2024-2026 Aether3D. All rights reserved.

#ifndef AETHER_COST_POLICY_POLICY_KERNEL_H
#define AETHER_COST_POLICY_POLICY_KERNEL_H

#include <array>
#include <cstdint>

namespace aether {
namespace cost_policy {

struct GcraState {
    int64_t theoretical_arrival_time_ms{0};
};

struct GcraDecision {
    bool allowed{false};
    int64_t next_allowed_at_ms{0};
    int64_t debt_ms{0};
};

// Deterministic GCRA limiter used by CostShield quota/rate policy.
inline GcraDecision evaluate_gcra(
    int64_t now_ms,
    int64_t token_interval_ms,
    int64_t burst_tolerance_ms,
    GcraState& state) {
    if (token_interval_ms <= 0) {
        return GcraDecision{false, now_ms, 0};
    }

    if (state.theoretical_arrival_time_ms == 0) {
        state.theoretical_arrival_time_ms = now_ms;
    }

    const int64_t allowed_at = state.theoretical_arrival_time_ms - burst_tolerance_ms;
    if (now_ms < allowed_at) {
        return GcraDecision{
            false,
            allowed_at,
            allowed_at - now_ms};
    }

    const int64_t base = now_ms > state.theoretical_arrival_time_ms
        ? now_ms
        : state.theoretical_arrival_time_ms;
    state.theoretical_arrival_time_ms = base + token_interval_ms;
    return GcraDecision{
        true,
        state.theoretical_arrival_time_ms - burst_tolerance_ms,
        0};
}

// Shadow pricing with integer math (ppm inputs, micros output).
inline int64_t compute_shadow_price_micros(
    int64_t base_price_micros,
    int32_t utilization_ppm,
    int32_t hotness_ppm) {
    if (base_price_micros < 0) {
        base_price_micros = 0;
    }

    const int64_t util = utilization_ppm < 0 ? 0 : static_cast<int64_t>(utilization_ppm);
    const int64_t hot = hotness_ppm < 0 ? 0 : static_cast<int64_t>(hotness_ppm);

    // multiplier_ppm = 1.0 + 0.6*util + 0.4*hot
    const int64_t multiplier_ppm =
        1000000LL +
        ((600000LL * util) / 1000000LL) +
        ((400000LL * hot) / 1000000LL);
    return (base_price_micros * multiplier_ppm) / 1000000LL;
}

// Stable idempotency key (128-bit) from deterministic fields.
inline std::array<uint64_t, 2> make_idempotency_key(
    uint64_t tenant_id,
    uint64_t op_kind,
    uint64_t request_counter,
    uint64_t payload_digest_hi,
    uint64_t payload_digest_lo) {
    auto mix64 = [](uint64_t x) -> uint64_t {
        x ^= x >> 30;
        x *= 0xbf58476d1ce4e5b9ULL;
        x ^= x >> 27;
        x *= 0x94d049bb133111ebULL;
        x ^= x >> 31;
        return x;
    };

    const uint64_t k0 = mix64(tenant_id ^ (op_kind << 17) ^ request_counter);
    const uint64_t k1 = mix64(payload_digest_hi ^ (payload_digest_lo << 1) ^ (request_counter << 7));
    return {k0, k1};
}

}  // namespace cost_policy
}  // namespace aether

#endif  // AETHER_COST_POLICY_POLICY_KERNEL_H
