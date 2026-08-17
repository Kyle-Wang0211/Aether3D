#define AETHER_PRECLAMP_INSTR_ENV_SELFTEST 1
#define AETHER_PRECLAMP_INSTR_TEST_HOOKS 1
#include "test_preclamp_instr_v1_stage_b_fixture.h"

#include <cassert>
#include <cstdio>
#include <string>

namespace {

using namespace aether_preclamp_instr_v1;
using namespace preclamp_stage_b_test;

const std::string kPrefix =
    "{\"t\":10,\"type\":\"old_event\",\"value\":1}\n";

StageBParsedJournal Journal() {
  StageBParsedJournal journal;
  journal.status = StageBArtifactStatus::kSealed;
  journal.rows.push_back(MakeAccepted(1, 7));
  journal.rows.push_back(MakeAccepted(2, 8));
  return journal;
}

std::string Frame(uint32_t seq, int64_t fid, const std::string& result,
                  const std::string& queue) {
  return "{\"t\":20,\"type\":\"frame\",\"seq\":" +
         std::to_string(seq) + ",\"fid\":" + std::to_string(fid) +
         ",\"result\":\"" + result +
         "\",\"extract_ms\":4.5,\"optional\":{\"x\":[1,true,null]},"
         "\"queue\":" +
         queue + "}\n";
}

std::string Finalize() {
  return "{\"t\":22,\"type\":\"finalize_phase1\",\"iso\":\"worker\","
         "\"result\":\"ok\",\"rc\":0,\"wall_ms\":8,"
         "\"optional\":false}\n";
}

StageBTelemetryPrefix Boundary(const std::string& prefix = kPrefix) {
  return {static_cast<uint64_t>(prefix.size()), Sha256Hex(Bytes(prefix))};
}

void AssertInvalid(const std::string& suffix,
                   const std::string& prefix = kPrefix,
                   const StageBTelemetryPrefix* boundary_override = nullptr) {
  const StageBTelemetryPrefix boundary =
      boundary_override == nullptr ? Boundary(prefix) : *boundary_override;
  StageBJoinResult joined;
  assert(JoinStageBJournalTelemetry(Journal(), Bytes(prefix + suffix), boundary,
                                    &joined) == StageBJoinStatus::kInvalid);
  assert(joined.rows.empty());
}

}  // namespace

