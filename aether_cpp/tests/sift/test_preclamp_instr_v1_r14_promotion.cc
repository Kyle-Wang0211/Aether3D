#define AETHER_PRECLAMP_INSTR_ENV_SELFTEST 1
#include "test_preclamp_instr_v1_stage_d_fixture.h"

#include <cassert>
#include <cstdio>

int main() {
  using namespace aether_preclamp_instr_v1;
  using namespace preclamp_stage_d_test;
  const std::vector<BlockPayload> payloads = MakePayloads(2);
  const ArtifactPlan plan = MakePlan(payloads);
  const TransactionFault none = {TransactionFaultPoint::kNone, 0};
  ArtifactWriteStats stats;
  ArtifactValidationReport report;

  TempRoot incomplete("r14-incomplete");
  assert(InitializeStageDArtifact(incomplete.path, plan, &stats) ==
         ArtifactStatus::kOk);
  assert(PromoteStageDArtifact(incomplete.path, plan, none, &stats) ==
         ArtifactStatus::kPromotionNotReady);
  assert(ValidateStageDPromotion(incomplete.path, plan, &report) ==
         ArtifactStatus::kPromotionNotReady);

  TempRoot interrupted("r14-interrupted");
  assert(InitializeStageDArtifact(interrupted.path, plan, &stats) ==
         ArtifactStatus::kOk);
  assert(WriteStageDBatch(interrupted.path, plan, payloads, none, &stats) ==
         ArtifactStatus::kOk);
  const TransactionFault partial_marker = {
      TransactionFaultPoint::kAfterPartialWrite, 0};
  assert(PromoteStageDArtifact(interrupted.path, plan, partial_marker, &stats) ==
         ArtifactStatus::kFaultInjected);
  assert(ValidateStageDPromotion(interrupted.path, plan, &report) ==
         ArtifactStatus::kTempResidue);

  TempRoot promoted("r14-promoted");
  assert(InitializeStageDArtifact(promoted.path, plan, &stats) ==
         ArtifactStatus::kOk);
  assert(WriteStageDBatch(promoted.path, plan, payloads, none, &stats) ==
         ArtifactStatus::kOk);
  assert(PromoteStageDArtifact(promoted.path, plan, none, &stats) ==
         ArtifactStatus::kSuccessFullSequenceLaneQReady);
  assert(ValidateStageDPromotion(promoted.path, plan, &report) ==
         ArtifactStatus::kSuccessFullSequenceLaneQReady);
  assert(report.completed_blocks == plan.blocks.size());

  const std::string marker = Child(promoted.path, kStageDPromotionFilename);
  std::string marker_text = ReadText(marker);
  ReplaceOnce(&marker_text, "SUCCESS_FULL_SEQUENCE_LANE_Q_READY",
              "SUCCESS_FULL_SEQUENCE_LANE_Q_BROKEN");
  WriteText(marker, marker_text);
  assert(ValidateStageDPromotion(promoted.path, plan, &report) ==
         ArtifactStatus::kPromotionMarkerInvalid);

  TempRoot missing("r14-missing");
  assert(InitializeStageDArtifact(missing.path, plan, &stats) ==
         ArtifactStatus::kOk);
  assert(WriteStageDBatch(missing.path, plan, payloads, none, &stats) ==
         ArtifactStatus::kOk);
  assert(std::remove(Child(missing.path, plan.blocks[1].filename).c_str()) == 0);
  assert(PromoteStageDArtifact(missing.path, plan, none, &stats) ==
         ArtifactStatus::kBlockMissing);

  std::puts("PASS R14 only exact complete verified sequence is promoted");
}

