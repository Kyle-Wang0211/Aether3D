#include "aether/sfm/canonical_feature_selector_v1.h"

#include <algorithm>
#include <bit>
#include <cmath>
#include <cstddef>
#include <cstdint>
#include <cstring>
#include <map>
#include <numeric>
#include <utility>
#include <vector>

namespace aether::sfm {
namespace {

constexpr uint32_t kBinary32ExponentMask = UINT32_C(0x7f800000);
constexpr uint32_t kBinary32SignMask = UINT32_C(0x80000000);

bool IsFiniteBinary32(uint32_t bits) {
    return (bits & kBinary32ExponentMask) != kBinary32ExponentMask;
}

uint32_t OrderedBinary32(uint32_t bits) {
    return (bits & kBinary32SignMask) != 0u ? ~bits
                                            : (bits ^ kBinary32SignMask);
}

int32_t SignedWord(uint32_t bits) {
    return std::bit_cast<int32_t>(bits);
}

bool IsFiniteCandidate(const CanonicalFeatureCandidateV1& candidate) {
    for (size_t word = 0; word < 6; ++word) {
        if (!IsFiniteBinary32(candidate.oriented_words[word])) return false;
    }
    return IsFiniteBinary32(candidate.response_bits) &&
           IsFiniteBinary32(candidate.orientation_bits);
}

bool CandidateComesFirst(const CanonicalFeatureCandidateV1& lhs,
                         const CanonicalFeatureCandidateV1& rhs) {
    const int32_t lhs_octave = SignedWord(lhs.oriented_words[6]);
    const int32_t rhs_octave = SignedWord(rhs.oriented_words[6]);
    if (lhs_octave != rhs_octave) return lhs_octave > rhs_octave;

    const int32_t lhs_scale = SignedWord(lhs.oriented_words[7]);
    const int32_t rhs_scale = SignedWord(rhs.oriented_words[7]);
    if (lhs_scale != rhs_scale) return lhs_scale > rhs_scale;

    const uint32_t lhs_response = OrderedBinary32(lhs.response_bits);
    const uint32_t rhs_response = OrderedBinary32(rhs.response_bits);
    if (lhs_response != rhs_response) return lhs_response > rhs_response;

    for (size_t word = 0; word < 6; ++word) {
        const uint32_t lhs_value =
            OrderedBinary32(lhs.oriented_words[word]);
        const uint32_t rhs_value =
            OrderedBinary32(rhs.oriented_words[word]);
        if (lhs_value != rhs_value) return lhs_value < rhs_value;
    }

    const uint32_t lhs_orientation =
        OrderedBinary32(lhs.orientation_bits);
    const uint32_t rhs_orientation =
        OrderedBinary32(rhs.orientation_bits);
    return lhs_orientation < rhs_orientation;
}

}  // namespace

FeatureSelectionPolicyDecisionV1 ParseFeatureSelectionPolicyV1(
    const char* value) {
    if (value == nullptr) {
        return {
            FeatureSelectionPolicyV1::kLegacyColmapGroup,
            FeatureSelectionPolicyReasonV1::kAbsent,
        };
    }
    if (std::strcmp(value, "legacy_colmap_group_v1") == 0) {
        return {
            FeatureSelectionPolicyV1::kLegacyColmapGroup,
            FeatureSelectionPolicyReasonV1::kExplicitLegacy,
        };
    }
    if (std::strcmp(value, "canonical_exact_8192_v1") == 0) {
        return {
            FeatureSelectionPolicyV1::kCanonicalExact8192,
            FeatureSelectionPolicyReasonV1::kExplicitCanonical,
        };
    }
    if (std::strcmp(value, "coverage_exact_8192_v1") == 0) {
        return {
            FeatureSelectionPolicyV1::kCoverageExact8192,
            FeatureSelectionPolicyReasonV1::kExplicitCoverage,
        };
    }
    return {
        FeatureSelectionPolicyV1::kLegacyColmapGroup,
        FeatureSelectionPolicyReasonV1::kInvalidValue,
    };
}

CanonicalCandidateBuildStatusV1 BuildCanonicalCandidatesFromSidecarV1(
    std::span<const uint32_t> oriented_words,
    std::span<const uint32_t> orientation_sidecar_words,
    std::span<const uint32_t> affine_input_words,
    std::vector<CanonicalFeatureCandidateV1>* output) {
    if (output == nullptr) {
        return CanonicalCandidateBuildStatusV1::kNullOutput;
    }
    output->clear();

    constexpr size_t kOrientedStride = 8;
    constexpr size_t kSidecarStride = 2;
    if (oriented_words.size() % kOrientedStride != 0 ||
        affine_input_words.size() % kOrientedStride != 0) {
        return CanonicalCandidateBuildStatusV1::kInvalidBufferShape;
    }
    const size_t candidate_count =
        oriented_words.size() / kOrientedStride;
    if (orientation_sidecar_words.size() !=
        candidate_count * kSidecarStride) {
        return CanonicalCandidateBuildStatusV1::kInvalidBufferShape;
    }
    const size_t affine_count =
        affine_input_words.size() / kOrientedStride;

    std::vector<CanonicalFeatureCandidateV1> candidates;
    candidates.reserve(candidate_count);
    for (size_t candidate_index = 0; candidate_index < candidate_count;
         ++candidate_index) {
        const uint32_t source_bits =
            orientation_sidecar_words[candidate_index * kSidecarStride];
        const float source_value = std::bit_cast<float>(source_bits);
        if (!std::isfinite(source_value)) {
            return CanonicalCandidateBuildStatusV1::kNonFiniteSourceIndex;
        }
        if (std::trunc(source_value) != source_value) {
            return CanonicalCandidateBuildStatusV1::kNonIntegralSourceIndex;
        }
        if (source_value < 0.0f ||
            source_value >= static_cast<float>(affine_count)) {
            return CanonicalCandidateBuildStatusV1::kSourceIndexOutOfRange;
        }
        const size_t source_index = static_cast<size_t>(source_value);
        const size_t oriented_offset = candidate_index * kOrientedStride;
        const size_t affine_offset = source_index * kOrientedStride;
        if (oriented_words[oriented_offset] !=
                affine_input_words[affine_offset] ||
            oriented_words[oriented_offset + 1] !=
                affine_input_words[affine_offset + 1] ||
            oriented_words[oriented_offset + 6] !=
                affine_input_words[affine_offset + 5] ||
            oriented_words[oriented_offset + 7] !=
                affine_input_words[affine_offset + 6]) {
            return CanonicalCandidateBuildStatusV1::kSourceRecordMismatch;
        }

        CanonicalFeatureCandidateV1 candidate;
        std::copy_n(oriented_words.begin() + oriented_offset,
                    kOrientedStride, candidate.oriented_words.begin());
        candidate.response_bits = affine_input_words[affine_offset + 3];
        candidate.orientation_bits =
            orientation_sidecar_words[candidate_index * kSidecarStride + 1];
        candidates.push_back(candidate);
    }
    *output = std::move(candidates);
    return CanonicalCandidateBuildStatusV1::kOk;
}

CanonicalRowGatherStatusV1 GatherCanonicalRowsV1(
    std::span<const uint32_t> input_words,
    uint32_t row_stride_words,
    std::span<const uint32_t> input_indices,
    std::vector<uint32_t>* output_words) {
    if (output_words == nullptr) {
        return CanonicalRowGatherStatusV1::kNullOutput;
    }
    output_words->clear();
    if (row_stride_words == 0u ||
        input_words.size() % row_stride_words != 0u) {
        return CanonicalRowGatherStatusV1::kInvalidBufferShape;
    }

    const size_t row_count = input_words.size() / row_stride_words;
    for (uint32_t input_index : input_indices) {
        if (input_index >= row_count) {
            return CanonicalRowGatherStatusV1::kIndexOutOfRange;
        }
    }

    std::vector<uint32_t> gathered;
    gathered.reserve(input_indices.size() * row_stride_words);
    for (uint32_t input_index : input_indices) {
        const auto row_begin =
            input_words.begin() +
            static_cast<size_t>(input_index) * row_stride_words;
        gathered.insert(gathered.end(), row_begin,
                        row_begin + row_stride_words);
    }
    *output_words = std::move(gathered);
    return CanonicalRowGatherStatusV1::kOk;
}

SelectedSidecarGatherStatusV1 GatherSelectedSidecarByRowsV1(
    std::span<const uint32_t> full_oriented_words,
    std::span<const uint32_t> selected_oriented_words,
    std::span<const uint32_t> orientation_sidecar_words,
    std::vector<uint32_t>* output_sidecar_words) {
    if (output_sidecar_words == nullptr) {
        return SelectedSidecarGatherStatusV1::kNullOutput;
    }
    output_sidecar_words->clear();
    constexpr size_t kOrientedStride = 8;
    constexpr size_t kSidecarStride = 2;
    if (full_oriented_words.size() % kOrientedStride != 0 ||
        selected_oriented_words.size() % kOrientedStride != 0) {
        return SelectedSidecarGatherStatusV1::kInvalidBufferShape;
    }
    const size_t full_count = full_oriented_words.size() / kOrientedStride;
    if (orientation_sidecar_words.size() != full_count * kSidecarStride) {
        return SelectedSidecarGatherStatusV1::kInvalidBufferShape;
    }

    using Row = std::array<uint32_t, kOrientedStride>;
    struct Bucket {
        std::vector<size_t> full_indices;
        size_t next = 0;
    };
    std::map<Row, Bucket> rows;
    for (size_t index = 0; index < full_count; ++index) {
        Row row{};
        std::copy_n(full_oriented_words.begin() +
                        static_cast<std::ptrdiff_t>(index * kOrientedStride),
                    kOrientedStride, row.begin());
        rows[row].full_indices.push_back(index);
    }

    const size_t selected_count =
        selected_oriented_words.size() / kOrientedStride;
    output_sidecar_words->reserve(selected_count * kSidecarStride);
    for (size_t selected_index = 0; selected_index < selected_count;
         ++selected_index) {
        Row row{};
        std::copy_n(selected_oriented_words.begin() +
                        static_cast<std::ptrdiff_t>(selected_index *
                                                    kOrientedStride),
                    kOrientedStride, row.begin());
        auto found = rows.find(row);
        if (found == rows.end() ||
            found->second.next >= found->second.full_indices.size()) {
            output_sidecar_words->clear();
            return SelectedSidecarGatherStatusV1::kSelectedRowMissing;
        }
        const size_t full_index =
            found->second.full_indices[found->second.next++];
        const size_t offset = full_index * kSidecarStride;
        output_sidecar_words->push_back(orientation_sidecar_words[offset]);
        output_sidecar_words->push_back(
            orientation_sidecar_words[offset + 1]);
    }
    return SelectedSidecarGatherStatusV1::kOk;
}

CanonicalFeatureSelectionStatusV1 SelectCanonicalFeaturesV1(
    std::span<const CanonicalFeatureCandidateV1> candidates,
    uint32_t max_features,
    CanonicalFeatureSelectionV1* output) {
    if (output == nullptr) {
        return CanonicalFeatureSelectionStatusV1::kNullOutput;
    }
    output->input_indices.clear();
    output->stable_ids.clear();

    for (const CanonicalFeatureCandidateV1& candidate : candidates) {
        if (!IsFiniteCandidate(candidate)) {
            return CanonicalFeatureSelectionStatusV1::kNonFiniteCandidate;
        }
    }

    std::vector<uint32_t> order(candidates.size());
    std::iota(order.begin(), order.end(), 0u);
    std::sort(order.begin(), order.end(), [&](uint32_t lhs, uint32_t rhs) {
        return CandidateComesFirst(candidates[lhs], candidates[rhs]);
    });

    const size_t selected_count =
        std::min(candidates.size(), static_cast<size_t>(max_features));
    output->input_indices.reserve(selected_count);
    output->stable_ids.reserve(selected_count);
    for (size_t rank = 0; rank < selected_count; ++rank) {
        output->input_indices.push_back(order[rank]);
        output->stable_ids.push_back(static_cast<uint64_t>(rank));
    }
    return CanonicalFeatureSelectionStatusV1::kOk;
}

CanonicalFeatureSelectionStatusV1 SelectCoverageFeaturesV1(
    std::span<const CanonicalFeatureCandidateV1> candidates,
    uint32_t max_features,
    uint32_t image_width,
    uint32_t image_height,
    CanonicalFeatureSelectionV1* output) {
    if (output == nullptr) {
        return CanonicalFeatureSelectionStatusV1::kNullOutput;
    }
    output->input_indices.clear();
    output->stable_ids.clear();
    if (image_width == 0u || image_height == 0u) {
        return CanonicalFeatureSelectionStatusV1::kInvalidImageExtent;
    }
    for (const CanonicalFeatureCandidateV1& candidate : candidates) {
        if (!IsFiniteCandidate(candidate)) {
            return CanonicalFeatureSelectionStatusV1::kNonFiniteCandidate;
        }
    }

    constexpr uint32_t kGridSide = 32u;
    constexpr uint32_t kCellCount = kGridSide * kGridSide;
    std::array<std::vector<uint32_t>, kCellCount> cells;
    for (uint32_t index = 0; index < candidates.size(); ++index) {
        const float x = std::bit_cast<float>(
            candidates[index].oriented_words[0]);
        const float y = std::bit_cast<float>(
            candidates[index].oriented_words[1]);
        const double normalized_x =
            static_cast<double>(x) * kGridSide / image_width;
        const double normalized_y =
            static_cast<double>(y) * kGridSide / image_height;
        const int64_t cell_x = std::clamp<int64_t>(
            static_cast<int64_t>(std::floor(normalized_x)), 0,
            kGridSide - 1);
        const int64_t cell_y = std::clamp<int64_t>(
            static_cast<int64_t>(std::floor(normalized_y)), 0,
            kGridSide - 1);
        cells[static_cast<size_t>(cell_y) * kGridSide +
              static_cast<size_t>(cell_x)]
            .push_back(index);
    }
    const auto index_comes_first = [&](uint32_t lhs, uint32_t rhs) {
        return CandidateComesFirst(candidates[lhs], candidates[rhs]);
    };
    size_t max_cell_depth = 0;
    for (auto& cell : cells) {
        std::sort(cell.begin(), cell.end(), index_comes_first);
        max_cell_depth = std::max(max_cell_depth, cell.size());
    }

    const size_t selected_count =
        std::min(candidates.size(), static_cast<size_t>(max_features));
    std::vector<uint32_t> selected;
    selected.reserve(selected_count);
    for (size_t depth = 0;
         depth < max_cell_depth && selected.size() < selected_count;
         ++depth) {
        std::vector<uint32_t> layer;
        layer.reserve(kCellCount);
        for (const auto& cell : cells) {
            if (depth < cell.size()) layer.push_back(cell[depth]);
        }
        std::sort(layer.begin(), layer.end(), index_comes_first);
        const size_t remaining = selected_count - selected.size();
        const size_t take = std::min(remaining, layer.size());
        selected.insert(selected.end(), layer.begin(), layer.begin() + take);
    }

    // Spatial coverage decides membership only. Preserve the shared canonical
    // total order for descriptor rows, deterministic DB serialization and IDs.
    std::sort(selected.begin(), selected.end(), index_comes_first);
    output->input_indices = std::move(selected);
    output->stable_ids.resize(output->input_indices.size());
    std::iota(output->stable_ids.begin(), output->stable_ids.end(), UINT64_C(0));
    return CanonicalFeatureSelectionStatusV1::kOk;
}

}  // namespace aether::sfm
