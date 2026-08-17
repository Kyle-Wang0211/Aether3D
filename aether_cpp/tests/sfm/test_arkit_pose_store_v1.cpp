#include "../../official_pipeline/src/arkit_pose_store_v1.h"

#include <cassert>
#include <filesystem>
#include <fstream>
#include <string>
#include <vector>

#include <unistd.h>

namespace {

aether::sfm::ArkitPoseRecordV1 Record(const int frame_id,
                                      const uint32_t image_id,
                                      const double tx) {
  aether::sfm::ArkitPoseRecordV1 record;
  record.frame_id = frame_id;
  record.image_id = image_id;
  record.active = true;
  record.frame_identity_digest = 0x1000U + image_id;
  record.cam_from_world_q_xyzw = {0.0, 0.0, 0.0, 1.0};
  record.cam_from_world_t_xyz = {tx, 0.0, 0.0};
  record.gravity_cam_xyz = {0.0, -1.0, 0.0};
  return record;
}

}  // namespace

int main() {
  char dir_template[] = "/private/tmp/arkit_pose_store_v1.XXXXXX";
  const char* dir = mkdtemp(dir_template);
  assert(dir != nullptr);
  const std::filesystem::path root(dir);
  const std::filesystem::path path = root / "sfm_live.db.arkit_pose_v1";

  std::vector<aether::sfm::ArkitPoseRecordV1> loaded;
  assert(aether::sfm::ReadArkitPoseStoreV1(path.string(), &loaded) ==
         aether::sfm::ArkitPoseStoreStatusV1::kMissing);

  std::vector<aether::sfm::ArkitPoseRecordV1> expected = {
      Record(0, 1, 0.0), Record(1, 2, 0.2), Record(2, 3, 0.4)};
  expected[1].active = false;
  assert(aether::sfm::WriteArkitPoseStoreV1(path.string(), expected) ==
         aether::sfm::ArkitPoseStoreStatusV1::kOk);
  assert(aether::sfm::ReadArkitPoseStoreV1(path.string(), &loaded) ==
         aether::sfm::ArkitPoseStoreStatusV1::kOk);
  assert(loaded == expected);
  assert(!std::filesystem::exists(path.string() + ".tmp"));

  // One flipped byte must invalidate the whole snapshot; partial recovery is
  // forbidden because it would silently drop mandatory pose/gravity records.
  {
    std::fstream file(path, std::ios::in | std::ios::out | std::ios::binary);
    assert(file.good());
    file.seekg(-1, std::ios::end);
    char byte = 0;
    file.read(&byte, 1);
    byte ^= 0x1;
    file.seekp(-1, std::ios::end);
    file.write(&byte, 1);
  }
  loaded.clear();
  assert(aether::sfm::ReadArkitPoseStoreV1(path.string(), &loaded) ==
         aether::sfm::ArkitPoseStoreStatusV1::kInvalid);
  assert(loaded.empty());

  // Non-contiguous frame identity cannot be persisted as a valid recovery
  // snapshot; callers must block rather than invent a missing ARKit pose.
  const std::vector<aether::sfm::ArkitPoseRecordV1> gap = {
      Record(0, 1, 0.0), Record(2, 3, 0.4)};
  assert(aether::sfm::WriteArkitPoseStoreV1(path.string(), gap) ==
         aether::sfm::ArkitPoseStoreStatusV1::kInvalid);

  std::filesystem::remove_all(root);
  return 0;
}
