#define AETHER_PRECLAMP_INSTR_ENV_SELFTEST 1
#include "test_preclamp_instr_v1_stage_d_fixture.h"

#include <cassert>
#include <cstdio>

int main() {
  using namespace aether_preclamp_instr_v1;
  using namespace preclamp_stage_d_test;

  TempRoot root("r11");
  const std::vector<BlockPayload> payloads = MakePayloads(3);
  const ArtifactPlan plan = MakePlan(payloads);
  ArtifactWriteStats init_stats;
  assert(InitializeStageDArtifact(root.path, plan, &init_stats) ==
         ArtifactStatus::kOk);
  assert(init_stats.manifest_writes == 1);

  ArtifactWriteStats crash_stats;
  const TransactionFault crash = {
      TransactionFaultPoint::kAfterManifestCommit, plan.blocks[1].block_id};
  assert(WriteStageDBatch(root.path, plan, payloads, crash, &crash_stats) ==
         ArtifactStatus::kFaultInjected);
  assert(crash_stats.block_file_writes == 2);
  assert(crash_stats.manifest_writes == 2);

  const FileSnapshot first_before =
      Snapshot(Child(root.path, plan.blocks[0].filename));
  const FileSnapshot second_before =
      Snapshot(Child(root.path, plan.blocks[1].filename));

  ArtifactWriteStats resume_stats;
  const TransactionFault none = {TransactionFaultPoint::kNone, 0};
  assert(WriteStageDBatch(root.path, plan, payloads, none, &resume_stats) ==
         ArtifactStatus::kOk);
  assert(resume_stats.skipped_verified_blocks == 2);
  assert(resume_stats.block_file_writes == 1);
  assert(resume_stats.manifest_writes == 1);
  assert(SameSnapshot(first_before,
                      Snapshot(Child(root.path, plan.blocks[0].filename))));
  assert(SameSnapshot(second_before,
                      Snapshot(Child(root.path, plan.blocks[1].filename))));

  ArtifactValidationReport report;
  assert(ValidateStageDArtifact(root.path, plan, &report) ==
         ArtifactStatus::kOk);
  assert(report.completed_blocks == 3);

  ArtifactPlan duplicate = plan;
  duplicate.blocks[2].block_id = duplicate.blocks[1].block_id;
  assert(ValidateStageDArtifact(root.path, duplicate, &report) ==
         ArtifactStatus::kDuplicateBlockId);

  ArtifactPlan wrong_identity = plan;
  wrong_identity.identity.config_sha256 = std::string(64, 'd');
  assert(ValidateStageDArtifact(root.path, wrong_identity, &report) ==
         ArtifactStatus::kManifestIdentityMismatch);

  std::puts("PASS R11 crash-resume verifies and never rewrites completed blocks");
}

