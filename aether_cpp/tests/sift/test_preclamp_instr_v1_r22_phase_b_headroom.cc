#define AETHER_PRECLAMP_INSTR_ENV_SELFTEST 1
#include "../../official_pipeline/src/official_preclamp_instr_v1.h"

#include <cassert>
#include <cmath>
#include <cstdio>
#include <vector>

namespace {

aether_preclamp_instr_v1::FrameCounts Row(uint32_t ordinal,
                                          int64_t frame_id,
                                          uint32_t preclamp,
                                          uint32_t legacy) {
  using namespace aether_preclamp_instr_v1;
  FrameCounts row;
  row.accepted_status = AcceptedFrameStatus::kAccepted;
  row.frame_ordinal = ordinal;
  row.frame_id = frame_id;
  row.count_status = FieldStatus::kValid;
  row.preclamp_count = preclamp;
  row.legacy_count = legacy;
  row.strict_shadow_count = preclamp < 8192 ? preclamp : 8192;
  row.overflow_group_size =
      legacy > row.strict_shadow_count ? legacy - row.strict_shadow_count : 0;
  row.descriptor_rows_status = FieldStatus::kValid;
  row.descriptor_rows = legacy;
  return row;
}

}  // namespace

int main() {
  using namespace aether_preclamp_instr_v1;

  PhaseBHeadroomReport report;
  assert(AnalyzePhaseBHeadroom({Row(1, 10, 8000, 8000),
                                Row(2, 20, 8192, 8192)},
                               &report) ==
         PhaseBHeadroomStatus::kParkNoComputeHeadroom);
  assert(report.accepted_frames == 2);
  assert(report.legacy_descriptor_rows_total == 16192);
  assert(report.coverage8192_rows_total == 16192);
  assert(report.canonical8192_rows_total == 16192);
  assert(report.frames_descriptor_gt_8192 == 0);
  assert(report.coverage_row_headroom == 0.0);
  assert(report.canonical_row_headroom == 0.0);

  assert(AnalyzePhaseBHeadroom({Row(1, 10, 10000, 9000),
                                Row(2, 20, 7000, 7000)},
                               &report) ==
         PhaseBHeadroomStatus::kComputeHeadroomPresent);
  assert(report.legacy_descriptor_rows_total == 16000);
  assert(report.coverage8192_rows_total == 15192);
  assert(report.canonical8192_rows_total == 15192);
  assert(report.frames_descriptor_gt_8192 == 1);
  assert(std::abs(report.coverage_row_headroom - 0.0505) < 1e-12);
  assert(std::abs(report.canonical_row_headroom - 0.0505) < 1e-12);

  auto invalid = Row(1, 10, 9000, 8500);
  invalid.descriptor_rows = 8499;
  assert(AnalyzePhaseBHeadroom({invalid}, &report) ==
         PhaseBHeadroomStatus::kInvalidInput);
  assert(AnalyzePhaseBHeadroom({}, &report) ==
         PhaseBHeadroomStatus::kInvalidInput);
  assert(AnalyzePhaseBHeadroom({Row(1, 10, 9000, 8500)}, nullptr) ==
         PhaseBHeadroomStatus::kInvalidInput);

  std::puts("PASS R22/R23 Phase-B headroom branches and exact row ledger");
}