int main() {
  using namespace aether_preclamp_instr_v1;
  using namespace preclamp_stage_b_test;

  const std::string valid =
      Frame(1, 7, "ok", "3") +
      "{\"t\":21,\"type\":\"other\",\"note\":\"kept\"}\n" +
      Frame(2, 8, "ok", "0") + Finalize();
  StageBJoinResult joined;
  assert(JoinStageBJournalTelemetry(Journal(), Bytes(kPrefix + valid),
                                    Boundary(), &joined) ==
         StageBJoinStatus::kCountSequenceComplete);
  assert(joined.rows.size() == 2 && joined.rows[0].queue_backlog == 3 &&
         joined.rows[1].queue_backlog == 0);

  const std::string empty_prefix;
  const StageBTelemetryPrefix empty_boundary = {0, Sha256Hex(Bytes(""))};
  assert(JoinStageBJournalTelemetry(Journal(), Bytes(valid), empty_boundary,
                                    &joined) ==
         StageBJoinStatus::kCountSequenceComplete);

  StageBTelemetryPrefix wrong_hash = Boundary();
  wrong_hash.sha256 = std::string(64, '0');
  AssertInvalid(valid, kPrefix, &wrong_hash);
  StageBTelemetryPrefix beyond = Boundary();
  beyond.byte_length = 999999;
  AssertInvalid(valid, kPrefix, &beyond);
  const std::string drifted_prefix =
      "{\"t\":10,\"type\":\"old_event\",\"value\":2}\n";
  const StageBTelemetryPrefix frozen_original = Boundary();
  AssertInvalid(valid, drifted_prefix, &frozen_original);
  const std::string nonterminated_prefix = "{\"t\":10,\"type\":\"old\"}";
  const StageBTelemetryPrefix nonterminated_boundary =
      Boundary(nonterminated_prefix);
  AssertInvalid(valid, nonterminated_prefix, &nonterminated_boundary);

  std::string no_final_lf = valid;
  no_final_lf.pop_back();
  AssertInvalid(no_final_lf);
  AssertInvalid("");
  AssertInvalid(Frame(1, 7, "ok", "3") + Finalize());
  AssertInvalid(Frame(1, 7, "ok", "3") + Frame(1, 7, "ok", "3") +
                Frame(2, 8, "ok", "0") + Finalize());
  AssertInvalid(Frame(1, 7, "ok", "3") + Frame(2, 8, "ok", "0") +
                Frame(3, 9, "ok", "0") + Finalize());
  AssertInvalid(Frame(1, 7, "failed", "3") +
                Frame(2, 8, "ok", "0") + Finalize());
  AssertInvalid(Frame(1, 7, "ok", "3") + Frame(2, 9, "ok", "0") +
                Finalize());
  AssertInvalid(Frame(2, 8, "ok", "0") + Frame(1, 7, "ok", "3") +
                Finalize());
  AssertInvalid(Frame(1, 8, "ok", "3") + Frame(2, 7, "ok", "0") +
                Finalize());
  AssertInvalid(Frame(1, 7, "ok", "4294967296") +
                Frame(2, 8, "ok", "0") + Finalize());
  AssertInvalid(Frame(1, 7, "ok", "-1") + Frame(2, 8, "ok", "0") +
                Finalize());
  AssertInvalid("{\"t\":20,\"type\":\"frame\",\"seq\":1,\"fid\":7,"
                "\"result\":\"ok\"}\n" +
                Frame(2, 8, "ok", "0") + Finalize());
  AssertInvalid("{\"t\":20,\"type\":\"frame\",\"seq\":1,\"seq\":1,"
                "\"fid\":7,\"result\":\"ok\",\"queue\":0}\n" +
                Frame(2, 8, "ok", "0") + Finalize());
  AssertInvalid("{\"t\":20,\"type\":\"frame\",\"seq\":1,\"fid\":7,"
                "\"result\":\"ok\",\"queue\":0\n" +
                Frame(2, 8, "ok", "0") + Finalize());
  AssertInvalid("{\"t\":20,\"type\":\"frame\",\"event\":\"frame\","
                "\"ordinal\":1,\"frame_id\":7,\"queue\":0}\n" +
                Frame(2, 8, "ok", "0") + Finalize());

  AssertInvalid(Frame(1, 7, "ok", "3") + Frame(2, 8, "ok", "0"));
  AssertInvalid(Frame(1, 7, "ok", "3") + Frame(2, 8, "ok", "0") +
                "{\"t\":22,\"type\":\"complete\",\"result\":\"ok\"}\n");
  AssertInvalid(Frame(1, 7, "ok", "3") + Frame(2, 8, "ok", "0") +
                "{\"t\":22,\"type\":\"finalize_wall\",\"ms\":8,"
                "\"phase\":\"local_ready\"}\n");
  AssertInvalid(Frame(1, 7, "ok", "3") + Frame(2, 8, "ok", "0") +
                Finalize() + Finalize());
  AssertInvalid(Frame(1, 7, "ok", "3") + Frame(2, 8, "ok", "0") +
                Finalize() + Frame(3, 9, "ok", "0"));
  AssertInvalid(Frame(1, 7, "ok", "3") + Frame(2, 8, "ok", "0") +
                "{\"t\":22,\"type\":\"finalize_phase1\","
                "\"iso\":\"main\",\"result\":\"ok\",\"rc\":0,"
                "\"wall_ms\":8}\n");
  AssertInvalid(Frame(1, 7, "ok", "3") + Frame(2, 8, "ok", "0") +
                "{\"t\":22,\"type\":\"finalize_phase1\","
                "\"iso\":\"worker\",\"result\":\"failed\",\"rc\":0,"
                "\"wall_ms\":8}\n");
  AssertInvalid(Frame(1, 7, "ok", "3") + Frame(2, 8, "ok", "0") +
                "{\"t\":22,\"type\":\"finalize_phase1\","
                "\"iso\":\"worker\",\"result\":\"ok\",\"rc\":1,"
                "\"wall_ms\":8}\n");
  AssertInvalid(Frame(1, 7, "ok", "3") + Frame(2, 8, "ok", "0") +
                "{\"t\":22,\"type\":\"finalize_phase1\","
                "\"iso\":\"worker\",\"result\":\"ok\",\"rc\":0,"
                "\"wall_ms\":-1}\n");

  StageBParsedJournal incomplete = Journal();
  incomplete.status = StageBArtifactStatus::kIncomplete;
  assert(JoinStageBJournalTelemetry(incomplete, Bytes(kPrefix + valid),
                                    Boundary(), &joined) ==
         StageBJoinStatus::kInvalid);

  std::puts("PASS Stage-B telemetry join rejects boundary drift, malformed, "
            "missing, duplicate, extra, failed, order, and closure errors");
}
