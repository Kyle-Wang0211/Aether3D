#define AETHER_PRECLAMP_INSTR_ENV_SELFTEST 1
#include "../../official_pipeline/src/official_preclamp_instr_v1.h"

#include <cassert>
#include <cstdio>
#include <vector>

int main() {
  using namespace aether_preclamp_instr_v1;
  assert(!ShouldCollapseFixed12288({}));
  assert(ShouldCollapseFixed12288({0, 8192, 12288}));
  assert(!ShouldCollapseFixed12288({1, 12289, 100}));
  std::puts("PASS R7 Fixed-12288 collapse iff every observed frame <= 12288");
}
