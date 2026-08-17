#include "../../official_pipeline/src/official_preclamp_replay_driver_v1.h"

#include <cstdio>

int main() {
  void* handle = reinterpret_cast<void*>(0x1);
  const uint32_t status = aether_preclamp_phase_b_replay_create_v1(
      nullptr, nullptr, nullptr, 0, &handle);
  if (status != static_cast<uint32_t>(
                    aether_preclamp_instr_v1::PhaseBReplayDriverStatus::kOff) ||
      handle != nullptr) {
    return 2;
  }
  std::puts("PASS R19 C bridge default-OFF allocates nothing");
  return 0;
}
