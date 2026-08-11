// SPDX-License-Identifier: LicenseRef-Aether3D-Proprietary
// Copyright (c) 2024-2026 Aether3D. All rights reserved.

#ifndef AETHER_CPP_OFFICIAL_PIPELINE_SRC_OFFICIAL_GPU_TIMESTAMP_DIAGNOSTICS_V1_H
#define AETHER_CPP_OFFICIAL_PIPELINE_SRC_OFFICIAL_GPU_TIMESTAMP_DIAGNOSTICS_V1_H

#include <stddef.h>
#include <stdint.h>

// This private header is compiled into the static extractor archive only. It is
// deliberately absent from aether_sfm_c.h and the framework export surface.
#ifndef AETHER_GPU_TIMESTAMP_INTERNAL
#if defined(__GNUC__) || defined(__clang__)
#define AETHER_GPU_TIMESTAMP_INTERNAL __attribute__((visibility("hidden")))
#else
#define AETHER_GPU_TIMESTAMP_INTERNAL
#endif
#define AETHER_GPU_TIMESTAMP_INTERNAL_WAS_DEFAULTED_V1 1
#endif

// CPU-only targets link official_gpu_timestamp_weak_stubs_v1.cc, whose weak
// NOT_READY definitions are covered by an executable absence-link contract.
// A consumer that has its own platform linker policy may additionally override
// these declaration attributes. The harness definition includes the header
// without an override and therefore remains a strong hidden definition.
#ifndef AETHER_GPU_TIMESTAMP_WEAK_IMPORT
#define AETHER_GPU_TIMESTAMP_WEAK_IMPORT
#define AETHER_GPU_TIMESTAMP_WEAK_IMPORT_WAS_DEFAULTED_V1 1
#endif

#if defined(AETHER_GPU_TIMESTAMPS_ENV_OFFICIAL) && \
    defined(AETHER_GPU_TIMESTAMPS_ENV_SELFTEST)
#error "GPU timestamp env namespace is ambiguous: define exactly one selector"
#elif !defined(AETHER_GPU_TIMESTAMPS_ENV_OFFICIAL) && \
      !defined(AETHER_GPU_TIMESTAMPS_ENV_SELFTEST)
#error "GPU timestamp env namespace is absent: define exactly one selector"
#endif

#define AETHER_GPU_TIMESTAMP_SCHEMA_VERSION_V1 1u
#define AETHER_GPU_TIMESTAMP_STAGE_CAPACITY_V1 9u
#define AETHER_GPU_TIMESTAMP_RAW_PAIR_CAPACITY_V1 512u
#define AETHER_GPU_TIMESTAMP_REASON_CAPACITY_V1 128u
#define AETHER_GPU_TIMESTAMP_ENV_KEY_CAPACITY_V1 64u
#define AETHER_GPU_TIMESTAMP_ADAPTER_CAPACITY_V1 160u
#define AETHER_GPU_TIMESTAMP_DAWN_VERSION_CAPACITY_V1 64u
#define AETHER_GPU_TIMESTAMP_DAWN_HASH_CAPACITY_V1 65u

#if defined(AETHER_GPU_TIMESTAMPS_ENV_OFFICIAL)
#define AETHER_GPU_TIMESTAMP_ENV_KEY_LITERAL_V1 \
    "OFFICIAL_AETHER_GPU_TIMESTAMPS"
#else
#define AETHER_GPU_TIMESTAMP_ENV_KEY_LITERAL_V1 "AETHER_GPU_TIMESTAMPS"
#endif

typedef enum AetherGpuTimestampStatusV1 {
    AETHER_GPU_TIMESTAMP_STATUS_OFF_V1 = 0,
    AETHER_GPU_TIMESTAMP_STATUS_ENABLED_V1 = 1,
    AETHER_GPU_TIMESTAMP_STATUS_UNSUPPORTED_V1 = 2,
    AETHER_GPU_TIMESTAMP_STATUS_RESOURCE_FAILED_V1 = 3,
    AETHER_GPU_TIMESTAMP_STATUS_RESOLVE_FAILED_V1 = 4
} AetherGpuTimestampStatusV1;

typedef enum AetherGpuTimestampCapabilityV1 {
    AETHER_GPU_TIMESTAMP_CAPABILITY_NOT_PROBED_V1 = 0,
    AETHER_GPU_TIMESTAMP_CAPABILITY_SUPPORTED_V1 = 1,
    AETHER_GPU_TIMESTAMP_CAPABILITY_UNSUPPORTED_V1 = 2,
    AETHER_GPU_TIMESTAMP_CAPABILITY_PROBE_ERROR_V1 = 3
} AetherGpuTimestampCapabilityV1;

