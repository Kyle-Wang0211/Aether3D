// SPDX-License-Identifier: LicenseRef-Aether3D-Proprietary

#include "official_gpu_timestamp_diagnostics_v1.h"

#include <atomic>
#include <cstdint>
#include <cstring>
#include <iostream>
#include <thread>

namespace gti = aether::tools::gpu_timestamp_internal;

namespace {

int fail(const char* message) {
    std::cerr << "GPU_TIMESTAMP_CONTRACT_FAIL: " << message << '\n';
    return 1;
}

template <size_t N>
void put(char (&destination)[N], const char* source) {
    std::strncpy(destination, source, N - 1);
    destination[N - 1] = '\0';
}

AetherGpuTimestampProbeV1 make_probe(uint64_t id) {
    AetherGpuTimestampProbeV1 probe{};
    probe.struct_size = sizeof(probe);
    probe.schema_version = AETHER_GPU_TIMESTAMP_SCHEMA_VERSION_V1;
    probe.presence_flags = AETHER_GPU_TIMESTAMP_PRESENCE_PERIOD_V1;
    probe.requested = 1;
    probe.probe_instance_id = id;
    probe.capability = AETHER_GPU_TIMESTAMP_CAPABILITY_SUPPORTED_V1;
    probe.status = AETHER_GPU_TIMESTAMP_STATUS_ENABLED_V1;
    probe.ts_enabled = 1;
    probe.query_capacity = AETHER_GPU_TIMESTAMP_RAW_PAIR_CAPACITY_V1 * 2;
    probe.timestamp_period_ns = 1;
    put(probe.selected_env_key, gti::AETHER_GPU_TIMESTAMP_ENV_KEY_V1);
    put(probe.adapter_identity, "contract-adapter");
    put(probe.dawn_version, "contract-version");
    put(probe.dawn_build_hash, "contract-build");
    return probe;
}

AetherGpuTimestampFrameV1 make_frame(uint64_t id, uint64_t ordinal) {
    AetherGpuTimestampFrameV1 frame{};
    frame.struct_size = sizeof(frame);
    frame.schema_version = AETHER_GPU_TIMESTAMP_SCHEMA_VERSION_V1;
    frame.presence_flags =
        AETHER_GPU_TIMESTAMP_PRESENCE_PERIOD_V1 |
        AETHER_GPU_TIMESTAMP_PRESENCE_DURATIONS_V1 |
        AETHER_GPU_TIMESTAMP_PRESENCE_RAW_PAIRS_V1 |
        AETHER_GPU_TIMESTAMP_PRESENCE_PROBE_REF_V1;
    frame.status = AETHER_GPU_TIMESTAMP_STATUS_ENABLED_V1;
    frame.probe_instance_id = id;
    frame.extraction_ordinal = ordinal;
    frame.valid = 1;
    frame.stage_count = AETHER_GPU_TIMESTAMP_STAGE_CAPACITY_V1;
    frame.raw_pair_count = AETHER_GPU_TIMESTAMP_STAGE_CAPACITY_V1;
    frame.resolve_attempt_count = 1;
    frame.resolve_success_count = 1;
    frame.timestamp_period_ns = 1;
    for (uint32_t i = 0; i < AETHER_GPU_TIMESTAMP_STAGE_CAPACITY_V1; ++i) {
        frame.stage_duration_ns[i] = ordinal * 100 + i + 1;
        frame.raw_pairs[i].begin_tick = ordinal * 1000 + i * 10;
        frame.raw_pairs[i].end_tick =
            frame.raw_pairs[i].begin_tick + frame.stage_duration_ns[i];
        frame.raw_pairs[i].stage_index = i;
    }
    return frame;
}

}  // namespace

