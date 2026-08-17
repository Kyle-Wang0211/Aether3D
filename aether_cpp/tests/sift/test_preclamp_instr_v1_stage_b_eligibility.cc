#define AETHER_PRECLAMP_INSTR_ENV_SELFTEST 1
#define AETHER_PRECLAMP_INSTR_TEST_HOOKS 1
#include "test_preclamp_instr_v1_stage_b_fixture.h"

#include <cassert>
#include <cstdio>
#include <filesystem>

namespace {

using namespace aether_preclamp_instr_v1;

void AssertDiscarded(PendingDiscardReason reason) {
  ClearPendingAtGpuEntry();
  BeginLegacyClamp(10000);
  UpdateLegacyClampResult(9000);
  DiscardPending(reason);
  FrameCounts row;
  assert(!FinalizeAcceptedFrame(7, 1, FieldStatus::kValid, 2, &row));
}

}  // namespace

int main() {
  using namespace aether_preclamp_instr_v1;
  using namespace preclamp_stage_b_test;

  TempHome home("eligibility");
  ConfigureOn(home, "eligibility");
  SessionRecords records;

  ClearPendingAtGpuEntry();
  BeginLegacyClamp(0);
  UpdateLegacyClampResult(0);
  assert(!SealAcceptedLegacyGpuResult(0, FieldStatus::kUnavailable, 0.0f));
  FrameCounts row;
  assert(!FinalizeAcceptedFrame(1, 1, FieldStatus::kValid, 1, &row));
  AssertDiscarded(PendingDiscardReason::kZeroCandidate);
  AssertDiscarded(PendingDiscardReason::kValidationFailure);
  AssertDiscarded(PendingDiscardReason::kGpuFailureOrFallback);
  AssertDiscarded(PendingDiscardReason::kCanonicalRoute);
  AssertDiscarded(PendingDiscardReason::kSessionRejected);
  AssertDiscarded(PendingDiscardReason::kNonGpuRoute);
  StageBJournalSnapshot snapshot;
  assert(CopyStageBJournalSnapshot(&records, &snapshot));
  assert(snapshot.status == StageBJournalStatus::kOff &&
         snapshot.row_attempts == 0 && snapshot.writer_calls == 0);
  assert(!std::filesystem::exists(home.Journal("eligibility")));

  ClearPendingAtGpuEntry();
  BeginLegacyClamp(10000);
  UpdateLegacyClampResult(9000);
  assert(SealAcceptedLegacyGpuResult(9000, FieldStatus::kValid, 1.5f));
  assert(FinalizeAcceptedFrame(9, 1, FieldStatus::kValid, 2, &row));
  assert(AppendSessionRecord(&records, row));
  assert(CopyStageBJournalSnapshot(&records, &snapshot));
  assert(snapshot.row_attempts == 1 && snapshot.writer_calls == 1 &&
         snapshot.rows_written == 1);

  std::puts("PASS Stage-B writes only accepted legacy-GPU lifecycle rows");
}
