// SPDX-License-Identifier: LicenseRef-Aether3D-Proprietary

#include "official_gpu_timestamp_writer_v1.h"

#include <atomic>
#include <cstdint>
#include <cstring>
#include <iostream>
#include <string>
#include <thread>
#include <vector>

namespace writer = aether::official::gpu_timestamp_writer_v1;

namespace {

int fail(const char* message) {
  std::cerr << "GPU_TIMESTAMP_WRITER_CONTRACT_FAIL: " << message << '\n';
  return 1;
}

template <size_t N>
void put(char (&destination)[N], const char* source) {
  std::strncpy(destination, source, N - 1);
  destination[N - 1] = '\0';
}

AetherGpuTimestampProbeV1 MakeProbe() {
  AetherGpuTimestampProbeV1 probe{};
  probe.struct_size = sizeof(probe);
  probe.schema_version = AETHER_GPU_TIMESTAMP_SCHEMA_VERSION_V1;
  probe.presence_flags = AETHER_GPU_TIMESTAMP_PRESENCE_PERIOD_V1;
  probe.requested = 1;
  probe.probe_instance_id = 41;
  probe.capability = AETHER_GPU_TIMESTAMP_CAPABILITY_SUPPORTED_V1;
  probe.status = AETHER_GPU_TIMESTAMP_STATUS_ENABLED_V1;
  probe.ts_enabled = 1;
  probe.reason_code = AETHER_GPU_TIMESTAMP_REASON_NONE_V1;
  probe.query_capacity = 1024;
  probe.timestamp_period_ns = 1;
  put(probe.selected_env_key, "OFFICIAL_AETHER_GPU_TIMESTAMPS");
  put(probe.adapter_identity, "Apple \"A16\"\\Metal\nGPU");
  put(probe.dawn_version, "git-revision-sha1");
  put(probe.dawn_build_hash,
      "12ee391c7411285895f4289a3d889a182c093014");
  return probe;
}

AetherGpuTimestampFrameV1 MakeValidFrame(uint64_t ordinal) {
  AetherGpuTimestampFrameV1 frame{};
  frame.struct_size = sizeof(frame);
  frame.schema_version = AETHER_GPU_TIMESTAMP_SCHEMA_VERSION_V1;
  frame.presence_flags =
      AETHER_GPU_TIMESTAMP_PRESENCE_PERIOD_V1 |
      AETHER_GPU_TIMESTAMP_PRESENCE_DURATIONS_V1 |
      AETHER_GPU_TIMESTAMP_PRESENCE_RAW_PAIRS_V1 |
      AETHER_GPU_TIMESTAMP_PRESENCE_PROBE_REF_V1;
  frame.status = AETHER_GPU_TIMESTAMP_STATUS_ENABLED_V1;
  frame.probe_instance_id = 41;
  frame.extraction_ordinal = ordinal;
  frame.valid = 1;
  frame.reason_code = AETHER_GPU_TIMESTAMP_REASON_NONE_V1;
  frame.stage_count = AETHER_GPU_TIMESTAMP_STAGE_CAPACITY_V1;
  frame.raw_pair_count = 2;
  frame.resolve_attempt_count = 1;
  frame.resolve_success_count = 1;
  frame.timestamp_period_ns = 1;
  frame.raw_pairs[0] = {100, 120, 0, 0};
  frame.raw_pairs[1] = {200, 260, 7, 0};
  frame.stage_duration_ns[0] = 20;
  frame.stage_duration_ns[7] = 60;
  return frame;
}

bool Has(const std::string& value, const char* needle) {
  return value.find(needle) != std::string::npos;
}

}  // namespace

