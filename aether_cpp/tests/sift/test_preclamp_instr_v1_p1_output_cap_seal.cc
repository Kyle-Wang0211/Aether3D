#define AETHER_PRECLAMP_INSTR_ENV_SELFTEST 1
#include "../../official_pipeline/src/official_preclamp_instr_v1.h"

#include <algorithm>
#include <cassert>
#include <cstdio>
#include <cstdlib>
#include <vector>

int main() {
  using namespace aether_preclamp_instr_v1;
  setenv("AETHER_PRECLAMP_INSTR_V1", "1", 1);

  // Production shape: the GPU descriptor stage computes every row retained by
  // the legacy group clamp, while the stable C ABI copies only out_cap rows.
  constexpr uint32_t kLegacyCount = 16570;
  constexpr uint32_t kOutCap = 8192;
  const uint32_t emitted = std::min(kLegacyCount, kOutCap);
  assert(emitted == 8192);

  ClearPendingAtGpuEntry();
  BeginLegacyClamp(20000);
  UpdateLegacyClampResult(kLegacyCount);
  assert(SealAcceptedLegacyGpuResult(
      kLegacyCount, FieldStatus::kUnavailable, 0.0f));
  FrameCounts row;
  assert(FinalizeAcceptedFrame(
      501, 1, FieldStatus::kValid, 2, &row));
  assert(row.legacy_count == kLegacyCount);
  assert(row.descriptor_rows_status == FieldStatus::kValid);
  assert(row.descriptor_rows == kLegacyCount);
  assert(row.descriptor_rows != emitted);
  assert(row.overflow_group_size == kLegacyCount - 8192);

  // A true descriptor-stage shortfall still fails closed.
  BeginLegacyClamp(20000);
  UpdateLegacyClampResult(kLegacyCount);
  assert(!SealAcceptedLegacyGpuResult(
      emitted, FieldStatus::kUnavailable, 0.0f));
  assert(!FinalizeAcceptedFrame(
      502, 2, FieldStatus::kValid, 2, &row));

  std::puts("PASS production-shaped descriptor rows survive ABI output cap");
}
