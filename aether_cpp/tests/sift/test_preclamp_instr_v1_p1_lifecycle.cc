#define AETHER_PRECLAMP_INSTR_ENV_SELFTEST 1
#include "../../official_pipeline/src/official_preclamp_instr_v1.h"

#include <cassert>
#include <cmath>
#include <cstdio>
#include <cstdlib>
#include <vector>

int main() {
  using namespace aether_preclamp_instr_v1;
  setenv("AETHER_PRECLAMP_INSTR_V1", "1", 1);
  ClearPendingAtGpuEntry();

  // Clamp exit updates pending scalar state but never publishes.
  BeginLegacyClamp(20000);
  UpdateLegacyClampResult(8300);

  // A post-clamp descriptor mismatch fails closed and cannot be reconciled to
  // a later accepted frame.
  assert(!SealAcceptedLegacyGpuResult(
      8299, FieldStatus::kUnavailable, 0.0f));
  FrameCounts rejected;
  assert(!FinalizeAcceptedFrame(
      41, 1, FieldStatus::kValid, 2, &rejected));

  // Descriptor failure/fallback and canonical routing both discard pending.
  BeginLegacyClamp(10000);
  UpdateLegacyClampResult(8200);
  DiscardPending(PendingDiscardReason::kGpuFailureOrFallback);
  assert(!FinalizeAcceptedFrame(
      42, 2, FieldStatus::kValid, 1, &rejected));
  BeginLegacyClamp(10000);
  UpdateLegacyClampResult(8192);
  DiscardPending(PendingDiscardReason::kCanonicalRoute);
  assert(!FinalizeAcceptedFrame(
      43, 3, FieldStatus::kValid, 1, &rejected));

  // A missing output sink fails closed and still consumes the seal.
  BeginLegacyClamp(10000);
  UpdateLegacyClampResult(8200);
  assert(SealAcceptedLegacyGpuResult(
      8200, FieldStatus::kUnavailable, 0.0f));
  assert(!FinalizeAcceptedFrame(
      44, 4, FieldStatus::kValid, 1, nullptr));
  assert(!FinalizeAcceptedFrame(
      44, 4, FieldStatus::kValid, 1, &rejected));

  // A complete legacy GPU result is sealed, then accepted-frame reconciliation
  // attaches the production identity and session-owned fields exactly once.
  BeginLegacyClamp(20000);
  UpdateLegacyClampResult(8300);
  assert(SealAcceptedLegacyGpuResult(
      8300, FieldStatus::kUnavailable, 0.0f));
  FrameCounts row;
  assert(FinalizeAcceptedFrame(
      91, 7, FieldStatus::kValid, 2, &row));
  assert(!FinalizeAcceptedFrame(
      92, 8, FieldStatus::kValid, 2, &rejected));
  assert(row.schema_version == 2);
  assert(row.accepted_status == AcceptedFrameStatus::kAccepted);
  assert(row.frame_id == 91);
  assert(row.frame_ordinal == 7);
  assert(row.count_status == FieldStatus::kValid);
  assert(row.preclamp_count == 20000);
  assert(row.legacy_count == 8300);
  assert(row.strict_shadow_count == 8192);
  assert(row.overflow_group_size == 108);
  assert(row.descriptor_rows_status == FieldStatus::kValid);
  assert(row.descriptor_rows == row.legacy_count);
  assert(row.gpu_ms_status == FieldStatus::kUnavailable);
  assert(row.gpu_ms == 0.0f);
  assert(row.thermal_state_status == FieldStatus::kValid);
  assert(row.thermal_state == 2);
  assert(row.queue_backlog_status == FieldStatus::kPendingExternalJoin);

  // The next GPU entry drops stale unsealed state.
  BeginLegacyClamp(9999);
  UpdateLegacyClampResult(8200);
  ClearPendingAtGpuEntry();
  assert(!SealAcceptedLegacyGpuResult(
      8200, FieldStatus::kUnavailable, 0.0f));
  std::puts("PASS amendment lifecycle and accepted-frame ownership");
}
