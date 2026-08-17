#define AETHER_PRECLAMP_INSTR_ENV_SELFTEST 1
#include "../../official_pipeline/src/official_preclamp_instr_v1.h"

#include <cassert>
#include <cstdint>
#include <cstdio>
#include <limits>

int main() {
  using namespace aether_preclamp_instr_v1;

  const CapacityGateResult unknown = CheckStageDCapacity(999, 0);
  assert(unknown.status == ArtifactStatus::kWorstCaseUnknown);

  const CapacityGateResult below = CheckStageDCapacity(1499, 1000);
  assert(below.status == ArtifactStatus::kInsufficientCapacity);
  assert(below.required_bytes == 1500);

  const CapacityGateResult boundary = CheckStageDCapacity(1500, 1000);
  assert(boundary.status == ArtifactStatus::kOk);
  assert(boundary.required_bytes == 1500);

  const CapacityGateResult odd = CheckStageDCapacity(5, 3);
  assert(odd.status == ArtifactStatus::kOk);
  assert(odd.required_bytes == 5);

  const uint64_t maximum = std::numeric_limits<uint64_t>::max();
  const CapacityGateResult overflow = CheckStageDCapacity(maximum, maximum);
  assert(overflow.status == ArtifactStatus::kCapacityArithmeticOverflow);
  assert(overflow.required_bytes == 0);

  std::puts("PASS R10 overflow-safe 1.5x capacity gate");
}

