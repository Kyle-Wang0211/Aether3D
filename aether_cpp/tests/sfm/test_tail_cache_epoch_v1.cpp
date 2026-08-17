#include "aether/sfm/tail_cache_epoch_v1.h"

#include <cstdlib>
#include <iostream>
#include <string_view>
#include <vector>

namespace {

using aether::sfm::TailCacheDirtyReasonV1;
using aether::sfm::TailCacheEpochStateV1;
using aether::sfm::TailCacheEpochV1;

[[noreturn]] void Fail(std::string_view message) {
  std::cerr << "FAIL tail_cache_epoch_v1: " << message << "\n";
  std::abort();
}

void Check(bool condition, std::string_view message) {
  if (!condition) Fail(message);
}

void TestFirstWriteAndDuplicatePair() {
  TailCacheEpochV1 epoch;
  epoch.StartEmpty();
  Check(epoch.state() == TailCacheEpochStateV1::kReadable,
        "empty session should be readable");
  Check(epoch.generation() == 1, "first generation should be one");
  Check(epoch.AdmitImage(1), "first image admission failed");
  Check(epoch.AdmitImage(2), "second image admission failed");
  Check(epoch.AdmitPair(10), "first pair admission failed");
  Check(!epoch.AdmitPair(10), "duplicate pair should not be admitted");
  Check(!epoch.readable(), "duplicate pair must close the epoch");
  Check(epoch.dirty_reason() == TailCacheDirtyReasonV1::kPairOverwrite,
        "duplicate pair must be classified as overwrite");
  Check(epoch.invalidated_generation() == 1,
        "invalidated generation mismatch");
}

void TestDirtyReasonsFailClosed() {
  const std::vector<TailCacheDirtyReasonV1> reasons = {
      TailCacheDirtyReasonV1::kRemoveFrame,
      TailCacheDirtyReasonV1::kLatePair,
      TailCacheDirtyReasonV1::kModelReplacement,
      TailCacheDirtyReasonV1::kFinalizeMove,
      TailCacheDirtyReasonV1::kReconstructionSwap,
      TailCacheDirtyReasonV1::kConfigChange,
      TailCacheDirtyReasonV1::kCacheInconsistency,
      TailCacheDirtyReasonV1::kExceptionRetry,
      TailCacheDirtyReasonV1::kDeviceReset,
      TailCacheDirtyReasonV1::kUnknownMutation,
  };
  for (const auto reason : reasons) {
    TailCacheEpochV1 epoch;
    epoch.StartEmpty();
    epoch.MarkDirty(reason);
    Check(epoch.state() == TailCacheEpochStateV1::kDirty,
          "dirty reason did not close epoch");
    Check(epoch.dirty_reason() == reason, "dirty reason was not retained");
    Check(!epoch.AdmitImage(1), "dirty epoch admitted an image");
    Check(!epoch.AdmitPair(2), "dirty epoch admitted a pair");
  }
}

void TestRebuildAdvancesGeneration() {
  TailCacheEpochV1 epoch;
  epoch.StartEmpty();
  epoch.AdmitImage(1);
  epoch.AdmitImage(2);
  epoch.AdmitPair(10);
  epoch.MarkDirty(TailCacheDirtyReasonV1::kRemoveFrame);
  Check(epoch.BeginRebuild(), "dirty epoch should enter rebuild");
  Check(epoch.state() == TailCacheEpochStateV1::kRebuilding,
        "rebuild state mismatch");
  Check(!epoch.readable(), "rebuild must remain unreadable");
  epoch.CompleteRebuild({1, 2, 3}, {10, 11});
  Check(epoch.state() == TailCacheEpochStateV1::kReadable,
        "successful rebuild should be readable");
  Check(epoch.generation() == 2, "rebuild must advance generation");
  Check(epoch.rebuild_parent_generation() == 1,
        "rebuild parent generation mismatch");
  Check(epoch.ContainsImage(3), "rebuilt image set mismatch");
  Check(epoch.ContainsPair(11), "rebuilt pair set mismatch");
  Check(epoch.AdmitPair(12), "new pair after rebuild should be admitted");
}

void TestFailedRebuildStaysDirty() {
  TailCacheEpochV1 epoch;
  epoch.StartEmpty();
  epoch.MarkDirty(TailCacheDirtyReasonV1::kExceptionRetry);
  Check(epoch.BeginRebuild(), "expected rebuild to start");
  epoch.FailRebuild(TailCacheDirtyReasonV1::kCacheInconsistency);
  Check(epoch.state() == TailCacheEpochStateV1::kDirty,
        "failed rebuild must stay dirty");
  Check(epoch.generation() == 1,
        "failed rebuild must not advance generation");
  Check(epoch.dirty_reason() == TailCacheDirtyReasonV1::kCacheInconsistency,
        "failed rebuild reason mismatch");
}

}  // namespace

int main() {
  TestFirstWriteAndDuplicatePair();
  TestDirtyReasonsFailClosed();
  TestRebuildAdvancesGeneration();
  TestFailedRebuildStaysDirty();
  std::cout << "PASS tail_cache_epoch_v1\n";
  return 0;
}
