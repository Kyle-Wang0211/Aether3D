#define AETHER_PRECLAMP_INSTR_ENV_SELFTEST 1
#include "test_preclamp_instr_v1_stage_d_fixture.h"

#include <cassert>
#include <cstdio>
#include <functional>

namespace {

using namespace aether_preclamp_instr_v1;
using namespace preclamp_stage_d_test;

void Complete(const TempRoot& root, const ArtifactPlan& plan,
              const std::vector<BlockPayload>& payloads) {
  ArtifactWriteStats stats;
  assert(InitializeStageDArtifact(root.path, plan, &stats) ==
         ArtifactStatus::kOk);
  const TransactionFault none = {TransactionFaultPoint::kNone, 0};
  assert(WriteStageDBatch(root.path, plan, payloads, none, &stats) ==
         ArtifactStatus::kOk);
}

ArtifactStatus CorruptManifest(
    const char* label, const ArtifactPlan& plan,
    const std::vector<BlockPayload>& payloads,
    const std::function<void(std::string*)>& mutate) {
  TempRoot root(label);
  Complete(root, plan, payloads);
  const std::string path = Child(root.path, kStageDManifestFilename);
  std::string manifest = ReadText(path);
  mutate(&manifest);
  WriteText(path, manifest);
  ArtifactValidationReport report;
  return ValidateStageDArtifact(root.path, plan, &report);
}

}  // namespace

int main() {
  using namespace aether_preclamp_instr_v1;
  using namespace preclamp_stage_d_test;
  const std::vector<BlockPayload> payloads = MakePayloads(2);
  const ArtifactPlan plan = MakePlan(payloads);

  assert(CorruptManifest("r13-truncated", plan, payloads,
                         [](std::string* text) { text->resize(text->size() / 2); }) ==
         ArtifactStatus::kManifestMalformed);
  assert(CorruptManifest("r13-malformed", plan, payloads,
                         [](std::string* text) { *text = "not-a-manifest\n"; }) ==
         ArtifactStatus::kManifestMalformed);
  assert(CorruptManifest("r13-version", plan, payloads,
                         [](std::string* text) {
                           ReplaceOnce(text, "schema_version=1",
                                       "schema_version=2");
                         }) == ArtifactStatus::kManifestVersionMismatch);
  assert(CorruptManifest("r13-identity", plan, payloads,
                         [](std::string* text) {
                           ReplaceOnce(text, std::string(64, 'a'),
                                       std::string(64, 'd'));
                         }) == ArtifactStatus::kManifestIdentityMismatch);
  assert(CorruptManifest("r13-order", plan, payloads,
                         [](std::string* text) {
                           ReplaceOnce(text, "block=0|100|", "block=1|100|");
                         }) == ArtifactStatus::kBlockOrderMismatch);
  assert(CorruptManifest("r13-size", plan, payloads,
                         [](std::string* text) {
                           ReplaceOnce(text, "block=0|100|block_000.bin|17|",
                                       "block=0|100|block_000.bin|18|");
                         }) == ArtifactStatus::kManifestPlanMismatch);
  assert(CorruptManifest("r13-hash", plan, payloads,
                         [&plan](std::string* text) {
                           ReplaceOnce(text, plan.blocks[0].expected_sha256,
                                       std::string(64, 'e'));
                         }) == ArtifactStatus::kManifestPlanMismatch);
  assert(CorruptManifest("r13-leading-zero-schema", plan, payloads,
                         [](std::string* text) {
                           ReplaceOnce(text, "schema_version=1",
                                       "schema_version=01");
                         }) == ArtifactStatus::kManifestMalformed);
  assert(CorruptManifest("r13-leading-zero-count", plan, payloads,
                         [](std::string* text) {
                           ReplaceOnce(text, "block_count=2",
                                       "block_count=02");
                         }) == ArtifactStatus::kManifestMalformed);
  assert(CorruptManifest("r13-leading-zero-ordinal", plan, payloads,
                         [](std::string* text) {
                           ReplaceOnce(text, "block=0|100|",
                                       "block=00|100|");
                         }) == ArtifactStatus::kManifestMalformed);
  assert(CorruptManifest("r13-leading-zero-id", plan, payloads,
                         [](std::string* text) {
                           ReplaceOnce(text, "block=0|100|",
                                       "block=0|0100|");
                         }) == ArtifactStatus::kManifestMalformed);
  assert(CorruptManifest("r13-leading-zero-size", plan, payloads,
                         [](std::string* text) {
                           ReplaceOnce(text, "block_000.bin|17|",
                                       "block_000.bin|017|");
                         }) == ArtifactStatus::kManifestMalformed);
  assert(CorruptManifest("r13-crlf", plan, payloads,
                         [](std::string* text) {
                           ReplaceOnce(text, "\n", "\r\n");
                         }) == ArtifactStatus::kManifestMalformed);
  assert(CorruptManifest("r13-extra-newline", plan, payloads,
                         [](std::string* text) { text->append("\n"); }) ==
         ArtifactStatus::kManifestMalformed);
  assert(CorruptManifest("r13-missing-newline", plan, payloads,
                         [](std::string* text) { text->pop_back(); }) ==
         ArtifactStatus::kManifestMalformed);
  assert(CorruptManifest("r13-unknown-bytes", plan, payloads,
                         [](std::string* text) {
                           text->append("unknown=1\n");
                         }) == ArtifactStatus::kManifestMalformed);

  TempRoot noncanonical_promotion("r13-noncanonical-promotion");
  Complete(noncanonical_promotion, plan, payloads);
  const std::string noncanonical_manifest =
      Child(noncanonical_promotion.path, kStageDManifestFilename);
  std::string noncanonical_text = ReadText(noncanonical_manifest);
  ReplaceOnce(&noncanonical_text, "schema_version=1", "schema_version=01");
  WriteText(noncanonical_manifest, noncanonical_text);
  ArtifactWriteStats promotion_stats;
  const TransactionFault none = {TransactionFaultPoint::kNone, 0};
  assert(PromoteStageDArtifact(noncanonical_promotion.path, plan, none,
                               &promotion_stats) ==
         ArtifactStatus::kManifestMalformed);
  ArtifactValidationReport noncanonical_report;
  assert(ValidateStageDPromotion(noncanonical_promotion.path, plan,
                                 &noncanonical_report) ==
         ArtifactStatus::kManifestMalformed);

  TempRoot changed("r13-block-hash");
  Complete(changed, plan, payloads);
  const std::string block = Child(changed.path, plan.blocks[0].filename);
  std::vector<uint8_t> changed_bytes = ReadBytes(block);
  changed_bytes[0] ^= 0xffu;
  WriteText(block, std::string(changed_bytes.begin(), changed_bytes.end()));
  ArtifactValidationReport report;
  assert(ValidateStageDArtifact(changed.path, plan, &report) ==
         ArtifactStatus::kBlockHashMismatch);

  TempRoot truncated("r13-block-size");
  Complete(truncated, plan, payloads);
  WriteText(Child(truncated.path, plan.blocks[0].filename), "x");
  assert(ValidateStageDArtifact(truncated.path, plan, &report) ==
         ArtifactStatus::kBlockSizeMismatch);

  std::puts("PASS R13 manifest/block corruption fails closed");
}
