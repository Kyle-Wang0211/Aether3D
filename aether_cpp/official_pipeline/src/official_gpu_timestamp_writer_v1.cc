// SPDX-License-Identifier: LicenseRef-Aether3D-Proprietary
// Copyright (c) 2024-2026 Aether3D. All rights reserved.

#include "official_gpu_timestamp_writer_v1.h"

#include <array>
#include <cstddef>
#include <cstdint>
#include <iomanip>
#include <limits>
#include <locale>
#include <sstream>
#include <string>

namespace aether::official::gpu_timestamp_writer_v1 {
namespace {

constexpr uint32_t kKnownPresenceFlags =
    AETHER_GPU_TIMESTAMP_PRESENCE_PERIOD_V1 |
    AETHER_GPU_TIMESTAMP_PRESENCE_DURATIONS_V1 |
    AETHER_GPU_TIMESTAMP_PRESENCE_RAW_PAIRS_V1 |
    AETHER_GPU_TIMESTAMP_PRESENCE_PROBE_REF_V1;

bool ValidIdentity(const RecordIdentityV1& identity, bool is_frame) {
  if (identity.run_id == 0 || identity.probe_record_id == 0) return false;
  if (is_frame) {
    return identity.frame_id >= 0 && identity.frame_ordinal > 0;
  }
  return identity.frame_id == -1 && identity.frame_ordinal == 0;
}

template <size_t N>
size_t InlineLength(const char (&value)[N]) {
  size_t length = 0;
  while (length < N && value[length] != '\0') ++length;
  return length;
}

template <size_t N>
void AppendJsonString(std::ostringstream& out, const char (&value)[N]) {
  static constexpr char kHex[] = "0123456789abcdef";
  out << '"';
  const size_t length = InlineLength(value);
  for (size_t i = 0; i < length; ++i) {
    const unsigned char c = static_cast<unsigned char>(value[i]);
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
          out << "\\u00" << kHex[(c >> 4) & 0x0f] << kHex[c & 0x0f];
        } else {
          out << static_cast<char>(c);
        }
    }
  }
  out << '"';
}

bool HasNulTerminator(const char* value, size_t capacity) {
  for (size_t i = 0; i < capacity; ++i) {
    if (value[i] == '\0') return true;
  }
  return false;
}

bool CommonProbeValid(const AetherGpuTimestampProbeV1& probe) {
  if (probe.struct_size != sizeof(probe) ||
      probe.schema_version != AETHER_GPU_TIMESTAMP_SCHEMA_VERSION_V1 ||
      (probe.presence_flags & ~kKnownPresenceFlags) != 0 ||
      probe.probe_instance_id == 0 ||
      probe.capability > AETHER_GPU_TIMESTAMP_CAPABILITY_PROBE_ERROR_V1 ||
      probe.status > AETHER_GPU_TIMESTAMP_STATUS_RESOLVE_FAILED_V1 ||
      !HasNulTerminator(probe.selected_env_key,
                        sizeof(probe.selected_env_key)) ||
      !HasNulTerminator(probe.reason, sizeof(probe.reason)) ||
      !HasNulTerminator(probe.adapter_identity,
                        sizeof(probe.adapter_identity)) ||
      !HasNulTerminator(probe.dawn_version, sizeof(probe.dawn_version)) ||
      !HasNulTerminator(probe.dawn_build_hash,
                        sizeof(probe.dawn_build_hash))) {
    return false;
  }
  if (std::string(probe.selected_env_key) !=
      aether::tools::gpu_timestamp_internal::
          AETHER_GPU_TIMESTAMP_ENV_KEY_V1) {
    return false;
  }
  const bool enabled =
      probe.status == AETHER_GPU_TIMESTAMP_STATUS_ENABLED_V1;
  if (enabled) {
    return probe.requested == 1 &&
           probe.capability == AETHER_GPU_TIMESTAMP_CAPABILITY_SUPPORTED_V1 &&
           probe.ts_enabled == 1 &&
           (probe.presence_flags &
            AETHER_GPU_TIMESTAMP_PRESENCE_PERIOD_V1) != 0 &&
           probe.timestamp_period_ns > 0 && probe.query_capacity > 0;
  }
  return probe.ts_enabled == 0 &&
         (probe.presence_flags &
          AETHER_GPU_TIMESTAMP_PRESENCE_PERIOD_V1) == 0 &&
         probe.timestamp_period_ns == 0;
}

