#define AETHER_PRECLAMP_INSTR_ENV_SELFTEST 1
#include "../../official_pipeline/src/official_preclamp_instr_v1.h"

#include <cassert>
#include <cstdio>
#include <vector>

int main() {
  using namespace aether_preclamp_instr_v1;
  DescriptorArmSelections arms{{1}, {2}, {}, false};
  std::vector<CandidateDescriptor> available{{1, {7}}};
  DescriptorUnionManifest out;
  out.descriptors.push_back({999, {1}});
  assert(BuildDescriptorUnion(arms, available, &out) ==
         FixtureStatus::kMissingDescriptor);
  assert(out.descriptors.empty());

  available.push_back({2, {}});  // a record without bytes is still missing
  assert(BuildDescriptorUnion(arms, available, &out) ==
         FixtureStatus::kMissingDescriptor);
  std::puts("PASS R9 missing selected descriptor fails closed");
}
