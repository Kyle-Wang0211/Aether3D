#define AETHER_PRECLAMP_INSTR_ENV_SELFTEST 1
#include "../../official_pipeline/src/official_preclamp_instr_v1.h"

#include <cassert>
#include <cstdio>
#include <vector>

int main() {
  using namespace aether_preclamp_instr_v1;
  const std::vector<int64_t> ordered{50, 70, 10, 30, 20, 90};
  // Recorded overflow is intentionally unrelated to preclamp-legacy so the
  // test fails if selection derives a substitute metric.
  const std::vector<ReplayFrame> frames{
      {50, 200, 199, 1}, {70, 200, 199, 20}, {10, 100, 99, 20},
      {30, 300, 299, 30}, {20, 400, 399, 40}, {90, 500, 499, 50}};
  ReplaySelectionManifest manifest;
  assert(SelectReplayFrames(ordered, frames, &manifest) ==
         FixtureStatus::kOk);
  assert(manifest.selected.size() == 4);
  assert(manifest.selected[0].role == ReplayFrameRole::kFirst);
  assert(manifest.selected[0].frame_id == 50);
  // Median value=200 ties at IDs 50/70. Smallest=50 is already selected, so
  // advance to the next DISTINCT value (300), never choose tied ID 70.
  assert(manifest.selected[1].role == ReplayFrameRole::kPreclampMedian);
  assert(manifest.selected[1].frame_id == 30);
  assert(manifest.selected[2].role == ReplayFrameRole::kOverflowP90);
  assert(manifest.selected[2].frame_id == 20);
  assert(manifest.selected[3].role == ReplayFrameRole::kOverflowMaximum);
  assert(manifest.selected[3].frame_id == 90);
  // final-third starts at ordered[4]=20; 20 and the only later ID 90 are used.
  // It must omit, not wrap to the earlier unused 70/10.
  assert(manifest.omissions.size() == 1);
  assert(manifest.omissions[0].role == ReplayFrameRole::kFinalThird);
  assert(manifest.omissions[0].reason ==
         ReplayOmissionReason::kNoLaterAcceptedFrame);
  std::puts("PASS amendment replay direct-overflow/distinct/no-wrap semantics");
}
