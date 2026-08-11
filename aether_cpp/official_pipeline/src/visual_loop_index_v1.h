#pragma once

#include <array>
#include <cstddef>
#include <cstdint>
#include <vector>

namespace aether::sfm {

struct VisualLoopIndexConfigV1 {
  // [LOOP-P5 2026-08-06 用户签决"period 10→5 上生产"] 10→5:流式回环单向
  // (只有后帧能认前帧),period=10 抽查在两场真机 fixture 上事件召回仅
  // 0.211/0.500;六臂 A/B 里"仅 period→5"是唯一实测正收益臂(cap6
  // 0.211→0.368,+74%),代价 +0.36 对/帧、无突发变化。同批测的一致性门/
  // 官方打分/尺度采样均判死或未证,见
  // progecttwo/_artifacts/loop_v11_20260806/REPORT.md。回滚=改回 10。
  int32_t query_period = 5;
  int32_t retrieve_cap = 50;
  // [LOOP-TOP8 2026-08-06 用户签决"p5_top8 上生产"] 4→8:period×topup 二维
  // Pareto(loop_v11_20260806/period_scan/)实测"第一份预算花在宽度"——
  // 真伙伴常被排在第 5-8 名(天花板缺口 75% 是排名进不了 top4),同价位
  // p5_top8(1.36 对/帧,0.347/0.600)两场均强于 p3_top4;宽度只值这一步,
  // top12/16 被加密严格支配。代价 ~+5% 总匹配预算;假候选由 TVG 兜底。
  // 回滚=改回 4。
  int32_t topup = 8;
  int32_t recent_exclusion = 20;
  int32_t max_descriptors_per_image = 256;
};

struct VisualLoopCandidateV1 {
  int32_t frame_id = -1;
  uint64_t score = 0;
};

// Platform-neutral, bounded visual retrieval over the production RootSIFT-u8
// descriptors. It uses four fixed integer random-hyperplane LSH tables and an
// integer IDF-weighted bag-of-words score. No FAISS, OpenMP, model asset, random
// seed, GPU API, or platform math library is involved, so ordered candidates
// are reproducible on iOS, Android, Harmony and the SIMD fallback.
//
// Retrieval only proposes remote frames. The existing exact descriptor matcher
// and COLMAP TwoViewGeometry remain the sole authority that can create a graph
// edge.
class PortableVisualLoopIndexV1 {
 public:
  explicit PortableVisualLoopIndexV1(
      VisualLoopIndexConfigV1 config = {});

  // Query before indexing the current frame, then index it. A query occurs on
  // every query_period-th valid descriptor frame. covered_frame_ids are the
  // S20/T2 or already-persisted partners that must not be returned again.
  std::vector<VisualLoopCandidateV1> QueryAndAdd(
      int32_t frame_id, const uint8_t* descriptors, int32_t descriptor_count,
      const std::vector<int32_t>& covered_frame_ids);

  // Removes all retrieval state for a withdrawn frame and repairs document
  // frequencies. Query cadence is capture-history based and is not rewound.
  bool RemoveFrame(int32_t frame_id);

  size_t NumImages() const { return images_.size(); }

 private:
  static constexpr int32_t kTables = 4;
  static constexpr int32_t kBitsPerTable = 10;
  static constexpr int32_t kWordsPerTable = 1 << kBitsPerTable;
  static constexpr int32_t kWordCount = kTables * kWordsPerTable;

  struct WordCount {
    uint16_t word = 0;
    uint16_t count = 0;
  };

  struct IndexedImage {
    int32_t frame_id = -1;
    std::vector<WordCount> histogram;
  };

  std::vector<WordCount> BuildHistogram(const uint8_t* descriptors,
                                        int32_t descriptor_count) const;
  uint16_t DescriptorWord(const uint8_t* descriptor, int32_t table) const;
  uint64_t Score(const std::vector<WordCount>& query,
                 const std::vector<WordCount>& indexed) const;

  VisualLoopIndexConfigV1 config_;
  int32_t valid_frames_seen_ = 0;
  std::array<uint32_t, kWordCount> document_frequency_{};
  std::vector<IndexedImage> images_;
};

}  // namespace aether::sfm
