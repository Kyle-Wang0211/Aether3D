#define AETHER_PRECLAMP_INSTR_ENV_SELFTEST 1
#include "test_preclamp_instr_v1_stage_d_fixture.h"

#include <cassert>
#include <cstdio>

int main() {
  using namespace aether_preclamp_instr_v1;
  using namespace preclamp_stage_d_test;

  TempRoot root("r13-noncanonical-reproducer");
  const std::vector<BlockPayload> payloads = MakePayloads(1);
  const ArtifactPlan plan = MakePlan(payloads);
  const TransactionFault none = {TransactionFaultPoint::kNone, 0};
  ArtifactWriteStats stats;
  assert(InitializeStageDArtifact(root.path, plan, &stats) ==
         ArtifactStatus::kOk);
  assert(WriteStageDBatch(root.path, plan, payloads, none, &stats) ==
         ArtifactStatus::kOk);

  const std::string manifest = Child(root.path, kStageDManifestFilename);
  std::string text = ReadText(manifest);
  ReplaceOnce(&text, "schema_version=1", "schema_version=01");
  WriteText(manifest, text);

  ArtifactValidationReport report;
  const ArtifactStatus validate = ValidateStageDArtifact(root.path, plan,
                                                          &report);
  const ArtifactStatus promote = PromoteStageDArtifact(root.path, plan, none,
                                                        &stats);
  const ArtifactStatus revalidate = ValidateStageDPromotion(root.path, plan,
                                                             &report);
  std::printf("validate=%u promote=%u revalidate=%u\n",
              static_cast<unsigned>(validate),
              static_cast<unsigned>(promote),
              static_cast<unsigned>(revalidate));
  std::fflush(stdout);

  assert(validate == ArtifactStatus::kManifestMalformed);
  assert(promote == ArtifactStatus::kManifestMalformed);
  assert(revalidate == ArtifactStatus::kManifestMalformed);
  std::puts("PASS R13 noncanonical manifest cannot validate or promote");
}
