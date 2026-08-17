#pragma once

#include "../../official_pipeline/src/official_preclamp_instr_v1.h"

#include <cassert>
#include <cstdint>
#include <filesystem>
#include <fstream>
#include <iterator>
#include <string>
#include <vector>

#include <unistd.h>

namespace preclamp_stage_b_test {

using aether_preclamp_instr_v1::AcceptedFrameStatus;
using aether_preclamp_instr_v1::FieldStatus;
using aether_preclamp_instr_v1::FrameCounts;

struct TempHome {
  std::string path;

  explicit TempHome(const char* label) {
    std::string pattern = std::string("/private/tmp/preclamp-stage-b-") +
                          label + ".XXXXXX";
    std::vector<char> writable(pattern.begin(), pattern.end());
    writable.push_back('\0');
    char* made = ::mkdtemp(writable.data());
    assert(made != nullptr);
    path = made;
    std::filesystem::create_directories(
        path + "/Library/Application Support");
  }

  TempHome(const TempHome&) = delete;
  TempHome& operator=(const TempHome&) = delete;

  ~TempHome() {
    assert(path.rfind("/private/tmp/preclamp-stage-b-", 0) == 0);
    std::error_code error;
    std::filesystem::remove_all(path, error);
  }

  std::string Journal(const std::string& run_id) const {
    return path + "/Library/Application Support/AetherDiagnostics/" + run_id +
           "/stage_b_counts.v1";
  }
};

inline FrameCounts MakeAccepted(uint32_t ordinal, int64_t frame_id) {
  FrameCounts row;
  row.accepted_status = AcceptedFrameStatus::kAccepted;
  row.frame_ordinal = ordinal;
  row.frame_id = frame_id;
  row.count_status = FieldStatus::kValid;
  row.preclamp_count = 10000;
  row.legacy_count = 9000;
  row.strict_shadow_count = 8192;
  row.overflow_group_size = 808;
  row.descriptor_rows_status = FieldStatus::kValid;
  row.descriptor_rows = 9000;
  row.gpu_ms_status = FieldStatus::kValid;
  row.gpu_ms = 1.5f;
  row.thermal_state_status = FieldStatus::kValid;
  row.thermal_state = 2;
  row.queue_backlog_status = FieldStatus::kPendingExternalJoin;
  row.queue_backlog = 0;
  return row;
}

inline std::string ReadText(const std::string& path) {
  std::ifstream input(path, std::ios::binary);
  assert(input.good());
  return std::string(std::istreambuf_iterator<char>(input),
                     std::istreambuf_iterator<char>());
}

inline std::vector<uint8_t> Bytes(const std::string& text) {
  return std::vector<uint8_t>(text.begin(), text.end());
}

inline void ConfigureOn(const TempHome& home, const std::string& run_id) {
  assert(::setenv("HOME", home.path.c_str(), 1) == 0);
  assert(::setenv("AETHER_PRECLAMP_INSTR_V1", "1", 1) == 0);
  assert(::setenv("AETHER_PRECLAMP_RUN_ID_V1", run_id.c_str(), 1) == 0);
  assert(::setenv("AETHER_PRECLAMP_SOURCE_SHA256_V1",
                  aether_preclamp_instr_v1::EmbeddedStageBSourceClosure(),
                  1) == 0);
}

}  // namespace preclamp_stage_b_test
