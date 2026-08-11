#include "visual_loop_index_v1.h"

#include <algorithm>
#include <array>
#include <cstdint>
#include <unordered_set>
#include <utility>

namespace aether::sfm {
namespace {

uint32_t Mix32(uint32_t value) {
  value ^= value >> 16U;
  value *= 0x7feb352dU;
  value ^= value >> 15U;
  value *= 0x846ca68bU;
  value ^= value >> 16U;
  return value;
}

const std::array<int8_t, 4U * 10U * 128U>& ProjectionSigns() {
  static const std::array<int8_t, 4U * 10U * 128U> signs = [] {
    std::array<int8_t, 4U * 10U * 128U> values{};
    for (uint32_t table = 0; table < 4U; ++table) {
      for (uint32_t bit = 0; bit < 10U; ++bit) {
        for (uint32_t dimension = 0; dimension < 128U; ++dimension) {
          const uint32_t identity = (table + 1U) * 0x9e3779b9U ^
                                    (bit + 1U) * 0x85ebca6bU ^
                                    (dimension + 1U) * 0xc2b2ae35U;
          values[(table * 10U + bit) * 128U + dimension] =
              (Mix32(identity) & 1U) != 0U ? int8_t{1} : int8_t{-1};
        }
      }
    }
    return values;
  }();
  return signs;
}

}  // namespace

PortableVisualLoopIndexV1::PortableVisualLoopIndexV1(
    VisualLoopIndexConfigV1 config)
    : config_(config) {
  config_.query_period = std::max(config_.query_period, 1);
  config_.retrieve_cap = std::max(config_.retrieve_cap, 0);
  config_.topup = std::max(config_.topup, 0);
  config_.recent_exclusion = std::max(config_.recent_exclusion, 0);
  config_.max_descriptors_per_image =
      std::max(config_.max_descriptors_per_image, 1);
}

uint16_t PortableVisualLoopIndexV1::DescriptorWord(
    const uint8_t* descriptor, const int32_t table) const {
  uint16_t code = 0;
  const auto& signs = ProjectionSigns();
  for (int32_t bit = 0; bit < kBitsPerTable; ++bit) {
    int32_t projection = 0;
    for (int32_t dimension = 0; dimension < 128; ++dimension) {
      const int32_t value = static_cast<int32_t>(descriptor[dimension]);
      const size_t sign_index =
          static_cast<size_t>((table * kBitsPerTable + bit) * 128 +
                              dimension);
      projection += value * signs[sign_index];
    }
    if (projection >= 0) code |= static_cast<uint16_t>(1U << bit);
  }
  return static_cast<uint16_t>(table * kWordsPerTable + code);
}

std::vector<PortableVisualLoopIndexV1::WordCount>
PortableVisualLoopIndexV1::BuildHistogram(
    const uint8_t* descriptors, const int32_t descriptor_count) const {
  if (descriptors == nullptr || descriptor_count <= 0) return {};
  const int32_t sample_count =
      std::min(descriptor_count, config_.max_descriptors_per_image);
  std::array<uint16_t, kWordCount> counts{};
  for (int32_t sample = 0; sample < sample_count; ++sample) {
    const int32_t descriptor_index = static_cast<int32_t>(
        (static_cast<int64_t>(sample) * descriptor_count) / sample_count);
    const uint8_t* descriptor =
        descriptors + static_cast<size_t>(descriptor_index) * 128U;
    for (int32_t table = 0; table < kTables; ++table) {
      const uint16_t word = DescriptorWord(descriptor, table);
      if (counts[word] != UINT16_MAX) ++counts[word];
    }
  }

  std::vector<WordCount> histogram;
  histogram.reserve(static_cast<size_t>(sample_count * kTables));
  for (int32_t word = 0; word < kWordCount; ++word) {
    if (counts[word] == 0) continue;
    histogram.push_back(
        {.word = static_cast<uint16_t>(word), .count = counts[word]});
  }
  return histogram;
}

uint64_t PortableVisualLoopIndexV1::Score(
    const std::vector<WordCount>& query,
    const std::vector<WordCount>& indexed) const {
  size_t query_index = 0;
  size_t image_index = 0;
  uint64_t score = 0;
  while (query_index < query.size() && image_index < indexed.size()) {
    if (query[query_index].word < indexed[image_index].word) {
      ++query_index;
      continue;
    }
    if (indexed[image_index].word < query[query_index].word) {
      ++image_index;
      continue;
    }
    const uint16_t word = query[query_index].word;
    const uint32_t weight =
        std::max<uint32_t>(1U, 4096U / (1U + document_frequency_[word]));
    score += static_cast<uint64_t>(
                 std::min(query[query_index].count,
                          indexed[image_index].count)) *
             weight;
    ++query_index;
    ++image_index;
  }
  return score;
}

std::vector<VisualLoopCandidateV1> PortableVisualLoopIndexV1::QueryAndAdd(
    const int32_t frame_id, const uint8_t* descriptors,
    const int32_t descriptor_count,
    const std::vector<int32_t>& covered_frame_ids) {
  if (frame_id < 0 || descriptors == nullptr || descriptor_count <= 0) {
    return {};
  }
  std::vector<WordCount> histogram =
      BuildHistogram(descriptors, descriptor_count);
  if (histogram.empty()) return {};

  ++valid_frames_seen_;
  std::vector<VisualLoopCandidateV1> candidates;
  if (valid_frames_seen_ % config_.query_period == 0 &&
      config_.retrieve_cap > 0 && config_.topup > 0) {
    const std::unordered_set<int32_t> covered(covered_frame_ids.begin(),
                                              covered_frame_ids.end());
    candidates.reserve(images_.size());
    for (const IndexedImage& image : images_) {
      if (image.frame_id < 0 || covered.count(image.frame_id) != 0U) continue;
      if (frame_id - image.frame_id <= config_.recent_exclusion) continue;
      const uint64_t score = Score(histogram, image.histogram);
      if (score == 0) continue;
      candidates.push_back({.frame_id = image.frame_id, .score = score});
    }
    std::sort(candidates.begin(), candidates.end(),
              [](const VisualLoopCandidateV1& left,
                 const VisualLoopCandidateV1& right) {
                if (left.score != right.score) return left.score > right.score;
                return left.frame_id < right.frame_id;
              });
    if (static_cast<int32_t>(candidates.size()) > config_.retrieve_cap) {
      candidates.resize(static_cast<size_t>(config_.retrieve_cap));
    }
    if (static_cast<int32_t>(candidates.size()) > config_.topup) {
      candidates.resize(static_cast<size_t>(config_.topup));
    }
  }

  for (const WordCount& word_count : histogram) {
    ++document_frequency_[word_count.word];
  }
  images_.push_back(
      {.frame_id = frame_id, .histogram = std::move(histogram)});
  return candidates;
}

bool PortableVisualLoopIndexV1::RemoveFrame(const int32_t frame_id) {
  bool removed = false;
  for (auto iterator = images_.begin(); iterator != images_.end();) {
    if (iterator->frame_id != frame_id) {
      ++iterator;
      continue;
    }
    for (const WordCount& word_count : iterator->histogram) {
      uint32_t& frequency = document_frequency_[word_count.word];
      if (frequency > 0U) --frequency;
    }
    iterator = images_.erase(iterator);
    removed = true;
  }
  return removed;
}

}  // namespace aether::sfm
