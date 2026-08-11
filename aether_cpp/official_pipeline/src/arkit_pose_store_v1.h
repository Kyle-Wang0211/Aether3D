#pragma once

#include <array>
#include <cstdint>
#include <string>
#include <vector>

namespace aether::sfm {

struct ArkitPoseRecordV1 {
  int32_t frame_id = -1;
  uint32_t image_id = 0;
  bool active = true;
  uint64_t frame_identity_digest = 0;
  std::array<double, 4> cam_from_world_q_xyzw{};
  std::array<double, 3> cam_from_world_t_xyz{};
  std::array<double, 3> gravity_cam_xyz{};

  bool operator==(const ArkitPoseRecordV1& other) const {
    return frame_id == other.frame_id && image_id == other.image_id &&
           active == other.active &&
           frame_identity_digest == other.frame_identity_digest &&
           cam_from_world_q_xyzw == other.cam_from_world_q_xyzw &&
           cam_from_world_t_xyz == other.cam_from_world_t_xyz &&
           gravity_cam_xyz == other.gravity_cam_xyz;
  }
};

enum class ArkitPoseStoreStatusV1 {
  kOk = 0,
  kMissing = 1,
  kInvalid = 2,
  kIoError = 3,
};

bool IsValidArkitPoseRecordV1(const ArkitPoseRecordV1& record);

// Rewrites the complete ordered snapshot as tmp -> fsync -> atomic rename.
// An interrupted write therefore leaves either the previous complete snapshot
// or a detectable missing/invalid state; it can never expose a partial record.
ArkitPoseStoreStatusV1 WriteArkitPoseStoreV1(
    const std::string& path,
    const std::vector<ArkitPoseRecordV1>& records);

ArkitPoseStoreStatusV1 ReadArkitPoseStoreV1(
    const std::string& path,
    std::vector<ArkitPoseRecordV1>* records);

}  // namespace aether::sfm