int main() {
  const writer::RecordIdentityV1 probe_identity{
      .run_id = 7001,
      .frame_id = -1,
      .frame_ordinal = 0,
      .probe_record_id = 9001,
  };
  std::string json;
  if (!writer::SerializeProbeRecordV1(
          MakeProbe(), probe_identity, 123456789, &json)) {
    return fail("valid probe rejected");
  }
  if (!Has(json, "\"type\":\"gpu_timestamp_probe_v1\"") ||
      !Has(json, "\"run_id\":7001") ||
      !Has(json, "\"probe_record_id\":9001") ||
      !Has(json, "\"probe_instance_id\":41") ||
      !Has(json, "\"env_key\":\"OFFICIAL_AETHER_GPU_TIMESTAMPS\"") ||
      !Has(json, "\"adapter\":\"Apple \\\"A16\\\"\\\\Metal\\nGPU\"") ||
      Has(json, "Apple \"A16\"\\Metal\nGPU")) {
    return fail("probe schema/escaping/identity");
  }

  const writer::RecordIdentityV1 frame_identity{
      .run_id = 7001,
      .frame_id = 17,
      .frame_ordinal = 18,
      .probe_record_id = 9002,
  };
  if (!writer::SerializeFrameRecordV1(
          MakeValidFrame(18), frame_identity, 123456790, &json)) {
    return fail("valid frame rejected");
  }
  if (!Has(json, "\"type\":\"gpu_timestamp_frame_v1\"") ||
      !Has(json, "\"frame_id\":17") ||
      !Has(json, "\"frame_ordinal\":18") ||
      !Has(json, "\"extraction_ordinal\":18") ||
      !Has(json, "\"stage_duration_ns\":[20,0,0,0,0,0,0,60,0]") ||
      !Has(json, "\"raw_pairs\":[[100,120,0],[200,260,7]]")) {
    return fail("valid frame schema/timing");
  }

  auto invalid = MakeValidFrame(19);
  invalid.status = AETHER_GPU_TIMESTAMP_STATUS_RESOLVE_FAILED_V1;
  invalid.valid = 0;
  invalid.reason_code =
      AETHER_GPU_TIMESTAMP_REASON_NONMONOTONIC_PAIR_V1;
  invalid.presence_flags = AETHER_GPU_TIMESTAMP_PRESENCE_PROBE_REF_V1;
  invalid.stage_count = 0;
  invalid.raw_pair_count = 0;
  invalid.timestamp_period_ns = 0;
  std::memset(invalid.stage_duration_ns, 0,
              sizeof(invalid.stage_duration_ns));
  std::memset(invalid.raw_pairs, 0, sizeof(invalid.raw_pairs));
  put(invalid.reason, "timestamp pair is zero or nonmonotonic");
  if (!writer::SerializeFrameRecordV1(
          invalid, frame_identity, 123456791, &json)) {
    return fail("invalid diagnostic frame rejected");
  }
  if (!Has(json, "\"status\":4") || !Has(json, "\"valid\":0") ||
      Has(json, "\"timestamp_period_ns\"") ||
      Has(json, "\"stage_duration_ns\"") ||
      Has(json, "\"raw_pairs\"")) {
    return fail("invalid frame exposed valid-looking timing");
  }

  // [GPU-TS-ZEROLEN 2026-08-08] 零长 pass(end == begin)是合法的 0 ns 观测,
  // 记录必须照常写出(此前 end <= begin 会让任何含短 pass 的真机 frame 记录
  // 静默写不出去);只有倒挂(end < begin)才拒绝。
  auto zero_len = MakeValidFrame(21);
  zero_len.raw_pair_count = 3;
  zero_len.raw_pairs[2] = {300, 300, 4, 0};
  if (!writer::SerializeFrameRecordV1(
          zero_len, frame_identity, 123456793, &json)) {
    return fail("zero-length pass frame rejected");
  }
  if (!Has(json, "\"raw_pairs\":[[100,120,0],[200,260,7],[300,300,4]]") ||
      !Has(json, "\"stage_duration_ns\":[20,0,0,0,0,0,0,60,0]")) {
    return fail("zero-length pass serialization");
  }

  auto inverted_pair = MakeValidFrame(22);
  inverted_pair.raw_pair_count = 3;
  inverted_pair.raw_pairs[2] = {300, 299, 4, 0};
  if (writer::SerializeFrameRecordV1(
          inverted_pair, frame_identity, 123456794, &json)) {
    return fail("inverted timestamp pair accepted");
  }

  auto inconsistent = MakeValidFrame(20);
  inconsistent.presence_flags &=
      ~static_cast<uint32_t>(AETHER_GPU_TIMESTAMP_PRESENCE_RAW_PAIRS_V1);
  if (writer::SerializeFrameRecordV1(
          inconsistent, frame_identity, 123456792, &json)) {
    return fail("inconsistent valid frame accepted");
  }

  std::atomic<bool> bad{false};
  std::vector<std::thread> threads;
  for (uint64_t ordinal = 1; ordinal <= 8; ++ordinal) {
    threads.emplace_back([ordinal, &bad] {
      const writer::RecordIdentityV1 identity{
          .run_id = 8000 + ordinal,
          .frame_id = static_cast<int64_t>(ordinal),
          .frame_ordinal = ordinal,
          .probe_record_id = 10000 + ordinal,
      };
      std::string local;
      const auto frame = MakeValidFrame(ordinal);
      if (!writer::SerializeFrameRecordV1(
              frame, identity, 200000 + ordinal, &local) ||
          !Has(local, ("\"run_id\":" +
                       std::to_string(8000 + ordinal)).c_str()) ||
          !Has(local, ("\"extraction_ordinal\":" +
                       std::to_string(ordinal)).c_str())) {
        bad.store(true, std::memory_order_relaxed);
      }
    });
  }
  for (auto& thread : threads) thread.join();
  if (bad.load(std::memory_order_relaxed)) {
    return fail("concurrent serialization mixed record identity");
  }

  std::cout << "GPU_TIMESTAMP_WRITER_CONTRACT_PASS\n";
  return 0;
}
