#define AETHER_PRECLAMP_INSTR_ENV_SELFTEST 1
#include "../../official_pipeline/src/official_preclamp_instr_v1.h"

#include <cassert>
#include <cstdio>
#include <vector>

int main() {
  using namespace aether_preclamp_instr_v1;
  DescriptorArmSelections arms{{11, 12}, {12, 99}, {}, false};
  std::vector<CandidateDescriptor> available{{11, {1}}, {12, {2}}, {99, {9}}};
  DescriptorUnionManifest out;
  assert(BuildDescriptorUnion(arms, available, &out) == FixtureStatus::kOk);
  assert(out.descriptors.size() == 3);
  assert(out.descriptors[2].source_candidate_id == 99);
  assert((out.legacy_indices == std::vector<uint32_t>{0, 1}));
  assert((out.canonical8192_indices == std::vector<uint32_t>{1, 2}));
  std::puts("PASS R6 canonical candidate outside legacy is exported");
}
