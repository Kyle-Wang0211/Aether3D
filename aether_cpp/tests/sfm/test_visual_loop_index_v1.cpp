#include "visual_loop_index_v1.h"

#include <cstdint>
#include <cstdlib>
#include <iostream>
#include <string>
#include <vector>

namespace {

[[noreturn]] void Fail(const std::string& message) {
  std::cerr << "FAIL " << message << '\n';
  std::exit(1);
}

void Expect(const bool condition, const std::string& message) {
  if (!condition) Fail(message);
}

std::vector<uint8_t> Descriptors(const int count, const uint8_t seed) {
  std::vector<uint8_t> descriptors(static_cast<size_t>(count) * 128U);
  for (int descriptor = 0; descriptor < count; ++descriptor) {
    for (int dimension = 0; dimension < 128; ++dimension) {
      descriptors[static_cast<size_t>(descriptor) * 128U + dimension] =
          static_cast<uint8_t>(seed + descriptor * 7 + dimension * 13);
    }
  }
  return descriptors;
}

void TestPeriodRecentExclusionCoveredSetAndStableTie() {
  aether::sfm::VisualLoopIndexConfigV1 config;
  config.query_period = 3;
  config.retrieve_cap = 50;
  config.topup = 4;
  config.recent_exclusion = 0;
  config.max_descriptors_per_image = 32;
  aether::sfm::PortableVisualLoopIndexV1 index(config);
  const std::vector<uint8_t> same = Descriptors(32, 11);

  Expect(index.QueryAndAdd(0, same.data(), 32, {}).empty(),
         "first valid frame does not query");
  Expect(index.QueryAndAdd(1, same.data(), 32, {}).empty(),
         "second valid frame does not query");
  const auto third = index.QueryAndAdd(2, same.data(), 32, {});
  Expect(third.size() == 2, "period-three query returns both older frames");
  Expect(third[0].frame_id == 0 && third[1].frame_id == 1,
         "equal visual scores tie-break by frame id");

  index.QueryAndAdd(3, same.data(), 32, {});
  index.QueryAndAdd(4, same.data(), 32, {});
  const auto covered = index.QueryAndAdd(5, same.data(), 32, {0, 1, 2, 3});
  Expect(covered.size() == 1 && covered[0].frame_id == 4,
         "covered spatial/temporal partners are excluded");
}

void TestBoundedTopupAndRecentFrames() {
  aether::sfm::VisualLoopIndexConfigV1 config;
  config.query_period = 1;
  config.retrieve_cap = 50;
  config.topup = 4;
  config.recent_exclusion = 2;
  config.max_descriptors_per_image = 16;
  aether::sfm::PortableVisualLoopIndexV1 index(config);
  const std::vector<uint8_t> same = Descriptors(16, 29);
  for (int frame = 0; frame < 8; ++frame) {
    index.QueryAndAdd(frame, same.data(), 16, {});
  }
  const auto candidates = index.QueryAndAdd(8, same.data(), 16, {});
  Expect(candidates.size() == 4, "L4 cap is enforced");
  for (const auto& candidate : candidates) {
    Expect(candidate.frame_id <= 5, "recent exclusion is enforced");
  }
}

void TestInvalidDescriptorsFailClosedWithoutAdvancingPeriod() {
  aether::sfm::VisualLoopIndexConfigV1 config;
  config.query_period = 2;
  config.recent_exclusion = 0;
  aether::sfm::PortableVisualLoopIndexV1 index(config);
  const std::vector<uint8_t> descriptors = Descriptors(8, 5);
  Expect(index.QueryAndAdd(0, nullptr, 0, {}).empty(),
         "empty descriptors fail closed");
  Expect(index.NumImages() == 0, "invalid frame is not indexed");
  Expect(index.QueryAndAdd(1, descriptors.data(), 8, {}).empty(),
         "first valid frame remains first period slot");
  const auto second = index.QueryAndAdd(2, descriptors.data(), 8, {});
  Expect(second.size() == 1 && second[0].frame_id == 1,
         "second valid frame triggers query");
}

void TestRemovedFrameCannotBeRetrievedAgain() {
  aether::sfm::VisualLoopIndexConfigV1 config;
  config.query_period = 1;
  config.recent_exclusion = 0;
  config.topup = 4;
  aether::sfm::PortableVisualLoopIndexV1 index(config);
  const std::vector<uint8_t> same = Descriptors(16, 41);
  index.QueryAndAdd(0, same.data(), 16, {});
  index.QueryAndAdd(1, same.data(), 16, {});
  Expect(index.RemoveFrame(0), "indexed frame removal succeeds");
  Expect(!index.RemoveFrame(0), "repeated frame removal is idempotent");
  const auto candidates = index.QueryAndAdd(2, same.data(), 16, {});
  Expect(candidates.size() == 1 && candidates[0].frame_id == 1,
         "removed frame was returned by visual retrieval");
  Expect(index.NumImages() == 2,
         "removed frame remains in the bounded retrieval index");
}

}  // namespace

int main() {
  TestPeriodRecentExclusionCoveredSetAndStableTie();
  TestBoundedTopupAndRecentFrames();
  TestInvalidDescriptorsFailClosedWithoutAdvancingPeriod();
  TestRemovedFrameCannotBeRetrievedAgain();
  std::cout << "PASS portable visual loop index v1\n";
  return 0;
}
