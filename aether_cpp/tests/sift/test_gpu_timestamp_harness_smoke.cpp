// SPDX-License-Identifier: LicenseRef-Aether3D-Proprietary

#include "dawn_kernel_harness.h"
#include "official_gpu_timestamp_diagnostics_v1.h"

#include <cstdlib>
#include <cstring>
#include <iostream>
#include <vector>

namespace gti = aether::tools::gpu_timestamp_internal;

int main() {
    const bool requested = gti::process_env_requests_v1();
    const bool force_resource_scope_error =
        gti::env_value_requests_v1(std::getenv(
            "AETHER_GPU_TIMESTAMP_SELFTEST_FORCE_RESOURCE_SCOPE_ERROR"));
    const bool force_resolve_scope_error =
        gti::env_value_requests_v1(std::getenv(
            "AETHER_GPU_TIMESTAMP_SELFTEST_FORCE_RESOLVE_SCOPE_ERROR"));
    const bool force_capacity_overflow =
        gti::env_value_requests_v1(std::getenv(
            "AETHER_GPU_TIMESTAMP_SELFTEST_FORCE_CAPACITY_OVERFLOW"));
    aether::tools::DawnKernelHarness harness;
    const bool initialized = harness.init();

    AetherGpuTimestampProbeV1 probe{};
    probe.struct_size = sizeof(probe);
    const int probe_rc = aether_sed_gpu_timestamp_probe_v1(&probe);
    if (probe_rc != AETHER_GPU_TIMESTAMP_PULL_OK_V1) {
        std::cerr << "GPU_TIMESTAMP_HARNESS_SMOKE_FAIL probe_rc=" << probe_rc
                  << '\n';
        return 1;
    }
    if (std::strcmp(probe.selected_env_key,
                    gti::AETHER_GPU_TIMESTAMP_ENV_KEY_V1) != 0 ||
        std::strcmp(probe.dawn_version,
                    "git:12ee391c7411285895f4289a3d889a182c093014") != 0 ||
        std::strcmp(probe.dawn_build_hash,
                    "2a186006dfae77c8adadf8475e6ea6e283786a16a6f0010a9fc4c11316792c6d") != 0) {
        std::cerr << "GPU_TIMESTAMP_HARNESS_SMOKE_FAIL identity\n";
        return 1;
    }

    if (!requested) {
        if (!initialized ||
            probe.requested != 0 ||
            probe.capability !=
                AETHER_GPU_TIMESTAMP_CAPABILITY_NOT_PROBED_V1 ||
            probe.status != AETHER_GPU_TIMESTAMP_STATUS_OFF_V1 ||
            probe.ts_enabled != 0 ||
            harness.gpu_ts_enabled() ||
            harness.gpu_ts_feature_request_to_device() ||
            harness.gpu_ts_feature_granted()) {
            std::cerr << "GPU_TIMESTAMP_HARNESS_SMOKE_FAIL off-state\n";
            return 1;
        }
    } else if (probe.requested != 1 ||
               (probe.status != AETHER_GPU_TIMESTAMP_STATUS_ENABLED_V1 &&
                probe.status != AETHER_GPU_TIMESTAMP_STATUS_UNSUPPORTED_V1 &&
                probe.status !=
                    AETHER_GPU_TIMESTAMP_STATUS_RESOURCE_FAILED_V1)) {
        std::cerr << "GPU_TIMESTAMP_HARNESS_SMOKE_FAIL on-state\n";
        return 1;
    }
    if (force_resource_scope_error &&
        (probe.status != AETHER_GPU_TIMESTAMP_STATUS_RESOURCE_FAILED_V1 ||
         probe.ts_enabled != 0 || harness.gpu_ts_enabled())) {
        std::cerr
            << "GPU_TIMESTAMP_HARNESS_SMOKE_FAIL resource-error-injection"
            << " status=" << probe.status
            << " enabled=" << probe.ts_enabled
            << " harness_enabled=" << (harness.gpu_ts_enabled() ? 1 : 0)
            << '\n';
        return 1;
    }
    if (force_resource_scope_error &&
        (!harness.gpu_ts_feature_request_to_device() ||
         !harness.gpu_ts_feature_granted())) {
        std::cerr
            << "GPU_TIMESTAMP_HARNESS_SMOKE_FAIL resource-grant-state\n";
        return 1;
    }

    const auto probe_before_reinit = probe;
    if (harness.init()) {
        std::cerr << "GPU_TIMESTAMP_HARNESS_SMOKE_FAIL repeated-init\n";
        return 1;
    }
    AetherGpuTimestampProbeV1 probe_after_reinit{};
    probe_after_reinit.struct_size = sizeof(probe_after_reinit);
    if (aether_sed_gpu_timestamp_probe_v1(&probe_after_reinit) !=
            AETHER_GPU_TIMESTAMP_PULL_OK_V1 ||
        std::memcmp(&probe_before_reinit, &probe_after_reinit,
                    sizeof(probe_before_reinit)) != 0) {
        std::cerr << "GPU_TIMESTAMP_HARNESS_SMOKE_FAIL reinit-mutated-probe\n";
        return 1;
    }

    if (probe.status == AETHER_GPU_TIMESTAMP_STATUS_ENABLED_V1 &&
        (!harness.gpu_ts_feature_request_to_device() ||
         !harness.gpu_ts_feature_granted() ||
         std::strstr(probe.adapter_identity,
                     "timestamp_domain=webgpu_queue") == nullptr ||
         std::strstr(probe.adapter_identity,
                     "resolved_unit=nanoseconds") == nullptr ||
         std::strstr(probe.adapter_identity,
                     "disable_timestamp_query_conversion=forced_disabled") ==
             nullptr)) {
        std::cerr << "GPU_TIMESTAMP_HARNESS_SMOKE_FAIL timestamp-provenance\n";
        return 1;
    }

    if (initialized) {
        harness.gpu_ts_reset();
        AetherGpuTimestampFrameV1 frame{};
        frame.struct_size = sizeof(frame);
        const int frame_rc =
            aether_sed_last_gpu_timestamp_frame_v1(&frame);
        if (harness.gpu_ts_enabled()) {
            if (frame_rc != AETHER_GPU_TIMESTAMP_PULL_NOT_READY_V1) {
                std::cerr
                    << "GPU_TIMESTAMP_HARNESS_SMOKE_FAIL enabled-not-ready\n";
                return 1;
            }
            static constexpr char kTimestampSmokeWgsl[] = R"(
@group(0) @binding(0) var<storage, read_write> output: array<u32>;
@compute @workgroup_size(1)
fn main() {
  output[0] = output[0] + 1u;
}
)";
            const auto pipeline = harness.load_compute(kTimestampSmokeWgsl);
            const auto output = harness.alloc(
                sizeof(uint32_t),
                wgpu::BufferUsage::Storage | wgpu::BufferUsage::CopySrc);
            if (force_capacity_overflow) {
                harness.begin_batch();
                for (uint32_t i = 0;
                     i < AETHER_GPU_TIMESTAMP_RAW_PAIR_CAPACITY_V1 + 2u;
                     ++i) {
                    harness.dispatch_batched(pipeline, {output}, 1);
                }
                harness.end_batch();
                const uint32_t pass_count = harness.gpu_ts_pass_count();
                std::vector<uint64_t> pass_ns;
                const bool resolved = harness.gpu_ts_resolve(&pass_ns);
                AetherGpuTimestampFrameV1 failed{};
                failed.struct_size = sizeof(failed);
                if (pass_count !=
                        AETHER_GPU_TIMESTAMP_RAW_PAIR_CAPACITY_V1 ||
                    resolved ||
                    aether_sed_last_gpu_timestamp_frame_v1(&failed) !=
                        AETHER_GPU_TIMESTAMP_PULL_OK_V1 ||
                    failed.status !=
                        AETHER_GPU_TIMESTAMP_STATUS_RESOLVE_FAILED_V1 ||
                    failed.reason_code !=
                        AETHER_GPU_TIMESTAMP_REASON_SLOT_OVERFLOW_V1 ||
                    failed.drop_count !=
                        AETHER_GPU_TIMESTAMP_RAW_PAIR_CAPACITY_V1 + 2u) {
                    std::cerr
                        << "GPU_TIMESTAMP_HARNESS_SMOKE_FAIL "
                           "capacity-overflow-accounting\n";
                    return 1;
                }
                std::cout
                    << "GPU_TIMESTAMP_HARNESS_SMOKE_PASS requested=1"
                    << " capability=" << probe.capability
                    << " status=" << probe.status
                    << " enabled=" << probe.ts_enabled
                    << " initialized=1\n";
                return 0;
            }
            harness.dispatch(pipeline, {output}, 1);
            harness.dispatch(pipeline, {output}, 1);
            const uint32_t pass_count = harness.gpu_ts_pass_count();
            std::vector<uint64_t> pass_ns;
            const bool resolved = harness.gpu_ts_resolve(&pass_ns);
            if (force_resolve_scope_error) {
                AetherGpuTimestampFrameV1 failed{};
                failed.struct_size = sizeof(failed);
                if (resolved ||
                    aether_sed_last_gpu_timestamp_frame_v1(&failed) !=
                        AETHER_GPU_TIMESTAMP_PULL_OK_V1 ||
                    failed.status !=
                        AETHER_GPU_TIMESTAMP_STATUS_RESOLVE_FAILED_V1 ||
                    failed.valid != 0 ||
                    failed.drop_count != 2) {
                    std::cerr
                        << "GPU_TIMESTAMP_HARNESS_SMOKE_FAIL "
                           "resolve-error-injection\n";
                    return 1;
                }
                std::cout
                    << "GPU_TIMESTAMP_HARNESS_SMOKE_PASS requested=1"
                    << " capability=" << probe.capability
                    << " status=" << probe.status
                    << " enabled=" << probe.ts_enabled
                    << " initialized=1\n";
                return 0;
            }
            if (pass_count != 2 || !resolved ||
                pass_ns.size() != 2) {
                AetherGpuTimestampFrameV1 failed{};
                failed.struct_size = sizeof(failed);
                const int failed_rc =
                    aether_sed_last_gpu_timestamp_frame_v1(&failed);
                std::cerr
                    << "GPU_TIMESTAMP_HARNESS_SMOKE_FAIL enabled-resolve"
                    << " pass_count=" << pass_count
                    << " resolved=" << (resolved ? 1 : 0)
                    << " durations=" << pass_ns.size()
                    << " pull_rc=" << failed_rc
                    << " reason_code=" << failed.reason_code
                    << " reason=" << failed.reason << '\n';
                return 1;
            }
            uint32_t bounds[AETHER_GPU_TIMESTAMP_STAGE_CAPACITY_V1]{};
            for (uint32_t& boundary : bounds) {
                boundary = pass_count;
            }
            if (!harness.gpu_ts_finalize_frame(
                    bounds, AETHER_GPU_TIMESTAMP_STAGE_CAPACITY_V1)) {
                std::cerr
                    << "GPU_TIMESTAMP_HARNESS_SMOKE_FAIL enabled-finalize\n";
                return 1;
            }
            AetherGpuTimestampFrameV1 completed{};
            completed.struct_size = sizeof(completed);
            if (aether_sed_last_gpu_timestamp_frame_v1(&completed) !=
                    AETHER_GPU_TIMESTAMP_PULL_OK_V1 ||
                completed.valid != 1 ||
                completed.probe_instance_id != probe.probe_instance_id ||
                completed.extraction_ordinal != 1 ||
                completed.raw_pair_count != 2 ||
                completed.stage_count !=
                    AETHER_GPU_TIMESTAMP_STAGE_CAPACITY_V1 ||
                completed.raw_pairs[0].stage_index != 0 ||
                completed.raw_pairs[1].stage_index != 0 ||
                completed.stage_duration_ns[0] == 0) {
                std::cerr
                    << "GPU_TIMESTAMP_HARNESS_SMOKE_FAIL enabled-publish\n";
                return 1;
            }
            if (harness.gpu_ts_resolve(&pass_ns)) {
                std::cerr
                    << "GPU_TIMESTAMP_HARNESS_SMOKE_FAIL duplicate-resolve\n";
                return 1;
            }
            AetherGpuTimestampFrameV1 duplicate{};
            duplicate.struct_size = sizeof(duplicate);
            if (aether_sed_last_gpu_timestamp_frame_v1(&duplicate) !=
                    AETHER_GPU_TIMESTAMP_PULL_OK_V1 ||
                std::memcmp(&duplicate, &completed, sizeof(duplicate)) != 0) {
                std::cerr
                    << "GPU_TIMESTAMP_HARNESS_SMOKE_FAIL "
                       "duplicate-overwrote-accepted-frame\n";
                return 1;
            }
        } else if (frame_rc != AETHER_GPU_TIMESTAMP_PULL_OK_V1 ||
                   frame.probe_instance_id != probe.probe_instance_id ||
                   frame.extraction_ordinal != 1 ||
                   frame.status != probe.status ||
                   frame.valid != 0 ||
                   (frame.presence_flags &
                    (AETHER_GPU_TIMESTAMP_PRESENCE_PERIOD_V1 |
                     AETHER_GPU_TIMESTAMP_PRESENCE_DURATIONS_V1 |
                     AETHER_GPU_TIMESTAMP_PRESENCE_RAW_PAIRS_V1)) != 0) {
            std::cerr << "GPU_TIMESTAMP_HARNESS_SMOKE_FAIL invalid-frame\n";
            return 1;
        }
    } else if (probe.status !=
               AETHER_GPU_TIMESTAMP_STATUS_RESOURCE_FAILED_V1) {
        std::cerr << "GPU_TIMESTAMP_HARNESS_SMOKE_FAIL init-without-resource-"
                     "status\n";
        return 1;
    }

    std::cout << "GPU_TIMESTAMP_HARNESS_SMOKE_PASS requested="
              << probe.requested << " capability=" << probe.capability
              << " status=" << probe.status
              << " enabled=" << probe.ts_enabled
              << " initialized=" << (initialized ? 1 : 0) << '\n';
    return 0;
}
