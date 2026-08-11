#pragma once

#include "official_preclamp_instr_v1.h"

#include <cstdint>
#include <string>
#include <vector>

namespace aether_preclamp_instr_v1 {

using PhaseBGpuExtractFn = int (*)(const uint8_t* gray, int width, int height,
                                   int max_features, int num_threads,
                                   float* out_xy, uint8_t* out_desc,
                                   int out_cap, int* out_count);

enum class PhaseBReplayDriverStatus : uint32_t {
  kOff = 0,
  kOk = 1,
  kInvalidArgument = 2,
  kAlreadySealed = 3,
  kExtractorFailed = 4,
  kExtractorFallbackOrUninstrumented = 5,
  kJournalFailed = 6,
  kSealed = 7,
  kNotInitialized = 8,
  kInputIdentityMismatch = 9,
  kIncomplete = 10,
};

struct PhaseBReplayFrameIdentityV1 {
  int64_t frame_id = -1;
  std::string source_sha256;
};

struct PhaseBReplayPlanV1 {
  std::string ordered_manifest_sha256;
  std::vector<PhaseBReplayFrameIdentityV1> ordered_frames;
};

// Private count-only orchestrator. It intentionally has no DB, matcher, TVG,
// mapper, BA, or PLY dependency. The platform adapter owns exact image decode
// and passes the same full-resolution gray bytes used by production.
class PhaseBReplayDriverV1 final {
 public:
  PhaseBReplayDriverV1() = default;
  ~PhaseBReplayDriverV1() = default;
  PhaseBReplayDriverV1(const PhaseBReplayDriverV1&) = delete;
  PhaseBReplayDriverV1& operator=(const PhaseBReplayDriverV1&) = delete;

  PhaseBReplayDriverStatus Initialize(
      const PhaseBReplayPlanV1& plan) noexcept;

  PhaseBReplayDriverStatus AddGrayFrame(
      const uint8_t* gray, int width, int height, int64_t frame_id,
      const std::string& source_sha256,
      FieldStatus thermal_state_status, int32_t thermal_state,
      PhaseBGpuExtractFn extractor) noexcept;

  PhaseBReplayDriverStatus Seal(PhaseBHeadroomReport* out) noexcept;

 private:
  SessionRecords records_;
  PhaseBReplayPlanV1 plan_;
  size_t next_plan_index_ = 0;
  uint32_t accepted_frames_ = 0;
  bool initialized_ = false;
  bool failed_ = false;
  bool sealed_ = false;
};

}  // namespace aether_preclamp_instr_v1

#if defined(__GNUC__) || defined(__clang__)
#define AETHER_PRECLAMP_REPLAY_PRIVATE __attribute__((visibility("hidden")))
#else
#define AETHER_PRECLAMP_REPLAY_PRIVATE
#endif

// Private C seam consumed only by the product-local ImageIO adapter. It is not
// part of the stable SfM ABI and must remain hidden inside PWOfficialSfm.
struct aether_preclamp_phase_b_report_v1 {
  uint64_t accepted_frames;
  uint64_t legacy_descriptor_rows_total;
  uint64_t coverage8192_rows_total;
  uint64_t canonical8192_rows_total;
  uint64_t frames_descriptor_gt_8192;
  double coverage_row_headroom;
  double canonical_row_headroom;
};

extern "C" {

AETHER_PRECLAMP_REPLAY_PRIVATE uint32_t
aether_preclamp_phase_b_replay_create_v1(
    const char* ordered_manifest_sha256, const int64_t* ordered_frame_ids,
    const char* const* ordered_source_sha256, uint32_t frame_count,
    void** out_handle) noexcept;

AETHER_PRECLAMP_REPLAY_PRIVATE uint32_t
aether_preclamp_phase_b_replay_add_gray_v1(
    void* handle, const uint8_t* gray, int width, int height, int64_t frame_id,
    const char* source_sha256, uint32_t thermal_state_status,
    int32_t thermal_state,
    aether_preclamp_instr_v1::PhaseBGpuExtractFn extractor) noexcept;

AETHER_PRECLAMP_REPLAY_PRIVATE uint32_t
aether_preclamp_phase_b_replay_seal_v1(
    void* handle, aether_preclamp_phase_b_report_v1* out_report) noexcept;

AETHER_PRECLAMP_REPLAY_PRIVATE void
aether_preclamp_phase_b_replay_destroy_v1(void* handle) noexcept;

}  // extern "C"

#undef AETHER_PRECLAMP_REPLAY_PRIVATE