bool CommonFrameValid(const AetherGpuTimestampFrameV1& frame) {
  return frame.struct_size == sizeof(frame) &&
         frame.schema_version == AETHER_GPU_TIMESTAMP_SCHEMA_VERSION_V1 &&
         (frame.presence_flags & ~kKnownPresenceFlags) == 0 &&
         frame.probe_instance_id != 0 && frame.extraction_ordinal != 0 &&
         frame.status <= AETHER_GPU_TIMESTAMP_STATUS_RESOLVE_FAILED_V1 &&
         frame.stage_count <= AETHER_GPU_TIMESTAMP_STAGE_CAPACITY_V1 &&
         frame.raw_pair_count <=
             AETHER_GPU_TIMESTAMP_RAW_PAIR_CAPACITY_V1 &&
         HasNulTerminator(frame.reason, sizeof(frame.reason));
}

bool ValidEnabledFrame(const AetherGpuTimestampFrameV1& frame) {
  constexpr uint32_t kRequired =
      AETHER_GPU_TIMESTAMP_PRESENCE_PERIOD_V1 |
      AETHER_GPU_TIMESTAMP_PRESENCE_DURATIONS_V1 |
      AETHER_GPU_TIMESTAMP_PRESENCE_RAW_PAIRS_V1 |
      AETHER_GPU_TIMESTAMP_PRESENCE_PROBE_REF_V1;
  if (frame.status != AETHER_GPU_TIMESTAMP_STATUS_ENABLED_V1 ||
      frame.valid != 1 || frame.presence_flags != kRequired ||
      frame.stage_count != AETHER_GPU_TIMESTAMP_STAGE_CAPACITY_V1 ||
      frame.timestamp_period_ns == 0 ||
      frame.resolve_attempt_count != 1 ||
      frame.resolve_success_count != 1 || frame.drop_count != 0) {
    return false;
  }

  std::array<uint64_t, AETHER_GPU_TIMESTAMP_STAGE_CAPACITY_V1> sums{};
  for (uint32_t i = 0; i < frame.raw_pair_count; ++i) {
    const auto& pair = frame.raw_pairs[i];
    // [GPU-TS-ZEROLEN 2026-08-08] 与 finalize_frame_v1 同口径:零长 pass
    // (end == begin)是合法的 0 ns 观测,不得据此否掉整条 frame 记录;
    // 只有 end < begin(时钟倒挂)才是无效数据。此前这里的 <= 会让任何
    // 含短 pass 的真机 frame 记录写不出去。
    if (pair.stage_index >= AETHER_GPU_TIMESTAMP_STAGE_CAPACITY_V1 ||
        pair.end_tick < pair.begin_tick) {
      return false;
    }
    const uint64_t ticks = pair.end_tick - pair.begin_tick;
    if (ticks > std::numeric_limits<uint64_t>::max() /
                    frame.timestamp_period_ns) {
      return false;
    }
    const uint64_t duration = ticks * frame.timestamp_period_ns;
    if (sums[pair.stage_index] >
        std::numeric_limits<uint64_t>::max() - duration) {
      return false;
    }
    sums[pair.stage_index] += duration;
  }
  for (uint32_t i = 0; i < frame.stage_count; ++i) {
    if (sums[i] != frame.stage_duration_ns[i]) return false;
  }
  return true;
}

bool ValidInvalidFrame(const AetherGpuTimestampFrameV1& frame) {
  constexpr uint32_t kTimingFlags =
      AETHER_GPU_TIMESTAMP_PRESENCE_PERIOD_V1 |
      AETHER_GPU_TIMESTAMP_PRESENCE_DURATIONS_V1 |
      AETHER_GPU_TIMESTAMP_PRESENCE_RAW_PAIRS_V1;
  if (frame.status == AETHER_GPU_TIMESTAMP_STATUS_ENABLED_V1 ||
      frame.valid != 0 || (frame.presence_flags & kTimingFlags) != 0 ||
      frame.stage_count != 0 || frame.raw_pair_count != 0 ||
      frame.timestamp_period_ns != 0) {
    return false;
  }
  for (uint64_t value : frame.stage_duration_ns) {
    if (value != 0) return false;
  }
  return true;
}

