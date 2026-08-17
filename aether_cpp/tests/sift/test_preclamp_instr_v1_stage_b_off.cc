#define AETHER_PRECLAMP_INSTR_ENV_SELFTEST 1
#define AETHER_PRECLAMP_INSTR_TEST_HOOKS 1
#include "test_preclamp_instr_v1_stage_b_fixture.h"

#include <cassert>
#include <cstdio>
#include <filesystem>

int main() {
  using namespace aether_preclamp_instr_v1;
  using namespace preclamp_stage_b_test;
  TempHome home("off");
  assert(::setenv("HOME", home.path.c_str(), 1) == 0);
  ::unsetenv("AETHER_PRECLAMP_INSTR_V1");
  ::unsetenv("AETHER_PRECLAMP_RUN_ID_V1");
  ::unsetenv("AETHER_PRECLAMP_SOURCE_SHA256_V1");
  SessionRecords records;
  assert(!AppendSessionRecord(&records, MakeAccepted(1, 7)));
  assert(!SealStageBJournal(&records));
  StageBJournalSnapshot snapshot;
  assert(CopyStageBJournalSnapshot(&records, &snapshot));
  assert(snapshot.status == StageBJournalStatus::kOff);
  assert(snapshot.row_attempts == 0 && snapshot.writer_calls == 0);
  assert(records.accepted_rows.empty());
  assert(!std::filesystem::exists(
      home.path + "/Library/Application Support/AetherDiagnostics"));
  std::puts("PASS Stage-B OFF performs no writer or filesystem action");
}
