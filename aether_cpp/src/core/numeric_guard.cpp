// SPDX-License-Identifier: LicenseRef-Aether3D-Proprietary
// Copyright (c) 2024-2026 Aether3D. All rights reserved.

#include "aether/core/numeric_guard.h"

#include <atomic>
#include <cmath>
#include <limits>

#if defined(__ARM_NEON)
#include <arm_neon.h>
#endif

namespace aether {
namespace core {
namespace {

struct GlobalCounters {
    std::atomic<std::uint64_t> nan_count{0};
    std::atomic<std::uint64_t> inf_count{0};
    std::atomic<std::uint64_t> guarded_scalar_count{0};
    std::atomic<std::uint64_t> guarded_vector_count{0};
};

struct ThreadLocalCounters {
    std::uint64_t nan_count{0};
    std::uint64_t inf_count{0};
    std::uint64_t guarded_scalar_count{0};
    std::uint64_t guarded_vector_count{0};
};

GlobalCounters& global_counters() {
    static GlobalCounters counters;
    return counters;
}

thread_local ThreadLocalCounters g_thread_local_counters{};

inline bool is_inf_float(float value) {
    return std::fabs(value) == std::numeric_limits<float>::infinity();
}

inline bool is_inf_double(double value) {
    return std::fabs(value) == std::numeric_limits<double>::infinity();
}

inline void record_non_finite(float value) {
    if (std::isnan(value)) {
        g_thread_local_counters.nan_count += 1u;
    } else if (is_inf_float(value)) {
        g_thread_local_counters.inf_count += 1u;
    }
}

inline void record_non_finite(double value) {
    if (std::isnan(value)) {
        g_thread_local_counters.nan_count += 1u;
    } else if (is_inf_double(value)) {
        g_thread_local_counters.inf_count += 1u;
    }
}

inline bool lane_has_bad(uint32x4_t mask) {
    const uint64x2_t packed = vreinterpretq_u64_u32(mask);
    return (vgetq_lane_u64(packed, 0) | vgetq_lane_u64(packed, 1)) != 0u;
}

bool guard_finite_vector_scalar(float* values, std::size_t count) {
    bool all_finite = true;
    for (std::size_t i = 0u; i < count; ++i) {
        const float value = values[i];
        if (!std::isfinite(value)) {
            record_non_finite(value);
            values[i] = 0.0f;
            all_finite = false;
        }
    }
    return all_finite;
}

bool all_finite_vector_scalar(const float* values, std::size_t count) {
    for (std::size_t i = 0u; i < count; ++i) {
        if (!std::isfinite(values[i])) {
            return false;
        }
    }
    return true;
}

}  // namespace

void reset_numerical_health_counters() {
    GlobalCounters& counters = global_counters();
    counters.nan_count.store(0u, std::memory_order_relaxed);
    counters.inf_count.store(0u, std::memory_order_relaxed);
    counters.guarded_scalar_count.store(0u, std::memory_order_relaxed);
    counters.guarded_vector_count.store(0u, std::memory_order_relaxed);
    g_thread_local_counters = ThreadLocalCounters{};
}

void commit_thread_local_numerical_counters() {
    GlobalCounters& counters = global_counters();
    counters.nan_count.fetch_add(g_thread_local_counters.nan_count, std::memory_order_relaxed);
    counters.inf_count.fetch_add(g_thread_local_counters.inf_count, std::memory_order_relaxed);
    counters.guarded_scalar_count.fetch_add(g_thread_local_counters.guarded_scalar_count, std::memory_order_relaxed);
    counters.guarded_vector_count.fetch_add(g_thread_local_counters.guarded_vector_count, std::memory_order_relaxed);
    g_thread_local_counters = ThreadLocalCounters{};
}

NumericalHealthSnapshot numerical_health_snapshot() {
    commit_thread_local_numerical_counters();
    GlobalCounters& counters = global_counters();
    NumericalHealthSnapshot snapshot{};
    snapshot.nan_count = counters.nan_count.load(std::memory_order_relaxed);
    snapshot.inf_count = counters.inf_count.load(std::memory_order_relaxed);
    snapshot.guarded_scalar_count = counters.guarded_scalar_count.load(std::memory_order_relaxed);
    snapshot.guarded_vector_count = counters.guarded_vector_count.load(std::memory_order_relaxed);
    return snapshot;
}

bool guard_finite_scalar(float* value) {
    if (value == nullptr) {
        return false;
    }
    const float in = *value;
    g_thread_local_counters.guarded_scalar_count += 1u;
    if (std::isfinite(in)) {
        return true;
    }
    record_non_finite(in);
    *value = 0.0f;
    return false;
}

bool guard_finite_scalar(double* value) {
    if (value == nullptr) {
        return false;
    }
    const double in = *value;
    g_thread_local_counters.guarded_scalar_count += 1u;
    if (std::isfinite(in)) {
        return true;
    }
    record_non_finite(in);
    *value = 0.0;
    return false;
}

bool guard_finite_vector(float* values, std::size_t count) {
    if (values == nullptr) {
        return false;
    }
    g_thread_local_counters.guarded_vector_count += count;

#if defined(__ARM_NEON)
    bool all_finite = true;
    const float32x4_t inf = vdupq_n_f32(std::numeric_limits<float>::infinity());
    std::size_t i = 0u;
    for (; i + 4u <= count; i += 4u) {
        float32x4_t v = vld1q_f32(values + i);
        const uint32x4_t nan_mask = vmvnq_u32(vceqq_f32(v, v));
        const uint32x4_t inf_mask = vceqq_f32(vabsq_f32(v), inf);
        const uint32x4_t bad_mask = vorrq_u32(nan_mask, inf_mask);
        if (lane_has_bad(bad_mask)) {
            all_finite = false;
            for (std::size_t lane = 0u; lane < 4u; ++lane) {
                float lane_value = values[i + lane];
                if (!std::isfinite(lane_value)) {
                    record_non_finite(lane_value);
                    values[i + lane] = 0.0f;
                }
            }
        }
    }
    if (i < count) {
        all_finite = guard_finite_vector_scalar(values + i, count - i) && all_finite;
    }
    return all_finite;
#else
    return guard_finite_vector_scalar(values, count);
#endif
}

bool guard_finite_vector(double* values, std::size_t count) {
    if (values == nullptr) {
        return false;
    }
    g_thread_local_counters.guarded_vector_count += count;
    bool all_finite = true;
    for (std::size_t i = 0u; i < count; ++i) {
        if (!std::isfinite(values[i])) {
            record_non_finite(values[i]);
            values[i] = 0.0;
            all_finite = false;
        }
    }
    return all_finite;
}

bool all_finite_vector(const float* values, std::size_t count) {
    if (values == nullptr) {
        return false;
    }
#if defined(__ARM_NEON)
    const float32x4_t inf = vdupq_n_f32(std::numeric_limits<float>::infinity());
    std::size_t i = 0u;
    for (; i + 4u <= count; i += 4u) {
        const float32x4_t v = vld1q_f32(values + i);
        const uint32x4_t nan_mask = vmvnq_u32(vceqq_f32(v, v));
        const uint32x4_t inf_mask = vceqq_f32(vabsq_f32(v), inf);
        if (lane_has_bad(vorrq_u32(nan_mask, inf_mask))) {
            return false;
        }
    }
    return all_finite_vector_scalar(values + i, count - i);
#else
    return all_finite_vector_scalar(values, count);
#endif
}

bool all_finite_vector(const double* values, std::size_t count) {
    if (values == nullptr) {
        return false;
    }
    for (std::size_t i = 0u; i < count; ++i) {
        if (!std::isfinite(values[i])) {
            return false;
        }
    }
    return true;
}

}  // namespace core
}  // namespace aether
