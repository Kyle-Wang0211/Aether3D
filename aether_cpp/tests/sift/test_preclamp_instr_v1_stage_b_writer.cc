#define AETHER_PRECLAMP_INSTR_ENV_SELFTEST 1
#define AETHER_PRECLAMP_INSTR_TEST_HOOKS 1
#include "test_preclamp_instr_v1_stage_b_fixture.h"

#include <cassert>
#include <cstdio>

int main() {
  using namespace aether_preclamp_instr_v1;
  using namespace preclamp_stage_b_test;
  TempHome home("writer-red");
  const std::string run_id = "writer-red";
  ConfigureOn(home, run_id);
  SessionRecords records;
  assert(AppendSessionRecord(&records, MakeAccepted(1, 7)));
  StageBJournalSnapshot snapshot;
  assert(CopyStageBJournalSnapshot(&records, &snapshot));
  assert(snapshot.status == StageBJournalStatus::kReady);
  assert(snapshot.row_attempts == 1 && snapshot.rows_written == 1);
  const std::string expected =
      std::string("STRICT8192_STAGE_B_COUNTS_V1|schema=1|run_id=") + run_id +
      "|source_sha256=" + EmbeddedStageBSourceClosure() + "\n" +
      "frame|ordinal=1|id=7|preclamp=10000|legacy=9000|strict=8192|"
      "overflow=808|descriptor_rows=9000|gpu_ms_status=1|"
      "gpu_ms_bits=3fc00000|thermal_status=1|thermal=2|"
      "backlog_status=2|backlog=0\n";
  assert(ReadText(home.Journal(run_id)) == expected);
  std::puts("PASS Stage-B exact writer");
}
