#define AETHER_PRECLAMP_INSTR_ENV_SELFTEST 1
#include "../../official_pipeline/src/official_preclamp_instr_v1.h"

#include <cassert>
#include <cstdio>
#include <set>
#include <vector>

int main() {
  using namespace aether_preclamp_instr_v1;
  const std::vector<int64_t> ordered{90, 50, 70, 10, 30, 20};
  const std::vector<ReplayFrame> frames{
      {90, 100, 50, 1}, {50, 200, 100, 2}, {70, 200, 100, 2},
      {10, 300, 200, 3}, {30, 400, 300, 4}, {20, 500, 400, 5}};
  ReplaySelectionManifest manifest;
  assert(SelectReplayFrames(ordered, frames, &manifest) ==
         FixtureStatus::kOk);
  // Equal values are ordered by the smallest frameId, independent of receipt.
  assert(manifest.selected[1].frame_id == 50);
  std::set<int64_t> unique;
  for (const auto& s : manifest.selected) unique.insert(s.frame_id);
  assert(unique.size() == manifest.selected.size());
  std::puts("PASS R4 duplicate resolution and smallest-frameId ties");
}