void AppendIdentity(std::ostringstream& out,
                    const RecordIdentityV1& identity) {
  out << "\"run_id\":" << identity.run_id
      << ",\"frame_id\":" << identity.frame_id
      << ",\"frame_ordinal\":" << identity.frame_ordinal
      << ",\"probe_record_id\":" << identity.probe_record_id;
}

}  // namespace

bool SerializeProbeRecordV1(const AetherGpuTimestampProbeV1& probe,
                            const RecordIdentityV1& identity,
                            int64_t epoch_ms, std::string* out_json) {
  if (out_json == nullptr || epoch_ms <= 0 ||
      !ValidIdentity(identity, false) || !CommonProbeValid(probe)) {
    return false;
  }

  std::ostringstream out;
  out.imbue(std::locale::classic());
  out << "{\"t\":" << epoch_ms
      << ",\"type\":\"gpu_timestamp_probe_v1\","
      << "\"schema\":" << probe.schema_version << ',';
  AppendIdentity(out, identity);
  out << ",\"probe_instance_id\":" << probe.probe_instance_id
      << ",\"env_key\":";
  AppendJsonString(out, probe.selected_env_key);
  out << ",\"requested\":" << probe.requested
      << ",\"capability\":" << probe.capability
      << ",\"status\":" << probe.status
      << ",\"enabled\":" << probe.ts_enabled
      << ",\"reason_code\":" << probe.reason_code
      << ",\"reason\":";
  AppendJsonString(out, probe.reason);
  out << ",\"adapter\":";
  AppendJsonString(out, probe.adapter_identity);
  out << ",\"dawn_version\":";
  AppendJsonString(out, probe.dawn_version);
  out << ",\"dawn_build_hash\":";
  AppendJsonString(out, probe.dawn_build_hash);
  out << ",\"query_capacity\":" << probe.query_capacity;
  if ((probe.presence_flags &
       AETHER_GPU_TIMESTAMP_PRESENCE_PERIOD_V1) != 0) {
    out << ",\"timestamp_period_ns\":" << probe.timestamp_period_ns;
  }
  out << '}';
  *out_json = out.str();
  return true;
}

bool SerializeFrameRecordV1(const AetherGpuTimestampFrameV1& frame,
                            const RecordIdentityV1& identity,
                            int64_t epoch_ms, std::string* out_json) {
  if (out_json == nullptr || epoch_ms <= 0 ||
      !ValidIdentity(identity, true) || !CommonFrameValid(frame)) {
    return false;
  }
  const bool enabled = frame.status == AETHER_GPU_TIMESTAMP_STATUS_ENABLED_V1 &&
                       frame.valid == 1;
  if ((enabled && !ValidEnabledFrame(frame)) ||
      (!enabled && !ValidInvalidFrame(frame))) {
    return false;
  }

  std::ostringstream out;
  out.imbue(std::locale::classic());
  out << "{\"t\":" << epoch_ms
      << ",\"type\":\"gpu_timestamp_frame_v1\","
      << "\"schema\":" << frame.schema_version << ',';
  AppendIdentity(out, identity);
  out << ",\"probe_instance_id\":" << frame.probe_instance_id
      << ",\"extraction_ordinal\":" << frame.extraction_ordinal
      << ",\"status\":" << frame.status
      << ",\"valid\":" << frame.valid
      << ",\"reason_code\":" << frame.reason_code
      << ",\"reason\":";
  AppendJsonString(out, frame.reason);
  out << ",\"resolve_attempt_count\":" << frame.resolve_attempt_count
      << ",\"resolve_success_count\":" << frame.resolve_success_count
      << ",\"drop_count\":" << frame.drop_count;
  if (enabled) {
    out << ",\"timestamp_period_ns\":" << frame.timestamp_period_ns
        << ",\"stage_duration_ns\":[";
    for (uint32_t i = 0; i < frame.stage_count; ++i) {
      if (i != 0) out << ',';
      out << frame.stage_duration_ns[i];
    }
    out << "],\"raw_pairs\":[";
    for (uint32_t i = 0; i < frame.raw_pair_count; ++i) {
      if (i != 0) out << ',';
      const auto& pair = frame.raw_pairs[i];
      out << '[' << pair.begin_tick << ',' << pair.end_tick << ','
          << pair.stage_index << ']';
    }
    out << ']';
  }
  out << '}';
  *out_json = out.str();
  return true;
}

}  // namespace aether::official::gpu_timestamp_writer_v1
