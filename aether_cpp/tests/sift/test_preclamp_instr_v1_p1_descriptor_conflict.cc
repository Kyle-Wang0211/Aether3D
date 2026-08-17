#define AETHER_PRECLAMP_INSTR_ENV_SELFTEST 1
#include "../../official_pipeline/src/official_preclamp_instr_v1.h"

#include <cassert>
#include <cstdio>
#include <vector>

int main() {
  using namespace aether_preclamp_instr_v1;
  DescriptorArmSelections arms{{8}, {8}, {}, false};
  std::vector<CandidateDescriptor> available{{8, {1, 2}}, {8, {1, 3}}};
  DescriptorUnionManifest out;
  out.descriptors.push_back({99, {9}});
  out.legacy_indices.push_back(9);
  assert(BuildDescriptorUnion(arms, available, &out) ==
         FixtureStatus::kConflictingDescriptor);
  assert(out.descriptors.empty());
  assert(out.legacy_indices.empty());
  assert(out.canonical8192_indices.empty());
  assert(out.canonical12288_indices.empty());
  std::puts("PASS conflicting duplicate descriptor fails closed");
}
