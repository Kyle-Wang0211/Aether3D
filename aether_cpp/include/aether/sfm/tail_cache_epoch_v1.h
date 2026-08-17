#pragma once

#include <cstddef>
#include <cstdint>
#include <unordered_set>
#include <vector>

namespace aether::sfm {

enum class TailCacheEpochStateV1 : uint8_t {
  kEmpty = 0,
  kReadable = 1,
  kDirty = 2,
  kRebuilding = 3,
};

enum class TailCacheDirtyReasonV1 : uint8_t {
  kNone = 0,
  kPairOverwrite = 1,
  kRemoveFrame = 2,
  kLatePair = 3,
  kModelReplacement = 4,
  kFinalizeMove = 5,
  kReconstructionSwap = 6,
  kConfigChange = 7,
  kCacheInconsistency = 8,
  kExceptionRetry = 9,
  kDeviceReset = 10,
  kUnknownMutation = 11,
};

/// Backend-neutral fail-closed epoch state for the mutable COLMAP cache.
/// COLMAP objects and database handles deliberately do not appear here.
class TailCacheEpochV1 {
 public:
  void StartEmpty() {
    generation_ = generation_ == 0 ? 1 : generation_ + 1;
    invalidated_generation_ = 0;
    rebuild_parent_generation_ = 0;
    dirty_reason_ = TailCacheDirtyReasonV1::kNone;
    image_ids_.clear();
    pair_ids_.clear();
    state_ = TailCacheEpochStateV1::kReadable;
  }

  bool AdmitImage(uint32_t image_id) {
    if (!readable()) return false;
    const auto [_, inserted] = image_ids_.insert(image_id);
    if (!inserted) MarkDirty(TailCacheDirtyReasonV1::kCacheInconsistency);
    return inserted;
  }

  bool AdmitPair(uint64_t pair_id) {
    if (!readable()) return false;
    const auto [_, inserted] = pair_ids_.insert(pair_id);
    if (!inserted) MarkDirty(TailCacheDirtyReasonV1::kPairOverwrite);
    return inserted;
  }

  void MarkDirty(TailCacheDirtyReasonV1 reason) {
    if (reason == TailCacheDirtyReasonV1::kNone) {
      reason = TailCacheDirtyReasonV1::kUnknownMutation;
    }
    if (state_ != TailCacheEpochStateV1::kDirty) {
      invalidated_generation_ = generation_;
    }
    dirty_reason_ = reason;
    state_ = TailCacheEpochStateV1::kDirty;
  }

  bool BeginRebuild() {
    if (state_ != TailCacheEpochStateV1::kDirty) return false;
    rebuild_parent_generation_ = generation_;
    state_ = TailCacheEpochStateV1::kRebuilding;
    return true;
  }

  void CompleteRebuild(const std::vector<uint32_t>& image_ids,
                       const std::vector<uint64_t>& pair_ids) {
    if (state_ != TailCacheEpochStateV1::kRebuilding) {
      MarkDirty(TailCacheDirtyReasonV1::kCacheInconsistency);
      return;
    }
    std::unordered_set<uint32_t> rebuilt_images(image_ids.begin(),
                                                image_ids.end());
    std::unordered_set<uint64_t> rebuilt_pairs(pair_ids.begin(),
                                               pair_ids.end());
    if (rebuilt_images.size() != image_ids.size() ||
        rebuilt_pairs.size() != pair_ids.size()) {
      MarkDirty(TailCacheDirtyReasonV1::kCacheInconsistency);
      return;
    }
    image_ids_ = std::move(rebuilt_images);
    pair_ids_ = std::move(rebuilt_pairs);
    ++generation_;
    dirty_reason_ = TailCacheDirtyReasonV1::kNone;
    state_ = TailCacheEpochStateV1::kReadable;
  }

  void FailRebuild(TailCacheDirtyReasonV1 reason) { MarkDirty(reason); }

  bool readable() const { return state_ == TailCacheEpochStateV1::kReadable; }
  bool ContainsImage(uint32_t image_id) const {
    return image_ids_.find(image_id) != image_ids_.end();
  }
  bool ContainsPair(uint64_t pair_id) const {
    return pair_ids_.find(pair_id) != pair_ids_.end();
  }
  TailCacheEpochStateV1 state() const { return state_; }
  TailCacheDirtyReasonV1 dirty_reason() const { return dirty_reason_; }
  uint64_t generation() const { return generation_; }
  uint64_t invalidated_generation() const { return invalidated_generation_; }
  uint64_t rebuild_parent_generation() const {
    return rebuild_parent_generation_;
  }
  size_t image_count() const { return image_ids_.size(); }
  size_t pair_count() const { return pair_ids_.size(); }

 private:
  TailCacheEpochStateV1 state_ = TailCacheEpochStateV1::kEmpty;
  TailCacheDirtyReasonV1 dirty_reason_ = TailCacheDirtyReasonV1::kNone;
  uint64_t generation_ = 0;
  uint64_t invalidated_generation_ = 0;
  uint64_t rebuild_parent_generation_ = 0;
  std::unordered_set<uint32_t> image_ids_;
  std::unordered_set<uint64_t> pair_ids_;
};

}  // namespace aether::sfm