typedef enum AetherGpuTimestampStageV1 {
    AETHER_GPU_TIMESTAMP_STAGE_PYRAMID_V1 = 0,
    AETHER_GPU_TIMESTAMP_STAGE_PACK_V1 = 1,
    AETHER_GPU_TIMESTAMP_STAGE_DETECT_V1 = 2,
    AETHER_GPU_TIMESTAMP_STAGE_SUPPRESS_V1 = 3,
    AETHER_GPU_TIMESTAMP_STAGE_AFFINE_V1 = 4,
    AETHER_GPU_TIMESTAMP_STAGE_ORIENT_V1 = 5,
    AETHER_GPU_TIMESTAMP_STAGE_CLAMP_V1 = 6,
    AETHER_GPU_TIMESTAMP_STAGE_DESCRIPTOR_V1 = 7,
    AETHER_GPU_TIMESTAMP_STAGE_DESC_RB_V1 = 8
} AetherGpuTimestampStageV1;

typedef enum AetherGpuTimestampPullResultV1 {
    AETHER_GPU_TIMESTAMP_PULL_OK_V1 = 0,
    AETHER_GPU_TIMESTAMP_PULL_INVALID_ARGUMENT_V1 = 1,
    AETHER_GPU_TIMESTAMP_PULL_NOT_READY_V1 = 2,
    AETHER_GPU_TIMESTAMP_PULL_SIZE_MISMATCH_V1 = 3,
    AETHER_GPU_TIMESTAMP_PULL_SNAPSHOT_INCONSISTENT_V1 = 4
} AetherGpuTimestampPullResultV1;

typedef enum AetherGpuTimestampPresenceV1 {
    AETHER_GPU_TIMESTAMP_PRESENCE_PERIOD_V1 = 1u << 0,
    AETHER_GPU_TIMESTAMP_PRESENCE_DURATIONS_V1 = 1u << 1,
    AETHER_GPU_TIMESTAMP_PRESENCE_RAW_PAIRS_V1 = 1u << 2,
    AETHER_GPU_TIMESTAMP_PRESENCE_PROBE_REF_V1 = 1u << 3
} AetherGpuTimestampPresenceV1;

typedef enum AetherGpuTimestampReasonV1 {
    AETHER_GPU_TIMESTAMP_REASON_NONE_V1 = 0,
    AETHER_GPU_TIMESTAMP_REASON_NOT_REQUESTED_V1 = 1,
    AETHER_GPU_TIMESTAMP_REASON_ADAPTER_UNSUPPORTED_V1 = 2,
    AETHER_GPU_TIMESTAMP_REASON_INSTANCE_FAILED_V1 = 3,
    AETHER_GPU_TIMESTAMP_REASON_ADAPTER_FAILED_V1 = 4,
    AETHER_GPU_TIMESTAMP_REASON_DEVICE_FAILED_V1 = 5,
    AETHER_GPU_TIMESTAMP_REASON_QUERY_SET_FAILED_V1 = 6,
    AETHER_GPU_TIMESTAMP_REASON_RESOLVE_BUFFER_FAILED_V1 = 7,
    AETHER_GPU_TIMESTAMP_REASON_READBACK_BUFFER_FAILED_V1 = 8,
    AETHER_GPU_TIMESTAMP_REASON_NO_RECORDED_PAIRS_V1 = 9,
    AETHER_GPU_TIMESTAMP_REASON_MAP_FAILED_V1 = 10,
    AETHER_GPU_TIMESTAMP_REASON_RANGE_FAILED_V1 = 11,
    AETHER_GPU_TIMESTAMP_REASON_NONMONOTONIC_PAIR_V1 = 12,
    AETHER_GPU_TIMESTAMP_REASON_SLOT_OVERFLOW_V1 = 13,
    AETHER_GPU_TIMESTAMP_REASON_PROVENANCE_FAILED_V1 = 14
} AetherGpuTimestampReasonV1;

typedef struct AetherGpuTimestampRawPairV1 {
    uint64_t begin_tick;
    uint64_t end_tick;
    uint32_t stage_index;
    uint32_t reserved;
} AetherGpuTimestampRawPairV1;

