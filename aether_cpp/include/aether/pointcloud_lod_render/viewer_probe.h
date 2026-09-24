// Test-only instrumentation of the pwlod_viewer render loop (not part of the
// frozen C ABI in pwlod_viewer.h; a shell never calls it).
//
// The plan 3b / B1 judges need to see two things the ABI does not expose:
//   * whether the render thread ever picked a ring target that was the one the
//     consumer holds (or the latest published one) -- counted at the moment the
//     target is chosen, under the same lock acquire_latest takes;
//   * a switch that removes the "not the consumer's target" rule, so the first
//     count can be shown to fire (negative control).
#pragma once

#include <cstdint>

#include "aether/pointcloud_lod_render/pwlod_viewer.h"

namespace aether::pointcloud_lod_render {

struct ViewerProbe {
  uint64_t frames_rendered = 0;    // ring frames submitted by the render thread
  uint64_t held_overwrites = 0;    // chosen target == the one the consumer held
  uint64_t latest_overwrites = 0;  // chosen target == the latest published one
  uint64_t published_ahead = 0;    // publishes with frame_number > completed_frame_number
};

ViewerProbe GetViewerProbe(pwlod_viewer* viewer);

// Negative control only: the ring choice ignores which target the consumer holds.
void SetIgnoreHeldExclusion(pwlod_viewer* viewer, bool on);

}  // namespace aether::pointcloud_lod_render
