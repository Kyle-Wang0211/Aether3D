#if !defined(AETHER_PRECLAMP_INSTR_ENV_OFFICIAL) && \
    !defined(AETHER_PRECLAMP_INSTR_ENV_SELFTEST)
#error "preclamp replay driver requires an explicit environment namespace"
#endif

#include "official_preclamp_replay_driver_v1.h"

#include <algorithm>
#include <limits>
#include <new>
#include <unordered_set>
#include <vector>

namespace aether_preclamp_instr_v1 {

namespace {

bool IsLowerHexSha256(const std::string& value) {
  return value.size() == 64 &&
         std::all_of(value.begin(), value.end(), [](char c) {
           return (c >= '0' && c <= '9') || (c >= 'a' && c <= 'f');
         });
}

}  // namespace

PhaseBReplayDriverStatus PhaseBReplayDriverV1::Initialize(
    const PhaseBReplayPlanV1& plan) noexcept {
  if (!Enabled()) return PhaseBReplayDriverStatus::kOff;
  if (initialized_ || sealed_) return PhaseBReplayDriverStatus::kAlreadySealed;
  if (!IsLowerHexSha256(plan.ordered_manifest_sha256) ||
      plan.ordered_frames.empty() ||
      plan.ordered_frames.size() >
          static_cast<size_t>(std::numeric_limits<uint32_t>::max())) {
    return PhaseBReplayDriverStatus::kInvalidArgument;
  }
  std::unordered_set<int64_t> frame_ids;
  for (const PhaseBReplayFrameIdentityV1& frame : plan.ordered_frames) {
    if (frame.frame_id < 0 || !IsLowerHexSha256(frame.source_sha256) ||
        !frame_ids.insert(frame.frame_id).second) {
      return PhaseBReplayDriverStatus::kInvalidArgument;
    }
  }
  try {
    plan_ = plan;
  } catch (...) {
    return PhaseBReplayDriverStatus::kInvalidArgument;
  }
  initialized_ = true;
  return PhaseBReplayDriverStatus::kOk;
}

PhaseBReplayDriverStatus PhaseBReplayDriverV1::AddGrayFrame(
    const uint8_t* gray, int width, int height, int64_t frame_id,
    const std::string& source_sha256,
    FieldStatus thermal_state_status, int32_t thermal_state,
    PhaseBGpuExtractFn extractor) noexcept {
  if (!Enabled()) return PhaseBReplayDriverStatus::kOff;
  if (!initialized_) return PhaseBReplayDriverStatus::kNotInitialized;
  if (failed_) return PhaseBReplayDriverStatus::kJournalFailed;
  if (sealed_) return PhaseBReplayDriverStatus::kAlreadySealed;
  if (gray == nullptr || width <= 0 || height <= 0 || frame_id < 0 ||
      extractor == nullptr ||
      accepted_frames_ == std::numeric_limits<uint32_t>::max()) {
    return PhaseBReplayDriverStatus::kInvalidArgument;
  }
  if (next_plan_index_ >= plan_.ordered_frames.size() ||
      plan_.ordered_frames[next_plan_index_].frame_id != frame_id ||
      plan_.ordered_frames[next_plan_index_].source_sha256 != source_sha256) {
    failed_ = true;
    return PhaseBReplayDriverStatus::kInputIdentityMismatch;
  }

  constexpr int kMaxFeatures = 8192;
  try {
    std::vector<float> xy(static_cast<size_t>(kMaxFeatures) * 2u);
    std::vector<uint8_t> descriptors(
        static_cast<size_t>(kMaxFeatures) * 128u);
    int emitted = 0;
    const int extract_result = extractor(
        gray, width, height, kMaxFeatures, /*num_threads=*/0, xy.data(),
        descriptors.data(), kMaxFeatures, &emitted);
    if (extract_result != 0 || emitted <= 0 || emitted > kMaxFeatures) {
      DiscardPending(PendingDiscardReason::kGpuFailureOrFallback);
      failed_ = true;
      return PhaseBReplayDriverStatus::kExtractorFailed;
    }

    FrameCounts row;
    if (!FinalizeAcceptedFrame(frame_id, accepted_frames_ + 1,
                               thermal_state_status, thermal_state, &row)) {
      failed_ = true;
      return PhaseBReplayDriverStatus::kExtractorFallbackOrUninstrumented;
    }
    if (!AppendSessionRecord(&records_, row)) {
      failed_ = true;
      return PhaseBReplayDriverStatus::kJournalFailed;
    }
    StageBJournalSnapshot snapshot;
    if (!CopyStageBJournalSnapshot(&records_, &snapshot) ||
        snapshot.status != StageBJournalStatus::kReady ||
        snapshot.first_failure != StageBFailureReason::kNone) {
      failed_ = true;
      return PhaseBReplayDriverStatus::kJournalFailed;
    }
    ++accepted_frames_;
    ++next_plan_index_;
    return PhaseBReplayDriverStatus::kOk;
  } catch (...) {
    DiscardPending(PendingDiscardReason::kValidationFailure);
    failed_ = true;
    return PhaseBReplayDriverStatus::kExtractorFailed;
  }
}

PhaseBReplayDriverStatus PhaseBReplayDriverV1::Seal(
    PhaseBHeadroomReport* out) noexcept {
  if (!Enabled()) return PhaseBReplayDriverStatus::kOff;
  if (!initialized_) return PhaseBReplayDriverStatus::kNotInitialized;
  if (failed_) return PhaseBReplayDriverStatus::kJournalFailed;
  if (sealed_) return PhaseBReplayDriverStatus::kAlreadySealed;
  if (out == nullptr || accepted_frames_ == 0) {
    return PhaseBReplayDriverStatus::kInvalidArgument;
  }
  if (next_plan_index_ != plan_.ordered_frames.size() ||
      accepted_frames_ != plan_.ordered_frames.size()) {
    return PhaseBReplayDriverStatus::kIncomplete;
  }
  std::vector<FrameCounts> rows;
  if (!CopySessionRecords(&records_, &rows) ||
      rows.size() != accepted_frames_) {
    return PhaseBReplayDriverStatus::kJournalFailed;
  }
  const PhaseBHeadroomStatus headroom = AnalyzePhaseBHeadroom(rows, out);
  if (headroom != PhaseBHeadroomStatus::kParkNoComputeHeadroom &&
      headroom != PhaseBHeadroomStatus::kComputeHeadroomPresent) {
    *out = PhaseBHeadroomReport{};
    return PhaseBReplayDriverStatus::kJournalFailed;
  }
  if (!SealStageBJournal(&records_)) {
    *out = PhaseBHeadroomReport{};
    return PhaseBReplayDriverStatus::kJournalFailed;
  }
  sealed_ = true;
  return PhaseBReplayDriverStatus::kSealed;
}

}  // namespace aether_preclamp_instr_v1

