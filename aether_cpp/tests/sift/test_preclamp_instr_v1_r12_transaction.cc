#define AETHER_PRECLAMP_INSTR_ENV_SELFTEST 1
#include "test_preclamp_instr_v1_stage_d_fixture.h"

#include <cassert>
#include <cstdio>

int main() {
  using namespace aether_preclamp_instr_v1;
  using namespace preclamp_stage_d_test;
  const TransactionFault none = {TransactionFaultPoint::kNone, 0};

  TempRoot success_root("r12-success");
  TransactionTrace trace;
  const std::vector<uint8_t> bytes = {1, 2, 3, 4, 5};
  assert(WriteFileTransactional(success_root.path, "probe.bin", bytes, none,
                                &trace) == ArtifactStatus::kOk);
  const std::vector<TransactionStep> expected = {
      TransactionStep::kTempCreated, TransactionStep::kFullWrite,
      TransactionStep::kFileFsync, TransactionStep::kFileClosed,
      TransactionStep::kAtomicRename, TransactionStep::kParentDirectoryFsync};
  assert(trace.steps == expected);
  assert(ReadBytes(Child(success_root.path, "probe.bin")) == bytes);
  assert(WriteFileTransactional(success_root.path, "../escape", bytes, none,
                                &trace) == ArtifactStatus::kPathViolation);

  TempRoot partial_root("r12-partial");
  const std::vector<BlockPayload> payloads = MakePayloads(1);
  const ArtifactPlan plan = MakePlan(payloads);
  ArtifactWriteStats stats;
  assert(InitializeStageDArtifact(partial_root.path, plan, &stats) ==
         ArtifactStatus::kOk);
  const TransactionFault partial = {
      TransactionFaultPoint::kAfterPartialWrite, plan.blocks[0].block_id};
  assert(WriteStageDBatch(partial_root.path, plan, payloads, partial, &stats) ==
         ArtifactStatus::kFaultInjected);
  ArtifactValidationReport report;
  assert(ValidateStageDArtifact(partial_root.path, plan, &report) ==
         ArtifactStatus::kTempResidue);

  TempRoot unexpected_root("r12-unexpected");
  assert(InitializeStageDArtifact(unexpected_root.path, plan, &stats) ==
         ArtifactStatus::kOk);
  WriteText(Child(unexpected_root.path, "rogue.bin"), "rogue");
  assert(ValidateStageDArtifact(unexpected_root.path, plan, &report) ==
         ArtifactStatus::kUnexpectedFile);

  TempRoot cross_root("r12-cross");
  assert(InitializeStageDArtifact(cross_root.path, plan, &stats) ==
         ArtifactStatus::kOk);
  const TransactionFault cross = {
      TransactionFaultPoint::kSimulateCrossDeviceRename,
      plan.blocks[0].block_id};
  assert(WriteStageDBatch(cross_root.path, plan, payloads, cross, &stats) ==
         ArtifactStatus::kCrossDeviceRename);
  assert(ValidateStageDArtifact(cross_root.path, plan, &report) ==
         ArtifactStatus::kTempResidue);

  TempRoot symlink_parent("r12-symlink");
  const std::string real = Child(symlink_parent.path, "real");
  const std::string linked = Child(symlink_parent.path, "linked");
  assert(::mkdir(real.c_str(), 0700) == 0);
  assert(::symlink(real.c_str(), linked.c_str()) == 0);
  assert(InitializeStageDArtifact(linked, plan, &stats) ==
         ArtifactStatus::kSymlinkRejected);

  std::puts("PASS R12 transactional order and residue/path fail-closed gates");
}

