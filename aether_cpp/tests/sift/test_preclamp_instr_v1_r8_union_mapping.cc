#define AETHER_PRECLAMP_INSTR_ENV_SELFTEST 1
#include "../../official_pipeline/src/official_preclamp_instr_v1.h"

#include <cassert>
#include <cstdio>
#include <vector>

int main() {
  using namespace aether_preclamp_instr_v1;
  DescriptorArmSelections arms{{4, 8}, {8, 15}, {15, 16, 4}, true};
  std::vector<CandidateDescriptor> available{
      {16, {16}}, {4, {4}}, {15, {15}}, {8, {8}}};
  DescriptorUnionManifest out;
  assert(BuildDescriptorUnion(arms, available, &out) == FixtureStatus::kOk);
  assert(out.descriptors.size() == 4);
  assert((out.legacy_indices == std::vector<uint32_t>{0, 1}));
  assert((out.canonical8192_indices == std::vector<uint32_t>{1, 2}));
  assert((out.canonical12288_indices == std::vector<uint32_t>{2, 3, 0}));
  assert(out.descriptors[0].source_candidate_id == 4);
  assert(out.descriptors[1].source_candidate_id == 8);
  assert(out.descriptors[2].source_candidate_id == 15);
  assert(out.descriptors[3].source_candidate_id == 16);

  arms.retain_canonical12288 = false;
  assert(BuildDescriptorUnion(arms, available, &out) == FixtureStatus::kOk);
  assert(out.descriptors.size() == 3);
  assert(out.canonical12288_indices.empty());
  std::puts("PASS R8 descriptor union dedupe and per-arm mappings");
}