typedef struct AetherGpuTimestampProbeV1 {
    uint32_t struct_size;
    uint32_t schema_version;
    uint32_t presence_flags;
    uint32_t requested;
    uint64_t probe_instance_id;
    uint32_t capability;
    uint32_t status;
    uint32_t ts_enabled;
    uint32_t reason_code;
    uint32_t query_capacity;
    uint32_t reserved0;
    uint64_t timestamp_period_ns;
    char selected_env_key[AETHER_GPU_TIMESTAMP_ENV_KEY_CAPACITY_V1];
    char reason[AETHER_GPU_TIMESTAMP_REASON_CAPACITY_V1];
    char adapter_identity[AETHER_GPU_TIMESTAMP_ADAPTER_CAPACITY_V1];
    char dawn_version[AETHER_GPU_TIMESTAMP_DAWN_VERSION_CAPACITY_V1];
    char dawn_build_hash[AETHER_GPU_TIMESTAMP_DAWN_HASH_CAPACITY_V1];
} AetherGpuTimestampProbeV1;

typedef struct AetherGpuTimestampFrameV1 {
    uint32_t struct_size;
    uint32_t schema_version;
    uint32_t presence_flags;
    uint32_t status;
    uint64_t probe_instance_id;
    uint64_t extraction_ordinal;
    uint32_t valid;
    uint32_t reason_code;
    uint32_t stage_count;
    uint32_t raw_pair_count;
    uint32_t resolve_attempt_count;
    uint32_t resolve_success_count;
    uint32_t drop_count;
    uint32_t reserved0;
    uint64_t timestamp_period_ns;
    uint64_t stage_duration_ns[AETHER_GPU_TIMESTAMP_STAGE_CAPACITY_V1];
    AetherGpuTimestampRawPairV1
        raw_pairs[AETHER_GPU_TIMESTAMP_RAW_PAIR_CAPACITY_V1];
    char reason[AETHER_GPU_TIMESTAMP_REASON_CAPACITY_V1];
} AetherGpuTimestampFrameV1;

#ifdef __cplusplus
extern "C" {
#endif

AETHER_GPU_TIMESTAMP_INTERNAL AETHER_GPU_TIMESTAMP_WEAK_IMPORT int
aether_sed_gpu_timestamp_probe_v1(
    AetherGpuTimestampProbeV1* out_probe);
AETHER_GPU_TIMESTAMP_INTERNAL AETHER_GPU_TIMESTAMP_WEAK_IMPORT int
aether_sed_last_gpu_timestamp_frame_v1(
    AetherGpuTimestampFrameV1* out_frame);
AETHER_GPU_TIMESTAMP_INTERNAL AETHER_GPU_TIMESTAMP_WEAK_IMPORT int
aether_dsp_sift_take_last_gpu_timestamp_frame_v1(
    AetherGpuTimestampFrameV1* out_frame);

#ifdef __cplusplus
}  // extern "C"

#include <cstdlib>
#include <type_traits>

