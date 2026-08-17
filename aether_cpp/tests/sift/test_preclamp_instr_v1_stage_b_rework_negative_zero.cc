#define AETHER_PRECLAMP_INSTR_ENV_SELFTEST 1
#define AETHER_PRECLAMP_INSTR_TEST_HOOKS 1
#include "test_preclamp_instr_v1_stage_b_fixture.h"

#include <cassert>
#include <cstdio>
#include <string>

int main() {
  using namespace aether_preclamp_instr_v1;
  using namespace preclamp_stage_b_test;

  TempHome home("rework-negative-zero");
  ConfigureOn(home, "rework-negative-zero");

  ClearPendingAtGpuEntry();
  BeginLegacyClamp(10000);
  UpdateLegacyClampResult(9000);
  assert(!SealAcceptedLegacyGpuResult(9000, FieldStatus::kUnavailable,
                                      -0.0f));

  SessionRecords records;
  FrameCounts negative_zero = MakeAccepted(1, 7);
  negative_zero.gpu_ms_status = FieldStatus::kUnavailable;
  negative_zero.gpu_ms = -0.0f;
  assert(AppendSessionRecord(&records, negative_zero));
  StageBJournalSnapshot snapshot;
  assert(CopyStageBJournalSnapshot(&records, &snapshot));
  assert(snapshot.status == StageBJournalStatus::kFailed);
  assert(snapshot.first_failure == StageBFailureReason::kRowInvariant);
  assert(snapshot.rows_written == 0);

  const std::string run_id = "rework-negative-zero-parser";
  const std::string header =
      "STRICT8192_STAGE_B_COUNTS_V1|schema=1|run_id=" + run_id +
      "|source_sha256=" + EmbeddedStageBSourceClosure() + "\n";
  const std::string row =
      "frame|ordinal=1|id=7|preclamp=10000|legacy=9000|strict=8192"
      "|overflow=808|descriptor_rows=9000|gpu_ms_status=0"
      "|gpu_ms_bits=80000000|thermal_status=1|thermal=2"
      "|backlog_status=2|backlog=0\n";
  const std::string prefix = header + row;
  const std::string artifact =
      prefix + "seal|rows=1|last_ordinal=1|journal_sha256=" +
      Sha256Hex(Bytes(prefix)) + "\n";
  StageBParsedJournal parsed;
  assert(ParseStageBJournal(Bytes(artifact), run_id,
                            EmbeddedStageBSourceClosure(), &parsed) !=
         StageBArtifactStatus::kSealed);

  std::puts("PASS Stage-B unavailable GPU time accepts only +0 bit pattern");
}
