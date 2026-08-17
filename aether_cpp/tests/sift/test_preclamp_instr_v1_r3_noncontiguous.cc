#define AETHER_PRECLAMP_INSTR_ENV_SELFTEST 1
#include "../../official_pipeline/src/official_preclamp_instr_v1.h"

#include <cassert>
#include <cstdio>
#include <vector>

int main() {
  using namespace aether_preclamp_instr_v1;
  const std::vector<int64_t> ordered{42, 7, 100, 3, 88};
  const std::vector<ReplayFrame> frames{
      {42, 100, 90, 10}, {7, 300, 100, 200}, {100, 200, 150, 50},
      {3, 500, 100, 400}, {88, 400, 350, 50}};
  ReplaySelectionManifest manifest;
  assert(SelectReplayFrames(ordered, frames, &manifest) ==
         FixtureStatus::kOk);
  const auto& selected = manifest.selected;
  assert(selected.size() == 4);
  assert(selected[0].role == ReplayFrameRole::kFirst);
  assert(selected[0].frame_id == 42);  // accepted[0], not numeric frame 0
  assert(selected[1].frame_id == 7);   // preclamp median
  assert(selected[2].frame_id == 3);   // P90 collision advances distinct-up
  assert(selected[3].frame_id == 88);  // final-third advances, without wrap
  assert(manifest.omissions.size() == 1);
  assert(manifest.omissions[0].role == ReplayFrameRole::kOverflowMaximum);
  std::puts("PASS R3 non-contiguous accepted frame IDs");
}