namespace aether::tools::gpu_timestamp_internal {

inline constexpr char AETHER_GPU_TIMESTAMP_ENV_KEY_V1[] =
    AETHER_GPU_TIMESTAMP_ENV_KEY_LITERAL_V1;

inline bool env_value_requests_v1(const char* value) noexcept {
    return value != nullptr && value[0] == '1' && value[1] == '\0';
}

inline bool process_env_requests_v1() noexcept {
    return env_value_requests_v1(std::getenv(AETHER_GPU_TIMESTAMP_ENV_KEY_V1));
}

struct InitialStateInputV1 {
    bool requested;
    bool adapter_probe_completed;
    bool adapter_supported;
    bool resource_initialization_succeeded;
};

struct StateDecisionV1 {
    uint32_t capability;
    uint32_t status;
    uint32_t enabled;
};

constexpr StateDecisionV1 classify_initial_state_v1(
    InitialStateInputV1 input) noexcept {
    if (!input.requested) {
        return {AETHER_GPU_TIMESTAMP_CAPABILITY_NOT_PROBED_V1,
                AETHER_GPU_TIMESTAMP_STATUS_OFF_V1, 0u};
    }
    if (!input.adapter_probe_completed) {
        return {AETHER_GPU_TIMESTAMP_CAPABILITY_PROBE_ERROR_V1,
                AETHER_GPU_TIMESTAMP_STATUS_RESOURCE_FAILED_V1, 0u};
    }
    if (!input.adapter_supported) {
        return {AETHER_GPU_TIMESTAMP_CAPABILITY_UNSUPPORTED_V1,
                AETHER_GPU_TIMESTAMP_STATUS_UNSUPPORTED_V1, 0u};
    }
    if (!input.resource_initialization_succeeded) {
        return {AETHER_GPU_TIMESTAMP_CAPABILITY_SUPPORTED_V1,
                AETHER_GPU_TIMESTAMP_STATUS_RESOURCE_FAILED_V1, 0u};
    }
    return {AETHER_GPU_TIMESTAMP_CAPABILITY_SUPPORTED_V1,
            AETHER_GPU_TIMESTAMP_STATUS_ENABLED_V1, 1u};
}

constexpr uint32_t classify_frame_status_v1(uint32_t initial_status,
                                             bool resolve_valid) noexcept {
    return initial_status == AETHER_GPU_TIMESTAMP_STATUS_ENABLED_V1 &&
                   !resolve_valid
               ? AETHER_GPU_TIMESTAMP_STATUS_RESOLVE_FAILED_V1
               : initial_status;
}

struct ResolveAttemptDecisionV1 {
    uint32_t attempt_count;
    bool encode_allowed;
};

constexpr ResolveAttemptDecisionV1 begin_resolve_attempt_v1(
    uint32_t previous_attempt_count) noexcept {
    return {previous_attempt_count + 1u, previous_attempt_count == 0u};
}

struct ScopedOperationDecisionV1 {
    bool accepted;
};

constexpr ScopedOperationDecisionV1 classify_scoped_resource_result_v1(
    bool handle_nonnull,
    bool pop_status_success,
    bool scopes_clean) noexcept {
    return {handle_nonnull && pop_status_success && scopes_clean};
}

constexpr ScopedOperationDecisionV1 classify_resolve_completion_v1(
    bool queue_success,
    bool scopes_clean) noexcept {
    return {queue_success && scopes_clean};
}

constexpr uint32_t increment_drop_count_v1(uint32_t previous) noexcept {
    return previous == UINT32_MAX ? UINT32_MAX : previous + 1u;
}

constexpr uint32_t add_drop_count_v1(uint32_t previous,
                                     uint32_t additional) noexcept {
    return additional > UINT32_MAX - previous ? UINT32_MAX
                                               : previous + additional;
}

bool publish_probe_v1(const AetherGpuTimestampProbeV1& probe) noexcept;
bool publish_frame_v1(const AetherGpuTimestampFrameV1& frame) noexcept;
bool mark_frame_not_ready_v1(uint64_t expected_probe_instance_id) noexcept;
void clear_caller_thread_frame_v1() noexcept;
bool stash_current_frame_for_caller_thread_v1(
    uint64_t expected_probe_instance_id,
    uint64_t expected_extraction_ordinal) noexcept;
int take_caller_thread_frame_v1(
    AetherGpuTimestampFrameV1* out_frame) noexcept;
bool finalize_frame_v1(AetherGpuTimestampFrameV1* frame,
                       uint64_t expected_probe_instance_id,
                       uint64_t expected_extraction_ordinal,
                       const uint32_t* cumulative_pass_counts,
                       uint32_t stage_count) noexcept;
void reset_snapshots_for_test_v1() noexcept;

static_assert(std::is_standard_layout_v<AetherGpuTimestampRawPairV1>);
static_assert(std::is_trivially_copyable_v<AetherGpuTimestampRawPairV1>);
static_assert(std::is_standard_layout_v<AetherGpuTimestampProbeV1>);
static_assert(std::is_trivially_copyable_v<AetherGpuTimestampProbeV1>);
static_assert(std::is_standard_layout_v<AetherGpuTimestampFrameV1>);
static_assert(std::is_trivially_copyable_v<AetherGpuTimestampFrameV1>);

}  // namespace aether::tools::gpu_timestamp_internal
#endif  // __cplusplus

#undef AETHER_GPU_TIMESTAMP_ENV_KEY_LITERAL_V1
#if defined(AETHER_GPU_TIMESTAMP_WEAK_IMPORT_WAS_DEFAULTED_V1)
#undef AETHER_GPU_TIMESTAMP_WEAK_IMPORT_WAS_DEFAULTED_V1
#undef AETHER_GPU_TIMESTAMP_WEAK_IMPORT
#endif
#if defined(AETHER_GPU_TIMESTAMP_INTERNAL_WAS_DEFAULTED_V1)
#undef AETHER_GPU_TIMESTAMP_INTERNAL_WAS_DEFAULTED_V1
#undef AETHER_GPU_TIMESTAMP_INTERNAL
#endif

#endif  // AETHER_CPP_OFFICIAL_PIPELINE_SRC_OFFICIAL_GPU_TIMESTAMP_DIAGNOSTICS_V1_H
