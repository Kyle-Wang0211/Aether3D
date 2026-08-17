#pragma once

#include <array>
#include <cstdint>
#include <span>
#include <string_view>
#include <vector>

namespace aether::sfm {

struct CanonicalFeatureCandidateV1 {
    std::array<uint32_t, 8> oriented_words{};
    uint32_t response_bits = 0;
    uint32_t orientation_bits = 0;
};

struct CanonicalFeatureSelectionV1 {
    std::vector<uint32_t> input_indices;
    std::vector<uint64_t> stable_ids;
};

enum class CanonicalFeatureSelectionStatusV1 : uint32_t {
    kOk = 0,
    kNullOutput = 1,
    kNonFiniteCandidate = 2,
    kInvalidImageExtent = 3,
};

enum class CanonicalCandidateBuildStatusV1 : uint32_t {
    kOk = 0,
    kNullOutput = 1,
    kInvalidBufferShape = 2,
    kNonFiniteSourceIndex = 3,
    kNonIntegralSourceIndex = 4,
    kSourceIndexOutOfRange = 5,
    kSourceRecordMismatch = 6,
};

enum class CanonicalRowGatherStatusV1 : uint32_t {
    kOk = 0,
    kNullOutput = 1,
    kInvalidBufferShape = 2,
    kIndexOutOfRange = 3,
};

enum class SelectedSidecarGatherStatusV1 : uint32_t {
    kOk = 0,
    kNullOutput = 1,
    kInvalidBufferShape = 2,
    kSelectedRowMissing = 3,
};

enum class FeatureSelectionPolicyV1 : uint32_t {
    kLegacyColmapGroup = 0,
    kCanonicalExact8192 = 1,
    kCoverageExact8192 = 2,
};

enum class FeatureSelectionPolicyReasonV1 : uint32_t {
    kAbsent = 0,
    kExplicitLegacy = 1,
    kExplicitCanonical = 2,
    kInvalidValue = 3,
    kExplicitCoverage = 4,
};

struct FeatureSelectionPolicyDecisionV1 {
    FeatureSelectionPolicyV1 policy =
        FeatureSelectionPolicyV1::kLegacyColmapGroup;
    FeatureSelectionPolicyReasonV1 reason =
        FeatureSelectionPolicyReasonV1::kAbsent;
};

FeatureSelectionPolicyDecisionV1 ParseFeatureSelectionPolicyV1(
    const char* value);

CanonicalCandidateBuildStatusV1 BuildCanonicalCandidatesFromSidecarV1(
    std::span<const uint32_t> oriented_words,
    std::span<const uint32_t> orientation_sidecar_words,
    std::span<const uint32_t> affine_input_words,
    std::vector<CanonicalFeatureCandidateV1>* output);

CanonicalRowGatherStatusV1 GatherCanonicalRowsV1(
    std::span<const uint32_t> input_words,
    uint32_t row_stride_words,
    std::span<const uint32_t> input_indices,
    std::vector<uint32_t>* output_words);

// Aligns full orientation sidecar records to a selected/reordered row table by
// exact eight-word row identity. This lets coverage preserve the byte-frozen
// legacy clamp while recovering its sidecar outside that source block.
SelectedSidecarGatherStatusV1 GatherSelectedSidecarByRowsV1(
    std::span<const uint32_t> full_oriented_words,
    std::span<const uint32_t> selected_oriented_words,
    std::span<const uint32_t> orientation_sidecar_words,
    std::vector<uint32_t>* output_sidecar_words);

CanonicalFeatureSelectionStatusV1 SelectCanonicalFeaturesV1(
    std::span<const CanonicalFeatureCandidateV1> candidates,
    uint32_t max_features,
    CanonicalFeatureSelectionV1* output);

// Selects an exact-cap, spatially distributed subset from the caller-provided
// candidate domain. The image is divided into a fixed 32x32 grid. Selection
// takes the strongest remaining candidate from every occupied cell before it
// takes a second candidate from any cell, then a third, and so on. The returned
// rows are restored to the same total canonical order as
// SelectCanonicalFeaturesV1, so Stable ID remains the output rank.
CanonicalFeatureSelectionStatusV1 SelectCoverageFeaturesV1(
    std::span<const CanonicalFeatureCandidateV1> candidates,
    uint32_t max_features,
    uint32_t image_width,
    uint32_t image_height,
    CanonicalFeatureSelectionV1* output);

}  // namespace aether::sfm
