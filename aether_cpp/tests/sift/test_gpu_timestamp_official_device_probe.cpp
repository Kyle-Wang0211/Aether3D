// SPDX-License-Identifier: LicenseRef-Aether3D-Proprietary

#include "dawn_kernel_harness.h"
#include "official_gpu_timestamp_diagnostics_v1.h"

#include <cstdint>
#include <cstdlib>
#include <cstring>
#include <fstream>
#include <iostream>
#include <sstream>
#include <string>
#include <vector>

namespace gti = aether::tools::gpu_timestamp_internal;

namespace {

std::string json_escape(const char* value) {
    std::ostringstream out;
    for (const unsigned char c :
         std::string(value == nullptr ? "" : value)) {
        switch (c) {
            case '"':
                out << "\\\"";
                break;
            case '\\':
                out << "\\\\";
                break;
            case '\b':
                out << "\\b";
                break;
            case '\f':
                out << "\\f";
                break;
            case '\n':
                out << "\\n";
                break;
            case '\r':
                out << "\\r";
                break;
            case '\t':
                out << "\\t";
                break;
            default:
                if (c < 0x20) {
                    static constexpr char kHex[] = "0123456789abcdef";
                    out << "\\u00" << kHex[(c >> 4) & 0xf] << kHex[c & 0xf];
                } else {
                    out << static_cast<char>(c);
                }
        }
    }
    return out.str();
}

std::string make_report(const AetherGpuTimestampProbeV1& probe,
                        const AetherGpuTimestampFrameV1& frame,
                        int frame_pull_rc,
                        bool initialized,
                        bool feature_request_to_device,
                        bool feature_granted,
                        uint32_t warmup_discarded_pair_count,
                        const char* verdict) {
    uint32_t zero_pairs = 0;
    uint32_t nonmonotonic_pairs = 0;
    if (frame_pull_rc == AETHER_GPU_TIMESTAMP_PULL_OK_V1) {
        for (uint32_t i = 0; i < frame.raw_pair_count; ++i) {
            if (frame.raw_pairs[i].begin_tick == 0 ||
                frame.raw_pairs[i].end_tick == 0) {
                ++zero_pairs;
            }
            if (frame.raw_pairs[i].end_tick <=
                frame.raw_pairs[i].begin_tick) {
                ++nonmonotonic_pairs;
            }
        }
    }

    const bool adapter_feature_advertised =
        probe.capability == AETHER_GPU_TIMESTAMP_CAPABILITY_SUPPORTED_V1;

    std::ostringstream out;
    out << "{"
        << "\"artifact\":\"AETHER_GPU_TIMESTAMP_DEVICE_PROBE_V1\","
        << "\"evidence_scope\":\"P2_MECHANICS_ONLY\","
        << "\"verdict\":\"" << verdict << "\","
        << "\"schema_version\":" << probe.schema_version << ","
        << "\"initialized\":" << (initialized ? "true" : "false") << ","
        << "\"requested_by_launch_env\":"
        << (probe.requested != 0 ? "true" : "false") << ","
        << "\"selected_env_key\":\""
        << json_escape(probe.selected_env_key) << "\","
        << "\"adapter_feature_advertised\":"
        << (adapter_feature_advertised ? "true" : "false") << ","
        << "\"feature_request_to_device\":"
        << (feature_request_to_device ? "true" : "false") << ","
        << "\"device_feature_granted\":"
        << (feature_granted ? "true" : "false") << ","
        << "\"capability\":" << probe.capability << ","
        << "\"timestamp_status\":" << probe.status << ","
        << "\"timestamp_enabled\":" << probe.ts_enabled << ","
        << "\"reason_code\":" << probe.reason_code << ","
        << "\"reason\":\"" << json_escape(probe.reason) << "\","
        << "\"adapter_identity\":\""
        << json_escape(probe.adapter_identity) << "\","
        << "\"dawn_version\":\"" << json_escape(probe.dawn_version)
        << "\","
        << "\"dawn_build_hash\":\""
        << json_escape(probe.dawn_build_hash) << "\","
        << "\"query_capacity\":" << probe.query_capacity << ","
        << "\"warmup_discarded_pair_count\":"
        << warmup_discarded_pair_count << ","
        << "\"probe_timestamp_period_ns\":"
        << probe.timestamp_period_ns << ","
        << "\"frame_pull_rc\":" << frame_pull_rc << ","
        << "\"frame_status\":" << frame.status << ","
        << "\"frame_reason_code\":" << frame.reason_code << ","
        << "\"frame_reason\":\"" << json_escape(frame.reason) << "\","
        << "\"frame_valid\":" << frame.valid << ","
        << "\"frame_timestamp_period_ns\":"
        << frame.timestamp_period_ns << ","
        << "\"raw_pair_count\":" << frame.raw_pair_count << ","
        << "\"zero_pair_count\":" << zero_pairs << ","
        << "\"nonmonotonic_pair_count\":" << nonmonotonic_pairs << ","
        << "\"drop_count\":" << frame.drop_count << ","
        << "\"resolve_attempt_count\":" << frame.resolve_attempt_count
        << ","
        << "\"resolve_success_count\":" << frame.resolve_success_count
        << "}";
    return out.str();
}

bool persist_report_if_required(bool requested, const std::string& report) {
#if defined(AETHER_GPU_TIMESTAMP_DEVICE_PROBE_PERSIST)
    const char* home = std::getenv("HOME");
    if (home == nullptr || home[0] == '\0') {
        std::cerr << "GPU_TIMESTAMP_DEVICE_PROBE_FAIL missing-home\n";
        return false;
    }
    const std::string path =
        std::string(home) + "/Documents/gpu_timestamp_probe_" +
        (requested ? "on" : "off") + "_v1.json";
    std::ofstream file(path, std::ios::binary | std::ios::trunc);
    if (!file) {
        std::cerr << "GPU_TIMESTAMP_DEVICE_PROBE_FAIL open-report path="
                  << path << '\n';
        return false;
    }
    file << report << '\n';
    file.close();
    if (!file) {
        std::cerr << "GPU_TIMESTAMP_DEVICE_PROBE_FAIL write-report path="
                  << path << '\n';
        return false;
    }
    std::cout << "GPU_TIMESTAMP_DEVICE_PROBE_REPORT_PATH=" << path << '\n';
#else
    (void)requested;
    (void)report;
#endif
    return true;
}

}  // namespace

