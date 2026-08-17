#define AETHER_PRECLAMP_INSTR_ENV_SELFTEST 1
#include "../../official_pipeline/src/official_preclamp_replay_driver_v1.h"
#include "test_preclamp_instr_v1_stage_b_fixture.h"

#include <cassert>
#include <cstdio>

namespace {

int g_extract_calls = 0;

int FakeGpuExtract(const uint8_t* gray, int width, int height,
                   int max_features, int num_threads, float* out_xy,
                   uint8_t* out_desc, int out_cap, int* out_count) {
  using namespace aether_preclamp_instr_v1;
  ++g_extract_calls;
  assert(gray != nullptr);
  assert(width == 4 && height == 3);
  assert(max_features == 8192);
  assert(num_threads == 0);
  assert(out_xy != nullptr && out_desc != nullptr);
  assert(out_cap == 8192 && out_count != nullptr);
  ClearPendingAtGpuEntry();
  BeginLegacyClamp(10000);
  UpdateLegacyClampResult(9000);
  assert(SealAcceptedLegacyGpuResult(9000, FieldStatus::kValid, 2.0f));
  *out_count = 8192;
  return 0;
}

int FakeFallback(const uint8_t*, int, int, int, int, float*, uint8_t*, int,
                 int* out_count) {
  using namespace aether_preclamp_instr_v1;
  ++g_extract_calls;
  ClearPendingAtGpuEntry();
  DiscardPending(PendingDiscardReason::kGpuFailureOrFallback);
  *out_count = 8192;
  return 0;
}

}  // namespace

int main() {
  using namespace aether_preclamp_instr_v1;
  using namespace preclamp_stage_b_test;

  TempHome home("replay-driver-on");
  ConfigureOn(home, "replay-driver-on");

  PhaseBReplayDriverV1 driver;
  const std::string manifest_sha(64, 'a');
  const std::string frame_sha(64, 'b');
  const PhaseBReplayPlanV1 plan{
      manifest_sha, {{41, frame_sha}}};
  assert(driver.Initialize(plan) == PhaseBReplayDriverStatus::kOk);
  const uint8_t gray[12] = {};
  assert(driver.AddGrayFrame(gray, 4, 3, 41, frame_sha,
                             FieldStatus::kValid, 2,
                             &FakeGpuExtract) ==
         PhaseBReplayDriverStatus::kOk);
  assert(g_extract_calls == 1);

  PhaseBHeadroomReport report;
  assert(driver.Seal(&report) == PhaseBReplayDriverStatus::kSealed);
  assert(report.accepted_frames == 1);
  assert(report.legacy_descriptor_rows_total == 9000);
  assert(report.coverage8192_rows_total == 8192);
  assert(report.frames_descriptor_gt_8192 == 1);

  StageBParsedJournal parsed;
  const auto text = ReadText(home.Journal("replay-driver-on"));
  assert(ParseStageBJournal(Bytes(text), "replay-driver-on",
                            EmbeddedStageBSourceClosure(), &parsed) ==
         StageBArtifactStatus::kSealed);
  assert(parsed.rows.size() == 1);
  assert(parsed.rows[0].frame_id == 41);

  PhaseBReplayDriverV1 identity_reject;
  assert(identity_reject.Initialize(plan) == PhaseBReplayDriverStatus::kOk);
  assert(identity_reject.AddGrayFrame(gray, 4, 3, 42, frame_sha,
                                      FieldStatus::kValid, 2,
                                      &FakeGpuExtract) ==
         PhaseBReplayDriverStatus::kInputIdentityMismatch);
  assert(g_extract_calls == 1);

  PhaseBReplayDriverV1 fallback;
  const PhaseBReplayPlanV1 fallback_plan{
      std::string(64, 'c'), {{51, std::string(64, 'd')}}};
  assert(fallback.Initialize(fallback_plan) ==
         PhaseBReplayDriverStatus::kOk);
  assert(fallback.AddGrayFrame(gray, 4, 3, 51, std::string(64, 'd'),
                               FieldStatus::kValid, 2, &FakeFallback) ==
         PhaseBReplayDriverStatus::kExtractorFallbackOrUninstrumented);
  assert(g_extract_calls == 2);
  std::puts("PASS R20 count-only driver seals one exact Stage-B row");
}