extern "C" uint32_t aether_preclamp_phase_b_replay_create_v1(
    const char* ordered_manifest_sha256, const int64_t* ordered_frame_ids,
    const char* const* ordered_source_sha256, uint32_t frame_count,
    void** out_handle) noexcept {
  using namespace aether_preclamp_instr_v1;
  if (out_handle != nullptr) *out_handle = nullptr;
  if (!Enabled()) {
    return static_cast<uint32_t>(PhaseBReplayDriverStatus::kOff);
  }
  if (out_handle == nullptr || ordered_manifest_sha256 == nullptr ||
      ordered_frame_ids == nullptr || ordered_source_sha256 == nullptr ||
      frame_count == 0) {
    return static_cast<uint32_t>(PhaseBReplayDriverStatus::kInvalidArgument);
  }

  try {
    PhaseBReplayPlanV1 plan;
    plan.ordered_manifest_sha256 = ordered_manifest_sha256;
    plan.ordered_frames.reserve(frame_count);
    for (uint32_t i = 0; i < frame_count; ++i) {
      if (ordered_source_sha256[i] == nullptr) {
        return static_cast<uint32_t>(
            PhaseBReplayDriverStatus::kInvalidArgument);
      }
      plan.ordered_frames.push_back(
          {ordered_frame_ids[i], ordered_source_sha256[i]});
    }
    PhaseBReplayDriverV1* driver =
        new (std::nothrow) PhaseBReplayDriverV1();
    if (driver == nullptr) {
      return static_cast<uint32_t>(
          PhaseBReplayDriverStatus::kInvalidArgument);
    }
    const PhaseBReplayDriverStatus status = driver->Initialize(plan);
    if (status != PhaseBReplayDriverStatus::kOk) {
      delete driver;
      return static_cast<uint32_t>(status);
    }
    *out_handle = driver;
    return static_cast<uint32_t>(PhaseBReplayDriverStatus::kOk);
  } catch (...) {
    return static_cast<uint32_t>(PhaseBReplayDriverStatus::kInvalidArgument);
  }
}

