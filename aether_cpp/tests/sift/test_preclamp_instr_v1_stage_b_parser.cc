#define AETHER_PRECLAMP_INSTR_ENV_SELFTEST 1
#define AETHER_PRECLAMP_INSTR_TEST_HOOKS 1
#include "test_preclamp_instr_v1_stage_b_fixture.h"

#include <cassert>
#include <cstdio>

int main() {
  using namespace aether_preclamp_instr_v1;
  using namespace preclamp_stage_b_test;
  const std::string run_id = "parser-red";
  const std::string prefix =
      std::string("STRICT8192_STAGE_B_COUNTS_V1|schema=1|run_id=") + run_id +
      "|source_sha256=" + EmbeddedStageBSourceClosure() + "\n" +
      "frame|ordinal=1|id=7|preclamp=10000|legacy=9000|strict=8192|"
      "overflow=808|descriptor_rows=9000|gpu_ms_status=1|"
      "gpu_ms_bits=3fc00000|thermal_status=1|thermal=2|"
      "backlog_status=2|backlog=0\n";
  StageBParsedJournal parsed;
  assert(ParseStageBJournal(Bytes(prefix), run_id,
                            EmbeddedStageBSourceClosure(), &parsed) ==
         StageBArtifactStatus::kIncomplete);
  assert(parsed.complete_prefix_rows == 1);
  assert(parsed.rows.size() == 1 && parsed.rows[0].frame_id == 7);
  std::puts("PASS Stage-B parser prefix diagnostics");
}
