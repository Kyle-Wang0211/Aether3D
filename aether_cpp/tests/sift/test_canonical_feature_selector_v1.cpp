#include "aether/sfm/canonical_feature_selector_v1.h"

#include <algorithm>
#include <bit>
#include <cmath>
#include <cstdint>
#include <cstdlib>
#include <iostream>
#include <limits>
#include <random>
#include <span>
#include <string_view>
#include <vector>

namespace {

using aether::sfm::CanonicalFeatureCandidateV1;
using aether::sfm::CanonicalCandidateBuildStatusV1;
using aether::sfm::CanonicalFeatureSelectionStatusV1;
using aether::sfm::CanonicalFeatureSelectionV1;
using aether::sfm::CanonicalRowGatherStatusV1;
using aether::sfm::BuildCanonicalCandidatesFromSidecarV1;
using aether::sfm::FeatureSelectionPolicyReasonV1;
using aether::sfm::FeatureSelectionPolicyV1;
using aether::sfm::ParseFeatureSelectionPolicyV1;
using aether::sfm::GatherCanonicalRowsV1;
using aether::sfm::GatherSelectedSidecarByRowsV1;
using aether::sfm::SelectedSidecarGatherStatusV1;
using aether::sfm::SelectCanonicalFeaturesV1;
using aether::sfm::SelectCoverageFeaturesV1;

[[noreturn]] void Fail(std::string_view message) {
    std::cerr << "FAIL canonical_feature_selector_v1: " << message << "\n";
    std::abort();
}

void Check(bool condition, std::string_view message) {
    if (!condition) Fail(message);
}

uint32_t FloatBits(float value) {
    return std::bit_cast<uint32_t>(value);
}

uint32_t IntBits(int32_t value) {
    return std::bit_cast<uint32_t>(value);
}

CanonicalFeatureCandidateV1 Candidate(
    int32_t octave,
    int32_t scale,
    float response,
    float x,
    float y = 2.0f,
    float a11 = 1.0f,
    float a12 = 0.0f,
    float a21 = 0.0f,
    float a22 = 1.0f,
    float orientation = 0.0f) {
    CanonicalFeatureCandidateV1 candidate;
    candidate.oriented_words = {
        FloatBits(x),   FloatBits(y),   FloatBits(a11), FloatBits(a12),
        FloatBits(a21), FloatBits(a22), IntBits(octave), IntBits(scale)};
    candidate.response_bits = FloatBits(response);
    candidate.orientation_bits = FloatBits(orientation);
    return candidate;
}

bool SameCandidate(const CanonicalFeatureCandidateV1& lhs,
                   const CanonicalFeatureCandidateV1& rhs) {
    return lhs.oriented_words == rhs.oriented_words &&
           lhs.response_bits == rhs.response_bits &&
           lhs.orientation_bits == rhs.orientation_bits;
}

std::vector<CanonicalFeatureCandidateV1> Materialize(
    std::span<const CanonicalFeatureCandidateV1> input,
    const CanonicalFeatureSelectionV1& selection) {
    Check(selection.input_indices.size() == selection.stable_ids.size(),
          "selection vector sizes differ");
    std::vector<CanonicalFeatureCandidateV1> output;
    output.reserve(selection.input_indices.size());
    for (size_t i = 0; i < selection.input_indices.size(); ++i) {
        Check(selection.input_indices[i] < input.size(),
              "selector returned an out-of-range index");
        Check(selection.stable_ids[i] == i, "Stable ID is not canonical rank");
        output.push_back(input[selection.input_indices[i]]);
    }
    return output;
}

CanonicalFeatureSelectionV1 SelectOrFail(
    std::span<const CanonicalFeatureCandidateV1> input,
    uint32_t cap) {
    CanonicalFeatureSelectionV1 selection;
    const auto status = SelectCanonicalFeaturesV1(input, cap, &selection);
    Check(status == CanonicalFeatureSelectionStatusV1::kOk,
          "valid selection returned failure");
    return selection;
}

void CheckSequence(
    std::span<const CanonicalFeatureCandidateV1> actual,
    std::span<const CanonicalFeatureCandidateV1> expected,
    std::string_view message) {
    Check(actual.size() == expected.size(), message);
    for (size_t i = 0; i < actual.size(); ++i) {
        Check(SameCandidate(actual[i], expected[i]), message);
    }
}

uint64_t Digest(std::span<const CanonicalFeatureCandidateV1> candidates) {
    uint64_t value = UINT64_C(1469598103934665603);
    auto mix = [&](uint32_t word) {
        for (int shift = 0; shift < 32; shift += 8) {
            value ^= static_cast<uint8_t>(word >> shift);
            value *= UINT64_C(1099511628211);
        }
    };
    for (const auto& candidate : candidates) {
        for (uint32_t word : candidate.oriented_words) mix(word);
        mix(candidate.response_bits);
        mix(candidate.orientation_bits);
    }
    return value;
}

void TestCountsAndRanks() {
    const std::vector<CanonicalFeatureCandidateV1> input = {
        Candidate(1, 1, 3.0f, 3.0f),
        Candidate(1, 1, 2.0f, 2.0f),
        Candidate(1, 1, 1.0f, 1.0f),
    };
    Check(Materialize(input, SelectOrFail(input, 0)).empty(), "cap zero");
    Check(Materialize({}, SelectOrFail({}, 7)).empty(), "empty input");
    Check(Materialize(input, SelectOrFail(input, 5)).size() == 3,
          "input below cap");
    Check(Materialize(input, SelectOrFail(input, 3)).size() == 3,
          "input at cap");
    Check(Materialize(input, SelectOrFail(input, 2)).size() == 2,
          "input above cap");
}

void TestPriorityAndBitOrder() {
    const auto low_octave = Candidate(-2, 99, 99.0f, 9.0f);
    const auto high_octave = Candidate(-1, -99, 1.0f, 8.0f);
    const auto actual_octave =
        Materialize(std::vector{low_octave, high_octave},
                    SelectOrFail(std::vector{low_octave, high_octave}, 2));
    Check(SameCandidate(actual_octave[0], high_octave),
          "signed octave is not descending");

    const auto low_scale = Candidate(2, -2, 99.0f, 7.0f);
    const auto high_scale = Candidate(2, -1, 1.0f, 6.0f);
    const std::vector scale_input{low_scale, high_scale};
    const auto actual_scale =
        Materialize(scale_input, SelectOrFail(scale_input, 2));
    Check(SameCandidate(actual_scale[0], high_scale),
          "signed scale is not descending");

    const auto low_response = Candidate(2, 3, -1.0f, 5.0f);
    const auto high_response = Candidate(2, 3, 2.0f, 4.0f);
    const std::vector response_input{low_response, high_response};
    const auto actual_response =
        Materialize(response_input, SelectOrFail(response_input, 2));
    Check(SameCandidate(actual_response[0], high_response),
          "response is not descending");

    const auto negative_zero = Candidate(2, 3, 2.0f, -0.0f);
    const auto positive_zero = Candidate(2, 3, 2.0f, +0.0f);
    const std::vector zero_input{positive_zero, negative_zero};
    const auto actual_zero = Materialize(zero_input, SelectOrFail(zero_input, 2));
    Check(SameCandidate(actual_zero[0], negative_zero),
          "signed-zero order is not bit-defined");

    const auto zero = Candidate(2, 3, 2.0f, 0.0f);
    const auto subnormal =
        Candidate(2, 3, 2.0f, std::numeric_limits<float>::denorm_min());
    const std::vector subnormal_input{subnormal, zero};
    const auto actual_subnormal =
        Materialize(subnormal_input, SelectOrFail(subnormal_input, 2));
    Check(SameCandidate(actual_subnormal[0], zero),
          "subnormal was normalized or ordered incorrectly");

    const auto theta_low = Candidate(2, 3, 2.0f, 1.0f, 2.0f, 1.0f, 0.0f,
                                     0.0f, 1.0f, -0.25f);
    const auto theta_high = Candidate(2, 3, 2.0f, 1.0f, 2.0f, 1.0f, 0.0f,
                                      0.0f, 1.0f, 0.25f);
    const std::vector theta_input{theta_high, theta_low};
    const auto actual_theta =
        Materialize(theta_input, SelectOrFail(theta_input, 2));
    Check(SameCandidate(actual_theta[0], theta_low),
          "orientation tie-break is not ascending");
}

void TestPermutationDeterminismAndDuplicates() {
    const auto duplicate = Candidate(4, 7, 11.0f, 1.0f);
    std::vector<CanonicalFeatureCandidateV1> source = {
        Candidate(5, 1, 4.0f, 9.0f),
        duplicate,
        Candidate(4, 7, 12.0f, 3.0f),
        duplicate,
        Candidate(3, 9, 99.0f, 4.0f),
        duplicate,
        Candidate(-1, 2, 7.0f, 5.0f),
    };
    const auto baseline = Materialize(source, SelectOrFail(source, 4));
    std::mt19937 random(0xA37E8192u);
    for (int iteration = 0; iteration < 100; ++iteration) {
        std::shuffle(source.begin(), source.end(), random);
        const auto selected = Materialize(source, SelectOrFail(source, 4));
        CheckSequence(selected, baseline,
                      "same multiset produced permutation-dependent bytes");
    }

    const std::vector duplicate_input{duplicate, duplicate, duplicate};
    const auto duplicate_output =
        Materialize(duplicate_input, SelectOrFail(duplicate_input, 2));
    Check(duplicate_output.size() == 2, "duplicate cap is not exact");
    Check(SameCandidate(duplicate_output[0], duplicate) &&
              SameCandidate(duplicate_output[1], duplicate),
          "duplicate output bytes changed");
}

void TestInvalidInputClearsStaleOutput() {
    for (int field = 0; field < 4; ++field) {
        for (float invalid : {std::numeric_limits<float>::quiet_NaN(),
                              std::numeric_limits<float>::infinity(),
                              -std::numeric_limits<float>::infinity()}) {
            auto candidate = Candidate(1, 1, 1.0f, 1.0f);
            const uint32_t invalid_bits = FloatBits(invalid);
            switch (field) {
                case 0:
                    candidate.oriented_words[0] = invalid_bits;
                    break;
                case 1:
                    candidate.oriented_words[5] = invalid_bits;
                    break;
                case 2:
                    candidate.response_bits = invalid_bits;
                    break;
                default:
                    candidate.orientation_bits = invalid_bits;
                    break;
            }
            CanonicalFeatureSelectionV1 output;
            output.input_indices = {41u};
            output.stable_ids = {99u};
            const auto status = SelectCanonicalFeaturesV1(
                std::span<const CanonicalFeatureCandidateV1>(&candidate, 1), 1,
                &output);
            Check(
                status ==
                    CanonicalFeatureSelectionStatusV1::kNonFiniteCandidate,
                "non-finite candidate field was accepted");
            Check(output.input_indices.empty() && output.stable_ids.empty(),
                  "failure exposed stale output");
        }
    }
    Check(SelectCanonicalFeaturesV1({}, 0, nullptr) ==
              CanonicalFeatureSelectionStatusV1::kNullOutput,
          "null output status mismatch");
}

void TestPolicyParser() {
    const auto absent = ParseFeatureSelectionPolicyV1(nullptr);
    Check(absent.policy == FeatureSelectionPolicyV1::kLegacyColmapGroup &&
              absent.reason == FeatureSelectionPolicyReasonV1::kAbsent,
          "absent policy did not fail closed to legacy");

    const auto legacy =
        ParseFeatureSelectionPolicyV1("legacy_colmap_group_v1");
    Check(
        legacy.policy == FeatureSelectionPolicyV1::kLegacyColmapGroup &&
            legacy.reason ==
                FeatureSelectionPolicyReasonV1::kExplicitLegacy,
        "explicit legacy policy parse failed");

    const auto canonical =
        ParseFeatureSelectionPolicyV1("canonical_exact_8192_v1");
    Check(
        canonical.policy == FeatureSelectionPolicyV1::kCanonicalExact8192 &&
            canonical.reason ==
                FeatureSelectionPolicyReasonV1::kExplicitCanonical,
        "canonical policy parse failed");

    const auto coverage =
        ParseFeatureSelectionPolicyV1("coverage_exact_8192_v1");
    Check(
        coverage.policy == FeatureSelectionPolicyV1::kCoverageExact8192 &&
            coverage.reason ==
                FeatureSelectionPolicyReasonV1::kExplicitCoverage,
        "coverage policy parse failed");

    for (const char* invalid :
         {"", "CANONICAL_EXACT_8192_V1", "canonical_exact_8192_v1 ",
          "shadow_compare_v1", "1"}) {
        const auto decision = ParseFeatureSelectionPolicyV1(invalid);
        Check(decision.policy ==
                      FeatureSelectionPolicyV1::kLegacyColmapGroup &&
                  decision.reason ==
                      FeatureSelectionPolicyReasonV1::kInvalidValue,
              "invalid policy did not fail closed to legacy");
    }
}

void TestCoverageSelectorSpreadsBeforeDeepening() {
    // Four very strong candidates are concentrated in the first cell. A pure
    // quality top-4 would keep only that cell; coverage must keep one candidate
    // from each occupied cell before taking a second candidate anywhere.
    const std::vector<CanonicalFeatureCandidateV1> input = {
        Candidate(9, 9, 100.0f, 1.0f, 1.0f),
        Candidate(9, 8, 99.0f, 1.5f, 1.5f),
        Candidate(9, 7, 98.0f, 2.0f, 2.0f),
        Candidate(9, 6, 97.0f, 2.5f, 2.5f),
        Candidate(1, 1, 3.0f, 40.0f, 1.0f),
        Candidate(1, 1, 2.0f, 1.0f, 40.0f),
        Candidate(1, 1, 1.0f, 40.0f, 40.0f),
    };
    CanonicalFeatureSelectionV1 selection;
    Check(SelectCoverageFeaturesV1(input, 4, 100, 100, &selection) ==
              CanonicalFeatureSelectionStatusV1::kOk,
          "coverage selection failed");
    Check(selection.input_indices == std::vector<uint32_t>({0u, 4u, 5u, 6u}),
          "coverage did not spread across occupied cells");
    Check(selection.stable_ids == std::vector<uint64_t>({0u, 1u, 2u, 3u}),
          "coverage Stable IDs are not canonical ranks");

    Check(SelectCoverageFeaturesV1(input, 5, 100, 100, &selection) ==
              CanonicalFeatureSelectionStatusV1::kOk,
          "coverage depth-two selection failed");
    Check(selection.input_indices ==
              std::vector<uint32_t>({0u, 1u, 4u, 5u, 6u}),
          "coverage did not deepen only after covering cells");
}

void TestCoverageSelectorIsPermutationDeterministic() {
    std::vector<CanonicalFeatureCandidateV1> source = {
        Candidate(4, 1, 8.0f, 2.0f, 2.0f),
        Candidate(3, 1, 7.0f, 3.0f, 3.0f),
        Candidate(2, 1, 6.0f, 35.0f, 3.0f),
        Candidate(1, 1, 5.0f, 66.0f, 3.0f),
        Candidate(0, 1, 4.0f, 3.0f, 66.0f),
    };
    CanonicalFeatureSelectionV1 selection;
    Check(SelectCoverageFeaturesV1(source, 4, 100, 100, &selection) ==
              CanonicalFeatureSelectionStatusV1::kOk,
          "coverage baseline failed");
    const auto baseline = Materialize(source, selection);
    std::mt19937 random(0xC0A3E819u);
    for (int iteration = 0; iteration < 100; ++iteration) {
        std::shuffle(source.begin(), source.end(), random);
        Check(SelectCoverageFeaturesV1(source, 4, 100, 100, &selection) ==
                  CanonicalFeatureSelectionStatusV1::kOk,
              "coverage shuffled selection failed");
        CheckSequence(Materialize(source, selection), baseline,
                      "coverage changed under input permutation");
    }

    selection.input_indices = {7u};
    selection.stable_ids = {7u};
    Check(SelectCoverageFeaturesV1(source, 4, 0, 100, &selection) ==
              CanonicalFeatureSelectionStatusV1::kInvalidImageExtent &&
              selection.input_indices.empty() && selection.stable_ids.empty(),
          "invalid coverage extent did not fail closed");
}

void TestSidecarCandidateBuilder() {
    const std::vector<uint32_t> affine = {
        FloatBits(10.0f), FloatBits(11.0f), FloatBits(1.5f),
        FloatBits(4.0f), FloatBits(0.1f), IntBits(1), IntBits(2), 0u,
        FloatBits(20.0f), FloatBits(21.0f), FloatBits(2.5f),
        FloatBits(8.0f), FloatBits(0.2f), IntBits(3), IntBits(4), 0u,
    };
    const std::vector<uint32_t> oriented = {
        affine[8], affine[9], FloatBits(2.0f), FloatBits(0.1f),
        FloatBits(0.2f), FloatBits(2.1f), affine[13], affine[14],
        affine[0], affine[1], FloatBits(1.0f), FloatBits(0.3f),
        FloatBits(0.4f), FloatBits(1.1f), affine[5], affine[6],
    };
    const std::vector<uint32_t> sidecar = {
        FloatBits(1.0f), FloatBits(0.5f),
        FloatBits(0.0f), FloatBits(-0.25f),
    };
    std::vector<CanonicalFeatureCandidateV1> candidates;
    Check(BuildCanonicalCandidatesFromSidecarV1(
              oriented, sidecar, affine, &candidates) ==
              CanonicalCandidateBuildStatusV1::kOk,
          "valid sidecar candidate build failed");
    Check(candidates.size() == 2, "sidecar candidate count mismatch");
    Check(candidates[0].response_bits == affine[11] &&
              candidates[0].orientation_bits == sidecar[1] &&
              candidates[1].response_bits == affine[3] &&
              candidates[1].orientation_bits == sidecar[3],
          "sidecar source mapping changed candidate metadata");

    auto expect_failure = [&](std::vector<uint32_t> bad_oriented,
                              std::vector<uint32_t> bad_sidecar,
                              CanonicalCandidateBuildStatusV1 expected) {
        std::vector<CanonicalFeatureCandidateV1> stale = {
            Candidate(9, 9, 9.0f, 9.0f)};
        const auto status = BuildCanonicalCandidatesFromSidecarV1(
            bad_oriented, bad_sidecar, affine, &stale);
        Check(status == expected, "sidecar failure status mismatch");
        Check(stale.empty(), "sidecar failure exposed stale candidates");
    };

    expect_failure(oriented, {FloatBits(0.0f)},
                   CanonicalCandidateBuildStatusV1::kInvalidBufferShape);
    auto non_finite = sidecar;
    non_finite[0] = FloatBits(std::numeric_limits<float>::quiet_NaN());
    expect_failure(oriented, non_finite,
                   CanonicalCandidateBuildStatusV1::kNonFiniteSourceIndex);
    auto fractional = sidecar;
    fractional[0] = FloatBits(0.5f);
    expect_failure(oriented, fractional,
                   CanonicalCandidateBuildStatusV1::kNonIntegralSourceIndex);
    auto out_of_range = sidecar;
    out_of_range[0] = FloatBits(2.0f);
    expect_failure(oriented, out_of_range,
                   CanonicalCandidateBuildStatusV1::kSourceIndexOutOfRange);
    auto mismatch = oriented;
    mismatch[0] = FloatBits(99.0f);
    expect_failure(mismatch, sidecar,
                   CanonicalCandidateBuildStatusV1::kSourceRecordMismatch);
    Check(BuildCanonicalCandidatesFromSidecarV1(
              oriented, sidecar, affine, nullptr) ==
              CanonicalCandidateBuildStatusV1::kNullOutput,
          "sidecar null-output status mismatch");
}

void TestCanonicalRowGather() {
    constexpr uint32_t kStride = 4;
    const std::vector<uint32_t> rows = {
        10u, 11u, 12u, 13u,
        20u, 21u, 22u, 23u,
        30u, 31u, 32u, 33u,
    };
    const std::vector<uint32_t> order = {2u, 0u};
    std::vector<uint32_t> gathered;
    Check(GatherCanonicalRowsV1(rows, kStride, order, &gathered) ==
              CanonicalRowGatherStatusV1::kOk,
          "canonical row gather failed");
    Check(gathered == std::vector<uint32_t>({30u, 31u, 32u, 33u,
                                             10u, 11u, 12u, 13u}),
          "canonical row order/payload alignment changed");

    gathered = {99u};
    Check(GatherCanonicalRowsV1(rows, 0u, order, &gathered) ==
              CanonicalRowGatherStatusV1::kInvalidBufferShape &&
              gathered.empty(),
          "zero-stride row gather exposed stale output");
    gathered = {99u};
    Check(GatherCanonicalRowsV1(rows, kStride, std::vector<uint32_t>{3u},
                                &gathered) ==
              CanonicalRowGatherStatusV1::kIndexOutOfRange &&
              gathered.empty(),
          "out-of-range row gather exposed stale output");
    Check(GatherCanonicalRowsV1(rows, kStride, order, nullptr) ==
              CanonicalRowGatherStatusV1::kNullOutput,
          "row gather null-output status mismatch");
}

void TestSelectedSidecarGatherUsesExactRows() {
    const std::vector<uint32_t> full_rows = {
        10u, 11u, 12u, 13u, 14u, 15u, 16u, 17u,
        20u, 21u, 22u, 23u, 24u, 25u, 26u, 27u,
        30u, 31u, 32u, 33u, 34u, 35u, 36u, 37u,
    };
    const std::vector<uint32_t> sidecar = {
        FloatBits(0.0f), FloatBits(0.1f),
        FloatBits(2.0f), FloatBits(0.2f),
        FloatBits(1.0f), FloatBits(0.3f),
    };
    const std::vector<uint32_t> selected_rows = {
        30u, 31u, 32u, 33u, 34u, 35u, 36u, 37u,
        20u, 21u, 22u, 23u, 24u, 25u, 26u, 27u,
    };
    std::vector<uint32_t> gathered;
    Check(GatherSelectedSidecarByRowsV1(full_rows, selected_rows, sidecar,
                                        &gathered) ==
              SelectedSidecarGatherStatusV1::kOk,
          "selected sidecar gather failed");
    Check(gathered == std::vector<uint32_t>({FloatBits(1.0f), FloatBits(0.3f),
                                              FloatBits(2.0f), FloatBits(0.2f)}),
          "selected sidecar did not follow exact row identity");

    gathered = {99u};
    const std::vector<uint32_t> missing_row = {
        99u, 98u, 97u, 96u, 95u, 94u, 93u, 92u,
    };
    Check(GatherSelectedSidecarByRowsV1(full_rows, missing_row, sidecar,
                                        &gathered) ==
              SelectedSidecarGatherStatusV1::kSelectedRowMissing &&
              gathered.empty(),
          "missing selected row did not fail closed");
}

}  // namespace

int main() {
    TestCountsAndRanks();
    TestPriorityAndBitOrder();
    TestPermutationDeterminismAndDuplicates();
    TestInvalidInputClearsStaleOutput();
    TestPolicyParser();
    TestCoverageSelectorSpreadsBeforeDeepening();
    TestCoverageSelectorIsPermutationDeterministic();
    TestSidecarCandidateBuilder();
    TestCanonicalRowGather();
    TestSelectedSidecarGatherUsesExactRows();
    const std::vector digest_input{
        Candidate(2, 3, 4.0f, -0.0f),
        Candidate(2, 3, 4.0f, +0.0f),
        Candidate(-1, 7, 9.0f, 3.0f),
    };
    const auto selected =
        Materialize(digest_input, SelectOrFail(digest_input, 3));
    std::cout << "PASS canonical_feature_selector_v1 digest=" << std::hex
              << Digest(selected) << "\n";
    return 0;
}
