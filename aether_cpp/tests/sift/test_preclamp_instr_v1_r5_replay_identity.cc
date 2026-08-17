#define AETHER_PRECLAMP_INSTR_ENV_SELFTEST 1
#include "../../official_pipeline/src/official_preclamp_instr_v1.h"

#include <cassert>
#include <cstdio>

int main() {
  using namespace aether_preclamp_instr_v1;
  LegacyReplayIdentity stored{{1, 2, 3, 4}, {9, 8, 7, 6}};
  LegacyReplayIdentity exact = stored;
  assert(ValidateLegacyReplayIdentity(stored, exact) == FixtureStatus::kOk);
  exact.keypoints[2] ^= 1;
  assert(ValidateLegacyReplayIdentity(stored, exact) ==
         FixtureStatus::kLegacyIdentityMismatch);
  exact = stored;
  exact.descriptors.pop_back();
  assert(ValidateLegacyReplayIdentity(stored, exact) ==
         FixtureStatus::kLegacyIdentityMismatch);
  std::puts("PASS R5 legacy replay byte identity fails closed");
}
