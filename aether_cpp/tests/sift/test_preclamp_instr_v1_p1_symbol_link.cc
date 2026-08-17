#define AETHER_PRECLAMP_INSTR_ENV_SELFTEST 1
#include "../../official_pipeline/src/official_preclamp_instr_v1.h"

#include <cstdlib>

int main() {
  setenv("AETHER_PRECLAMP_INSTR_V1", "1", 1);
  aether_preclamp_instr_v1::ClearPendingAtGpuEntry();
  aether_preclamp_instr_v1::BeginLegacyClamp(9000);
  aether_preclamp_instr_v1::UpdateLegacyClampResult(8200);
  aether_preclamp_instr_v1::DiscardPending(
      aether_preclamp_instr_v1::PendingDiscardReason::kValidationFailure);
  return 0;
}