int main() {
    static_assert(AETHER_GPU_TIMESTAMP_STATUS_OFF_V1 == 0);
    static_assert(AETHER_GPU_TIMESTAMP_STATUS_ENABLED_V1 == 1);
    static_assert(AETHER_GPU_TIMESTAMP_STATUS_UNSUPPORTED_V1 == 2);
    static_assert(AETHER_GPU_TIMESTAMP_STATUS_RESOURCE_FAILED_V1 == 3);
    static_assert(AETHER_GPU_TIMESTAMP_STATUS_RESOLVE_FAILED_V1 == 4);
    static_assert(AETHER_GPU_TIMESTAMP_STAGE_CAPACITY_V1 == 9);
    static_assert(AETHER_GPU_TIMESTAMP_RAW_PAIR_CAPACITY_V1 == 512);

    if (gti::env_value_requests_v1(nullptr) ||
        gti::env_value_requests_v1("") ||
        gti::env_value_requests_v1("0") ||
        gti::env_value_requests_v1("10") ||
        !gti::env_value_requests_v1("1")) {
        return fail("exact env parser");
    }

    const auto off = gti::classify_initial_state_v1({false, false, false, false});
    const auto unsupported =
        gti::classify_initial_state_v1({true, true, false, false});
    const auto resource =
        gti::classify_initial_state_v1({true, true, true, false});
    const auto enabled =
        gti::classify_initial_state_v1({true, true, true, true});
    if (off.status != AETHER_GPU_TIMESTAMP_STATUS_OFF_V1 ||
        off.capability != AETHER_GPU_TIMESTAMP_CAPABILITY_NOT_PROBED_V1 ||
        unsupported.status != AETHER_GPU_TIMESTAMP_STATUS_UNSUPPORTED_V1 ||
        resource.status != AETHER_GPU_TIMESTAMP_STATUS_RESOURCE_FAILED_V1 ||
        enabled.status != AETHER_GPU_TIMESTAMP_STATUS_ENABLED_V1 ||
        gti::classify_frame_status_v1(enabled.status, false) !=
            AETHER_GPU_TIMESTAMP_STATUS_RESOLVE_FAILED_V1) {
        return fail("five-state classifier");
    }
    const auto first_resolve = gti::begin_resolve_attempt_v1(0);
    const auto duplicate_resolve =
        gti::begin_resolve_attempt_v1(first_resolve.attempt_count);
    if (!first_resolve.encode_allowed ||
        first_resolve.attempt_count != 1 ||
        duplicate_resolve.encode_allowed ||
        duplicate_resolve.attempt_count != 2) {
        return fail("one-resolve-per-extraction guard");
    }
    const auto resource_ok =
        gti::classify_scoped_resource_result_v1(true, true, true);
    const auto nonnull_error_object =
        gti::classify_scoped_resource_result_v1(true, true, false);
    const auto null_resource =
        gti::classify_scoped_resource_result_v1(false, true, true);
    if (!resource_ok.accepted || nonnull_error_object.accepted ||
        null_resource.accepted) {
        return fail("scoped resource error-object classification");
    }
    if (!gti::classify_resolve_completion_v1(true, true).accepted ||
        gti::classify_resolve_completion_v1(false, true).accepted ||
        gti::classify_resolve_completion_v1(true, false).accepted) {
        return fail("resolve queue/scope completion classification");
    }
    uint32_t drops = 0;
    drops = gti::increment_drop_count_v1(drops);
    drops = gti::increment_drop_count_v1(drops);
    if (drops != 2 ||
        gti::increment_drop_count_v1(UINT32_MAX) != UINT32_MAX) {
        return fail("saturating timestamp drop count");
    }

    gti::reset_snapshots_for_test_v1();
    AetherGpuTimestampProbeV1 not_ready{};
    not_ready.struct_size = sizeof(not_ready);
    const auto not_ready_before = not_ready;
    if (aether_sed_gpu_timestamp_probe_v1(&not_ready) !=
            AETHER_GPU_TIMESTAMP_PULL_NOT_READY_V1 ||
        std::memcmp(&not_ready, &not_ready_before, sizeof(not_ready)) != 0) {
        return fail("NOT_READY modified caller");
    }

    auto probe = make_probe(77);
    gti::publish_probe_v1(probe);
    AetherGpuTimestampProbeV1 wrong_size{};
    wrong_size.struct_size = sizeof(wrong_size) - 1;
    const auto wrong_size_before = wrong_size;
    if (aether_sed_gpu_timestamp_probe_v1(&wrong_size) !=
            AETHER_GPU_TIMESTAMP_PULL_SIZE_MISMATCH_V1 ||
        std::memcmp(&wrong_size, &wrong_size_before, sizeof(wrong_size)) != 0) {
        return fail("SIZE_MISMATCH modified caller");
    }
    AetherGpuTimestampProbeV1 copied_probe{};
    copied_probe.struct_size = sizeof(copied_probe);
    if (aether_sed_gpu_timestamp_probe_v1(&copied_probe) !=
            AETHER_GPU_TIMESTAMP_PULL_OK_V1 ||
        copied_probe.probe_instance_id != 77 ||
        std::strcmp(copied_probe.selected_env_key,
                    gti::AETHER_GPU_TIMESTAMP_ENV_KEY_V1) != 0) {
        return fail("probe copy");
    }
    probe.probe_instance_id = 88;
    if (copied_probe.probe_instance_id != 77) {
        return fail("caller memory retained");
    }

    std::atomic<bool> stop{false};
    std::atomic<bool> torn{false};
    std::thread publisher([&] {
        for (uint64_t ordinal = 1; ordinal <= 20000; ++ordinal) {
            gti::publish_frame_v1(make_frame(77, ordinal));
        }
        stop.store(true, std::memory_order_release);
    });
    std::thread reader([&] {
        while (!stop.load(std::memory_order_acquire)) {
            AetherGpuTimestampFrameV1 frame{};
            frame.struct_size = sizeof(frame);
            const int rc = aether_sed_last_gpu_timestamp_frame_v1(&frame);
            if (rc == AETHER_GPU_TIMESTAMP_PULL_NOT_READY_V1) {
                continue;
            }
            if (rc != AETHER_GPU_TIMESTAMP_PULL_OK_V1 ||
                frame.probe_instance_id != 77 ||
                frame.stage_count != AETHER_GPU_TIMESTAMP_STAGE_CAPACITY_V1 ||
                frame.raw_pair_count != AETHER_GPU_TIMESTAMP_STAGE_CAPACITY_V1) {
                torn.store(true, std::memory_order_relaxed);
                break;
            }
            for (uint32_t i = 0; i < frame.stage_count; ++i) {
                if (frame.stage_duration_ns[i] !=
                        frame.extraction_ordinal * 100 + i + 1 ||
                    frame.raw_pairs[i].stage_index != i ||
                    frame.raw_pairs[i].begin_tick !=
                        frame.extraction_ordinal * 1000 + i * 10) {
                    torn.store(true, std::memory_order_relaxed);
                    break;
                }
            }
        }
    });
    publisher.join();
    reader.join();
    if (torn.load(std::memory_order_relaxed)) {
        return fail("concurrent torn snapshot");
    }
    AetherGpuTimestampFrameV1 wrong_frame_size{};
    wrong_frame_size.struct_size = sizeof(wrong_frame_size) - 1;
    const auto wrong_frame_before = wrong_frame_size;
    if (aether_sed_last_gpu_timestamp_frame_v1(&wrong_frame_size) !=
            AETHER_GPU_TIMESTAMP_PULL_SIZE_MISMATCH_V1 ||
        std::memcmp(&wrong_frame_size, &wrong_frame_before,
                    sizeof(wrong_frame_size)) != 0 ||
        aether_sed_last_gpu_timestamp_frame_v1(nullptr) !=
            AETHER_GPU_TIMESTAMP_PULL_INVALID_ARGUMENT_V1) {
        return fail("frame pull argument/size contract");
    }

    auto replacement_probe = make_probe(78);
    if (!gti::publish_probe_v1(replacement_probe) ||
        gti::publish_probe_v1(make_probe(77))) {
        return fail("probe publication order regressed");
    }
    AetherGpuTimestampFrameV1 stale_frame{};
    stale_frame.struct_size = sizeof(stale_frame);
    if (gti::publish_frame_v1(make_frame(77, 20001)) ||
        aether_sed_last_gpu_timestamp_frame_v1(&stale_frame) !=
        AETHER_GPU_TIMESTAMP_PULL_NOT_READY_V1) {
        return fail("foreign probe frame replaced current snapshot");
    }
    if (!gti::publish_frame_v1(make_frame(78, 20001)) ||
        gti::mark_frame_not_ready_v1(77)) {
        return fail("foreign harness cleared current snapshot");
    }
    stale_frame = {};
    stale_frame.struct_size = sizeof(stale_frame);
    if (aether_sed_last_gpu_timestamp_frame_v1(&stale_frame) !=
            AETHER_GPU_TIMESTAMP_PULL_OK_V1 ||
        stale_frame.probe_instance_id != 78 ||
        !gti::mark_frame_not_ready_v1(78) ||
        aether_sed_last_gpu_timestamp_frame_v1(&stale_frame) !=
            AETHER_GPU_TIMESTAMP_PULL_NOT_READY_V1) {
        return fail("owned snapshot clear contract");
    }
    if (gti::publish_frame_v1(make_frame(78, 20001)) ||
        gti::publish_frame_v1(make_frame(78, 20000)) ||
        !gti::publish_frame_v1(make_frame(78, 20002))) {
        return fail("same-probe frame ordinal regressed");
    }

    gti::clear_caller_thread_frame_v1();
    if (!gti::stash_current_frame_for_caller_thread_v1(78, 20002)) {
        return fail("caller thread did not seal matching frame");
    }
    if (!gti::publish_frame_v1(make_frame(78, 20003))) {
        return fail("newer global frame publication");
    }
    AetherGpuTimestampFrameV1 wrong_thread_frame_size{};
    wrong_thread_frame_size.struct_size =
        sizeof(wrong_thread_frame_size) - 1;
    if (aether_dsp_sift_take_last_gpu_timestamp_frame_v1(
            &wrong_thread_frame_size) !=
        AETHER_GPU_TIMESTAMP_PULL_SIZE_MISMATCH_V1) {
        return fail("caller thread frame size contract");
    }
    AetherGpuTimestampFrameV1 caller_owned_frame{};
    caller_owned_frame.struct_size = sizeof(caller_owned_frame);
    if (aether_dsp_sift_take_last_gpu_timestamp_frame_v1(
            &caller_owned_frame) != AETHER_GPU_TIMESTAMP_PULL_OK_V1 ||
        caller_owned_frame.probe_instance_id != 78 ||
        caller_owned_frame.extraction_ordinal != 20002 ||
        aether_dsp_sift_take_last_gpu_timestamp_frame_v1(
            &caller_owned_frame) != AETHER_GPU_TIMESTAMP_PULL_NOT_READY_V1) {
        return fail("caller thread frame was overwritten or not consumed");
    }

    auto thread_probe = make_probe(79);
    if (!gti::publish_probe_v1(thread_probe) ||
        !gti::publish_frame_v1(make_frame(79, 1))) {
        return fail("thread handoff setup");
    }
    std::atomic<bool> first_stashed{false};
    std::atomic<bool> release_first{false};
    std::atomic<bool> thread_handoff_failed{false};
    std::thread first_caller([&] {
        if (!gti::stash_current_frame_for_caller_thread_v1(79, 1)) {
            thread_handoff_failed.store(true, std::memory_order_relaxed);
            first_stashed.store(true, std::memory_order_release);
            return;
        }
        first_stashed.store(true, std::memory_order_release);
        while (!release_first.load(std::memory_order_acquire)) {
            std::this_thread::yield();
        }
        AetherGpuTimestampFrameV1 first{};
        first.struct_size = sizeof(first);
        if (aether_dsp_sift_take_last_gpu_timestamp_frame_v1(&first) !=
                AETHER_GPU_TIMESTAMP_PULL_OK_V1 ||
            first.probe_instance_id != 79 ||
            first.extraction_ordinal != 1) {
            thread_handoff_failed.store(true, std::memory_order_relaxed);
        }
    });
    while (!first_stashed.load(std::memory_order_acquire)) {
        std::this_thread::yield();
    }
    if (!gti::publish_frame_v1(make_frame(79, 2))) {
        release_first.store(true, std::memory_order_release);
        first_caller.join();
        return fail("second thread frame publication");
    }
    std::thread second_caller([&] {
        if (!gti::stash_current_frame_for_caller_thread_v1(79, 2)) {
            thread_handoff_failed.store(true, std::memory_order_relaxed);
            return;
        }
        AetherGpuTimestampFrameV1 second{};
        second.struct_size = sizeof(second);
        if (aether_dsp_sift_take_last_gpu_timestamp_frame_v1(&second) !=
                AETHER_GPU_TIMESTAMP_PULL_OK_V1 ||
            second.probe_instance_id != 79 ||
            second.extraction_ordinal != 2) {
            thread_handoff_failed.store(true, std::memory_order_relaxed);
        }
    });
    second_caller.join();
    release_first.store(true, std::memory_order_release);
    first_caller.join();
    if (thread_handoff_failed.load(std::memory_order_relaxed)) {
        return fail("caller-thread extraction ownership");
    }

    AetherGpuTimestampFrameV1 pending{};
    pending.struct_size = sizeof(pending);
    pending.schema_version = AETHER_GPU_TIMESTAMP_SCHEMA_VERSION_V1;
    pending.status = AETHER_GPU_TIMESTAMP_STATUS_ENABLED_V1;
    pending.probe_instance_id = 77;
    pending.extraction_ordinal = 20001;
    pending.raw_pair_count = AETHER_GPU_TIMESTAMP_STAGE_CAPACITY_V1;
    pending.resolve_attempt_count = 1;
    pending.resolve_success_count = 1;
    pending.timestamp_period_ns = 1;
    for (uint32_t i = 0; i < pending.raw_pair_count; ++i) {
        pending.raw_pairs[i].begin_tick = i * 100;
        pending.raw_pairs[i].end_tick = i * 100 + i + 1;
    }
    uint32_t bounds[AETHER_GPU_TIMESTAMP_STAGE_CAPACITY_V1]{};
    for (uint32_t i = 0; i < AETHER_GPU_TIMESTAMP_STAGE_CAPACITY_V1; ++i) {
        bounds[i] = i + 1;
    }
    if (!gti::finalize_frame_v1(
            &pending, 77, 20001, bounds,
            AETHER_GPU_TIMESTAMP_STAGE_CAPACITY_V1)) {
        return fail("pending frame finalization");
    }
    if (pending.valid != 1 ||
        pending.status != AETHER_GPU_TIMESTAMP_STATUS_ENABLED_V1 ||
        pending.presence_flags !=
            (AETHER_GPU_TIMESTAMP_PRESENCE_PERIOD_V1 |
             AETHER_GPU_TIMESTAMP_PRESENCE_DURATIONS_V1 |
             AETHER_GPU_TIMESTAMP_PRESENCE_RAW_PAIRS_V1 |
             AETHER_GPU_TIMESTAMP_PRESENCE_PROBE_REF_V1)) {
        return fail("finalized frame validity/presence");
    }

    // [GPU-TS-ZEROLEN 2026-08-08] 零长 pass(end == begin)是**合法**的 0 ns
    // 观测:GPU 时间戳量子(host 实测 65536 ns)远大于一个短 compute pass 的
    // 时长,78 个 pass 里实测 29 个 begin/end 落在同一 tick。旧语义把它当
    // "非单调"并作废**整帧**,直接导致九段 GPU 分解永远拿不到。这里把新语义
    // 钉死:零长按 0 计入本 stage,整帧照常有效;只有真正倒挂才判死。
    AetherGpuTimestampFrameV1 zero_len{};
    zero_len.struct_size = sizeof(zero_len);
    zero_len.schema_version = AETHER_GPU_TIMESTAMP_SCHEMA_VERSION_V1;
    zero_len.status = AETHER_GPU_TIMESTAMP_STATUS_ENABLED_V1;
    zero_len.probe_instance_id = 77;
    zero_len.extraction_ordinal = 30001;
    zero_len.raw_pair_count = AETHER_GPU_TIMESTAMP_STAGE_CAPACITY_V1;
    zero_len.resolve_attempt_count = 1;
    zero_len.resolve_success_count = 1;
    zero_len.timestamp_period_ns = 1;
    for (uint32_t i = 0; i < zero_len.raw_pair_count; ++i) {
        zero_len.raw_pairs[i].begin_tick = 1000 + i * 100;
        // stage 3 的那个 pass 是零长(end == begin)。
        zero_len.raw_pairs[i].end_tick =
            zero_len.raw_pairs[i].begin_tick + (i == 3 ? 0u : 5u);
    }
    uint32_t zero_bounds[AETHER_GPU_TIMESTAMP_STAGE_CAPACITY_V1]{};
    for (uint32_t i = 0; i < AETHER_GPU_TIMESTAMP_STAGE_CAPACITY_V1; ++i) {
        zero_bounds[i] = i + 1;
    }
    auto inverted_pair = zero_len;
    if (!gti::finalize_frame_v1(&zero_len, 77, 30001, zero_bounds,
                                AETHER_GPU_TIMESTAMP_STAGE_CAPACITY_V1)) {
        return fail("zero-length pass killed the whole frame");
    }
    if (zero_len.valid != 1 ||
        zero_len.status != AETHER_GPU_TIMESTAMP_STATUS_ENABLED_V1 ||
        zero_len.stage_duration_ns[0] != 5 ||
        zero_len.stage_duration_ns[3] != 0 ||
        zero_len.raw_pairs[3].stage_index != 3) {
        return fail("zero-length pass accounting");
    }

    // 倒挂(end < begin)仍必须整帧判死 —— 那是真的脏数据。
    inverted_pair.extraction_ordinal = 30002;
    inverted_pair.raw_pairs[5].end_tick =
        inverted_pair.raw_pairs[5].begin_tick - 1;
    if (gti::finalize_frame_v1(&inverted_pair, 77, 30002, zero_bounds,
                               AETHER_GPU_TIMESTAMP_STAGE_CAPACITY_V1) ||
        inverted_pair.reason_code !=
            AETHER_GPU_TIMESTAMP_REASON_NONMONOTONIC_PAIR_V1) {
        return fail("inverted timestamp pair accepted");
    }

    auto rejected = pending;
    rejected.valid = 0;
    rejected.extraction_ordinal = 20002;
    bounds[4] = bounds[3] - 1;
    if (gti::finalize_frame_v1(
            &rejected, 77, 20002, bounds,
            AETHER_GPU_TIMESTAMP_STAGE_CAPACITY_V1)) {
        return fail("invalid provenance finalized");
    }
    if (rejected.status != AETHER_GPU_TIMESTAMP_STATUS_RESOLVE_FAILED_V1 ||
        rejected.valid != 0 ||
        rejected.stage_count != 0 ||
        rejected.raw_pair_count != 0 ||
        (rejected.presence_flags &
         (AETHER_GPU_TIMESTAMP_PRESENCE_PERIOD_V1 |
          AETHER_GPU_TIMESTAMP_PRESENCE_DURATIONS_V1 |
          AETHER_GPU_TIMESTAMP_PRESENCE_RAW_PAIRS_V1)) != 0) {
        return fail("invalid frame exposed timing fields");
    }

    auto foreign = make_frame(77, 20003);
    foreign.valid = 0;
    if (gti::finalize_frame_v1(
            &foreign, 78, 20003, bounds,
            AETHER_GPU_TIMESTAMP_STAGE_CAPACITY_V1) ||
        foreign.reason_code !=
            AETHER_GPU_TIMESTAMP_REASON_PROVENANCE_FAILED_V1) {
        return fail("foreign harness probe ownership accepted");
    }

    std::cout << "GPU_TIMESTAMP_CONTRACT_PASS\n";
    return 0;
}