int main() {
    const bool requested = gti::process_env_requests_v1();
    aether::tools::DawnKernelHarness harness;
    const bool initialized = harness.init();

    AetherGpuTimestampProbeV1 probe{};
    probe.struct_size = sizeof(probe);
    const int probe_rc = aether_sed_gpu_timestamp_probe_v1(&probe);
    if (probe_rc != AETHER_GPU_TIMESTAMP_PULL_OK_V1 ||
        std::strcmp(probe.selected_env_key,
                    "OFFICIAL_AETHER_GPU_TIMESTAMPS") != 0) {
        std::cerr << "GPU_TIMESTAMP_DEVICE_PROBE_FAIL identity probe_rc="
                  << probe_rc << '\n';
        return 1;
    }

    AetherGpuTimestampFrameV1 frame{};
    frame.struct_size = sizeof(frame);
    int frame_pull_rc = AETHER_GPU_TIMESTAMP_PULL_NOT_READY_V1;
    bool execution_ok = true;
    uint32_t warmup_discarded_pair_count = 0;

    if (initialized) {
        harness.gpu_ts_reset();
        if (harness.gpu_ts_enabled()) {
            static constexpr char kProbeWgsl[] = R"(
@group(0) @binding(0) var<storage, read_write> output: array<u32>;
@compute @workgroup_size(1)
fn main() {
  output[0] = output[0] + 1u;
}
)";
            const auto pipeline = harness.load_compute(kProbeWgsl);
            const auto output = harness.alloc(
                sizeof(uint32_t),
                wgpu::BufferUsage::Storage | wgpu::BufferUsage::CopySrc);
            // Dawn/Metal can return a zero/nonmonotonic pair for the first
            // TimestampQuery use after a cold process start. Exercise that
            // explicitly outside the capability sample, record the excluded
            // pair count, then begin the two-pair measured probe.
            harness.dispatch(pipeline, {output}, 1);
            warmup_discarded_pair_count = harness.gpu_ts_pass_count();
            harness.gpu_ts_reset();
            harness.dispatch(pipeline, {output}, 1);
            harness.dispatch(pipeline, {output}, 1);
            std::vector<uint64_t> pass_ns;
            const bool resolved = harness.gpu_ts_resolve(&pass_ns);
            const uint32_t pass_count = harness.gpu_ts_pass_count();
            uint32_t boundaries[AETHER_GPU_TIMESTAMP_STAGE_CAPACITY_V1]{};
            for (uint32_t& boundary : boundaries) {
                boundary = pass_count;
            }
            if (!resolved || pass_count != 2 || pass_ns.size() != 2 ||
                !harness.gpu_ts_finalize_frame(
                    boundaries, AETHER_GPU_TIMESTAMP_STAGE_CAPACITY_V1)) {
                std::cerr
                    << "GPU_TIMESTAMP_DEVICE_PROBE_FAIL enabled-resolve"
                    << " pass_count=" << pass_count
                    << " resolved=" << (resolved ? 1 : 0)
                    << " durations=" << pass_ns.size() << '\n';
                execution_ok = false;
            }
        }
        frame_pull_rc = aether_sed_last_gpu_timestamp_frame_v1(&frame);
    }

    const bool off_ok =
        !requested && initialized &&
        probe.capability ==
            AETHER_GPU_TIMESTAMP_CAPABILITY_NOT_PROBED_V1 &&
        probe.status == AETHER_GPU_TIMESTAMP_STATUS_OFF_V1 &&
        probe.ts_enabled == 0 &&
        !harness.gpu_ts_feature_request_to_device() &&
        !harness.gpu_ts_feature_granted() &&
        frame_pull_rc == AETHER_GPU_TIMESTAMP_PULL_OK_V1;
    const bool unsupported =
        requested && initialized &&
        probe.capability == AETHER_GPU_TIMESTAMP_CAPABILITY_UNSUPPORTED_V1 &&
        probe.status == AETHER_GPU_TIMESTAMP_STATUS_UNSUPPORTED_V1 &&
        probe.ts_enabled == 0 &&
        !harness.gpu_ts_feature_request_to_device() &&
        !harness.gpu_ts_feature_granted() &&
        frame_pull_rc == AETHER_GPU_TIMESTAMP_PULL_OK_V1;
    const bool enabled_ok =
        requested && initialized && execution_ok &&
        probe.capability == AETHER_GPU_TIMESTAMP_CAPABILITY_SUPPORTED_V1 &&
        probe.status == AETHER_GPU_TIMESTAMP_STATUS_ENABLED_V1 &&
        probe.ts_enabled == 1 &&
        harness.gpu_ts_feature_request_to_device() &&
        harness.gpu_ts_feature_granted() &&
        warmup_discarded_pair_count == 1 &&
        frame_pull_rc == AETHER_GPU_TIMESTAMP_PULL_OK_V1 &&
        frame.valid == 1 && frame.raw_pair_count == 2 &&
        frame.resolve_attempt_count == 1 &&
        frame.resolve_success_count == 1 && frame.drop_count == 0;
    const char* verdict =
        off_ok
            ? "OFF_PROPAGATION_CONFIRMED"
            : unsupported
                  ? "BLOCKED_GPU_TIMESTAMP_CAPABILITY"
                  : enabled_ok
                        ? "SUPPORTED_GPU_TIMESTAMP_CAPABILITY"
                        : "P2_STOP_GPU_TIMESTAMP_PROBE_ERROR";

    const std::string report =
        make_report(probe, frame, frame_pull_rc, initialized,
                    harness.gpu_ts_feature_request_to_device(),
                    harness.gpu_ts_feature_granted(),
                    warmup_discarded_pair_count, verdict);
    std::cout << report << '\n';
    if (!persist_report_if_required(requested, report)) {
        return 1;
    }

    std::cout << "GPU_TIMESTAMP_DEVICE_PROBE_VERDICT=" << verdict << '\n';
    if (!off_ok && !unsupported && !enabled_ok) {
        std::cerr << "GPU_TIMESTAMP_DEVICE_PROBE_FAIL verdict=" << verdict
                  << '\n';
        return 1;
    }
    return 0;
}
