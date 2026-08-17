#include "../../official_pipeline/src/official_preclamp_replay_driver_v1.h"
#include "test_preclamp_instr_v1_stage_b_fixture.h"

#include <cmath>
#include <cstdio>

namespace {

int FakeGpuExtract(const uint8_t*, int, int, int, int, float*, uint8_t*,
                   int, int* out_count) {
  aether_preclamp_instr_v1::BeginLegacyClamp(10000);
  aether_preclamp_instr_v1::UpdateLegacyClampResult(9000);
  if (!aether_preclamp_instr_v1::SealAcceptedLegacyGpuResult(
          9000, aether_preclamp_instr_v1::FieldStatus::kUnavailable, 0.0f)) {
    return 8;
  }
  *out_count = 8192;
  return 0;
}

}  // namespace

int main() {
  using namespace preclamp_stage_b_test;
  constexpr char kClosure[] =
      AETHER_PRECLAMP_SOURCE_CLOSURE_SHA256_V1;
  constexpr char kManifest[] =
      "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa";
  constexpr char kFrameSha[] =
      "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb";
  TempHome home("replay-bridge-on");
  ConfigureOn(home, "replay-bridge-on");
  (void)kClosure;

  const int64_t frame_ids[] = {17};
  const char* frame_shas[] = {kFrameSha};
  void* handle = nullptr;
  const uint32_t create = aether_preclamp_phase_b_replay_create_v1(
      kManifest, frame_ids, frame_shas, 1, &handle);
  if (create != static_cast<uint32_t>(
                    aether_preclamp_instr_v1::PhaseBReplayDriverStatus::kOk) ||
      handle == nullptr) {
    return 2;
  }

  uint8_t gray[4] = {};
  const uint32_t add = aether_preclamp_phase_b_replay_add_gray_v1(
      handle, gray, 2, 2, 17, kFrameSha,
      static_cast<uint32_t>(aether_preclamp_instr_v1::FieldStatus::kValid), 2,
      FakeGpuExtract);
  if (add != static_cast<uint32_t>(
                 aether_preclamp_instr_v1::PhaseBReplayDriverStatus::kOk)) {
    aether_preclamp_phase_b_replay_destroy_v1(handle);
    return 3;
  }

  aether_preclamp_phase_b_report_v1 report{};
  const uint32_t seal =
      aether_preclamp_phase_b_replay_seal_v1(handle, &report);
  aether_preclamp_phase_b_replay_destroy_v1(handle);
  if (seal != static_cast<uint32_t>(
                  aether_preclamp_instr_v1::PhaseBReplayDriverStatus::kSealed) ||
      report.accepted_frames != 1 ||
      report.legacy_descriptor_rows_total != 9000 ||
      report.coverage8192_rows_total != 8192 ||
      report.canonical8192_rows_total != 8192 ||
      report.frames_descriptor_gt_8192 != 1 ||
      std::abs(report.coverage_row_headroom - (808.0 / 9000.0)) > 1e-12 ||
      std::abs(report.canonical_row_headroom - (808.0 / 9000.0)) > 1e-12) {
    return 4;
  }

  std::puts("PASS R20 private C bridge seals exact Phase-B report");
  return 0;
}
