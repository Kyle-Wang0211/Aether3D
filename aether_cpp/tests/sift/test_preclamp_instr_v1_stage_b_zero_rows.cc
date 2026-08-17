#define AETHER_PRECLAMP_INSTR_ENV_SELFTEST 1
#define AETHER_PRECLAMP_INSTR_TEST_HOOKS 1
#include "test_preclamp_instr_v1_stage_b_fixture.h"

#include <cassert>
#include <cstdio>

int main() {
  using namespace aether_preclamp_instr_v1;
  using namespace preclamp_stage_b_test;

  TempHome home("zero-rows");
  ConfigureOn(home, "zero-rows");
  SessionRecords records;
  assert(!SealStageBJournal(&records));
  StageBJournalSnapshot snapshot;
  assert(CopyStageBJournalSnapshot(&records, &snapshot));
  assert(snapshot.status == StageBJournalStatus::kFailed);
  assert(snapshot.first_failure == StageBFailureReason::kRowInvariant);

  const std::string header =
      "STRICT8192_STAGE_B_COUNTS_V1|schema=1|run_id=zero-rows"
      "|source_sha256=" +
      std::string(EmbeddedStageBSourceClosure()) + "\n";
  const std::string crafted =
      header + "seal|rows=0|last_ordinal=0|journal_sha256=" +
      Sha256Hex(Bytes(header)) + "\n";
  StageBParsedJournal parsed;
  assert(ParseStageBJournal(Bytes(crafted), "zero-rows",
                            EmbeddedStageBSourceClosure(), &parsed) !=
         StageBArtifactStatus::kSealed);

  StageBParsedJournal empty;
  empty.status = StageBArtifactStatus::kSealed;
  const std::string finalize =
      "{\"t\":1,\"type\":\"finalize_phase1\",\"iso\":\"worker\","
      "\"result\":\"ok\",\"rc\":0,\"wall_ms\":5}\n";
  const StageBTelemetryPrefix boundary = {0, Sha256Hex(Bytes(""))};
  StageBJoinResult joined;
  assert(JoinStageBJournalTelemetry(empty, Bytes(finalize), boundary,
                                    &joined) == StageBJoinStatus::kInvalid);
  assert(joined.rows.empty());

  std::puts("PASS Stage-B zero-row writer/parser/join promotion is rejected");
}
