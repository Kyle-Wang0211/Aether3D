#define AETHER_PRECLAMP_INSTR_ENV_SELFTEST 1
#define AETHER_PRECLAMP_INSTR_TEST_HOOKS 1
#include "test_preclamp_instr_v1_stage_b_fixture.h"

#include <cassert>
#include <cstdio>

int main() {
  using namespace aether_preclamp_instr_v1;
  using namespace preclamp_stage_b_test;
  TempHome home("seal-red");
  const std::string run_id = "seal-red";
  ConfigureOn(home, run_id);
  SessionRecords records;
  assert(AppendSessionRecord(&records, MakeAccepted(1, 7)));
  assert(SealStageBJournal(&records));
  StageBParsedJournal parsed;
  assert(ParseStageBJournal(Bytes(ReadText(home.Journal(run_id))), run_id,
                            EmbeddedStageBSourceClosure(), &parsed) ==
         StageBArtifactStatus::kSealed);
  assert(parsed.rows.size() == 1);
  StageBJournalSnapshot snapshot;
  assert(CopyStageBJournalSnapshot(&records, &snapshot));
  assert(snapshot.status == StageBJournalStatus::kSealed);
  std::puts("PASS Stage-B terminal seal");
}
