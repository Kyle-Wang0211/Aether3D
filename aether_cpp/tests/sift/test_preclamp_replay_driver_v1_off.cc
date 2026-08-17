#define AETHER_PRECLAMP_INSTR_ENV_SELFTEST 1
#include "../../official_pipeline/src/official_preclamp_replay_driver_v1.h"

#include <cassert>
#include <cstdio>
#include <cstdlib>

namespace {
int g_extract_calls = 0;
int MustNotRun(const uint8_t*, int, int, int, int, float*, uint8_t*, int,
               int*) {
  ++g_extract_calls;
  return 0;
}
}  // namespace

int main() {
  using namespace aether_preclamp_instr_v1;
  ::unsetenv("AETHER_PRECLAMP_INSTR_V1");
  ::unsetenv("AETHER_PRECLAMP_RUN_ID_V1");
  ::unsetenv("AETHER_PRECLAMP_SOURCE_SHA256_V1");
  PhaseBReplayDriverV1 driver;
  const uint8_t gray[1] = {};
  assert(driver.AddGrayFrame(gray, 1, 1, 0, std::string(),
                             FieldStatus::kUnavailable, -1, &MustNotRun) ==
         PhaseBReplayDriverStatus::kOff);
  assert(g_extract_calls == 0);
  PhaseBHeadroomReport report;
  assert(driver.Seal(&report) == PhaseBReplayDriverStatus::kOff);
  std::puts("PASS R19 default-OFF replay driver is a constructive no-op");
}