extern "C" uint32_t aether_preclamp_phase_b_replay_add_gray_v1(
    void* handle, const uint8_t* gray, int width, int height, int64_t frame_id,
    const char* source_sha256, uint32_t thermal_state_status,
    int32_t thermal_state,
    aether_preclamp_instr_v1::PhaseBGpuExtractFn extractor) noexcept {
  using namespace aether_preclamp_instr_v1;
  if (!Enabled()) {
    return static_cast<uint32_t>(PhaseBReplayDriverStatus::kOff);
  }
  if (handle == nullptr || source_sha256 == nullptr ||
      thermal_state_status > static_cast<uint32_t>(FieldStatus::kPendingExternalJoin)) {
    return static_cast<uint32_t>(PhaseBReplayDriverStatus::kInvalidArgument);
  }
  auto* driver = static_cast<PhaseBReplayDriverV1*>(handle);
  return static_cast<uint32_t>(driver->AddGrayFrame(
      gray, width, height, frame_id, source_sha256,
      static_cast<FieldStatus>(thermal_state_status), thermal_state,
      extractor));
}

extern "C" uint32_t aether_preclamp_phase_b_replay_seal_v1(
    void* handle, aether_preclamp_phase_b_report_v1* out_report) noexcept {
  using namespace aether_preclamp_instr_v1;
  if (out_report != nullptr) *out_report = {};
  if (!Enabled()) {
    return static_cast<uint32_t>(PhaseBReplayDriverStatus::kOff);
  }
  if (handle == nullptr || out_report == nullptr) {
    return static_cast<uint32_t>(PhaseBReplayDriverStatus::kInvalidArgument);
  }
  PhaseBHeadroomReport report;
  const PhaseBReplayDriverStatus status =
      static_cast<PhaseBReplayDriverV1*>(handle)->Seal(&report);
  if (status == PhaseBReplayDriverStatus::kSealed) {
    out_report->accepted_frames = report.accepted_frames;
    out_report->legacy_descriptor_rows_total =
        report.legacy_descriptor_rows_total;
    out_report->coverage8192_rows_total = report.coverage8192_rows_total;
    out_report->canonical8192_rows_total = report.canonical8192_rows_total;
    out_report->frames_descriptor_gt_8192 =
        report.frames_descriptor_gt_8192;
    out_report->coverage_row_headroom = report.coverage_row_headroom;
    out_report->canonical_row_headroom = report.canonical_row_headroom;
  }
  return static_cast<uint32_t>(status);
}

extern "C" void aether_preclamp_phase_b_replay_destroy_v1(
    void* handle) noexcept {
  delete static_cast<aether_preclamp_instr_v1::PhaseBReplayDriverV1*>(handle);
}
