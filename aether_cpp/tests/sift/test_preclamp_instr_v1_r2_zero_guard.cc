#define AETHER_PRECLAMP_INSTR_ENV_SELFTEST 1
#include "../../official_pipeline/src/official_preclamp_instr_v1.h"

#include <cassert>
#include <cstdio>

int main() {
  assert(!aether_preclamp_instr_v1::ShouldCreateCandidateGpuBuffer(0));
  assert(aether_preclamp_instr_v1::ShouldCreateCandidateGpuBuffer(1));
  assert(aether_preclamp_instr_v1::ShouldCreateCandidateGpuBuffer(8192));
  std::puts("PASS R2 zero candidate never authorizes a GPU buffer");
}
