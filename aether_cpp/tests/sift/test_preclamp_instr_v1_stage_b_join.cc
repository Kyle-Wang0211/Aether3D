#define AETHER_PRECLAMP_INSTR_ENV_SELFTEST 1
#define AETHER_PRECLAMP_INSTR_TEST_HOOKS 1
#include "test_preclamp_instr_v1_stage_b_fixture.h"

#include <cassert>
#include <cstdio>

int main() {
  using namespace aether_preclamp_instr_v1;
  using namespace preclamp_stage_b_test;
  StageBParsedJournal journal;
  journal.status = StageBArtifactStatus::kSealed;
  journal.rows.push_back(MakeAccepted(1, 7));
  const std::string prefix =
      "{\"t\":10,\"type\":\"old_event\",\"value\":1}\n";
  const std::string suffix =
      "{\"t\":20,\"type\":\"frame\",\"seq\":1,\"fid\":7,"
      "\"result\":\"ok\",\"extract_ms\":4.5,\"queue\":3}\n"
      "{\"t\":21,\"type\":\"other\",\"note\":\"kept\"}\n"
      "{\"t\":22,\"type\":\"finalize_phase1\",\"iso\":\"worker\","
      "\"result\":\"ok\",\"rc\":0,\"wall_ms\":8}\n";
  const std::string telemetry = prefix + suffix;
  const StageBTelemetryPrefix boundary = {
      static_cast<uint64_t>(prefix.size()), Sha256Hex(Bytes(prefix))};
  StageBJoinResult joined;
  assert(JoinStageBJournalTelemetry(journal, Bytes(telemetry), boundary,
                                    &joined) ==
         StageBJoinStatus::kCountSequenceComplete);
  assert(joined.rows.size() == 1);
  assert(joined.rows[0].queue_backlog_status == FieldStatus::kValid);
  assert(joined.rows[0].queue_backlog == 3);
  std::puts("PASS Stage-B exact telemetry join");
}
