#include "aether_birth_ownership_c.h"

#include <cassert>
#include <cstdint>
#include <vector>

namespace {

std::vector<float> make_partitioned_planes(float partition_two_y) {
    std::vector<float> sparse;
    for (int sample = -16; sample <= 16; ++sample) {
        const float x = static_cast<float>(sample) * 0.006f;
        const float z = static_cast<float>((sample * sample + 3 * sample) % 13)
            * 0.005f - 0.03f;
        // For each unique x, lexicographic XYZ order assigns these points to
        // partitions 0, 1 and 2 respectively.
        sparse.insert(sparse.end(), {x, -0.002f, z});
        sparse.insert(sparse.end(), {x, 0.002f, z});
        sparse.insert(sparse.end(), {x, partition_two_y, z});
    }
    return sparse;
}

aether_local_manifold_session_t* create_certificate_session(
    const std::vector<float>& sparse) {
    aether_local_manifold_options_t options{};
    aether_local_manifold_options_default(&options);
    options.maximum_nearest_m = 0.06;
    options.maximum_neighbor_radius_m = 0.15;
    options.maximum_neighbor_rms_m = 0.01;
    options.maximum_perpendicular_m = 0.02;
    aether_local_manifold_session_t* session = nullptr;
    assert(aether_local_manifold_session_create(
               sparse.data(), static_cast<int32_t>(sparse.size() / 3),
               &options, &session) == AETHER_BIRTH_OWNERSHIP_OK);
    assert(session != nullptr);
    return session;
}

void test_dual_partition_local_manifold_birth_gate() {
    std::vector<float> sparse;
    for (int ix = -20; ix <= 20; ++ix) {
        for (int iz = -20; iz <= 20; ++iz) {
            sparse.push_back(static_cast<float>(ix) * 0.02f);
            sparse.push_back(0.0f);
            sparse.push_back(static_cast<float>(iz) * 0.02f);
        }
    }
    aether_local_manifold_options_t options{};
    aether_local_manifold_options_default(&options);
    options.maximum_nearest_m = 0.06;
    options.maximum_neighbor_radius_m = 0.12;
    options.maximum_neighbor_rms_m = 0.005;
    options.maximum_perpendicular_m = 0.01;
    aether_local_manifold_session_t* session = nullptr;
    assert(aether_local_manifold_session_create(
               sparse.data(), static_cast<int32_t>(sparse.size() / 3),
               &options, &session) == AETHER_BIRTH_OWNERSHIP_OK);
    assert(session != nullptr);

    const float candidates[] = {
        0.0f, 0.0f, 0.0f,
        0.03f, 0.005f, -0.02f,
        0.0f, 0.03f, 0.0f,
        0.02f, 0.0f, 0.02f,
        2.0f, 0.0f, 2.0f,
    };
    const std::uint8_t eligible[] = {1, 1, 1, 0, 1};
    std::uint8_t first[5]{};
    std::uint8_t second[5]{};
    std::uint8_t birth[5]{};
    assert(aether_local_manifold_session_filter(
               session, candidates, 5, eligible, first, second, birth, 5) ==
           AETHER_BIRTH_OWNERSHIP_OK);
    assert(first[0] == 1 && second[0] == 1 && birth[0] == 1);
    assert(first[1] == 1 && second[1] == 1 && birth[1] == 1);
    assert(birth[2] == 0);  // Perpendicular offset exceeds the birth gate.
    assert(first[3] == 0 && second[3] == 0 && birth[3] == 0);
    assert(birth[4] == 0);  // No nearby sparse support.
    aether_local_manifold_session_free(session);
}

void test_non_certificate_partition_count_keeps_legacy_search_path() {
    std::vector<float> sparse;
    for (int ix = -20; ix <= 20; ++ix) {
        for (int iz = -20; iz <= 20; ++iz) {
            sparse.insert(sparse.end(), {
                static_cast<float>(ix) * 0.02f,
                0.0f,
                static_cast<float>(iz) * 0.02f});
        }
    }
    aether_local_manifold_options_t options{};
    aether_local_manifold_options_default(&options);
    options.partition_count = 4;
    options.first_partition = 0;
    options.second_partition = 3;
    options.maximum_nearest_m = 0.06;
    options.maximum_neighbor_radius_m = 0.12;
    options.maximum_neighbor_rms_m = 0.005;
    options.maximum_perpendicular_m = 0.01;
    aether_local_manifold_session_t* session = nullptr;
    assert(aether_local_manifold_session_create(
               sparse.data(), static_cast<int32_t>(sparse.size() / 3),
               &options, &session) == AETHER_BIRTH_OWNERSHIP_OK);
    const float candidate[] = {0.0f, 0.0f, 0.0f};
    std::uint8_t first[1]{};
    std::uint8_t second[1]{};
    std::uint8_t birth[1]{};
    assert(aether_local_manifold_session_filter(
               session, candidate, 1, nullptr, first, second, birth, 1) ==
           AETHER_BIRTH_OWNERSHIP_OK);
    assert(first[0] == 1 && second[0] == 1 && birth[0] == 1);
    aether_local_manifold_session_free(session);
}

void test_finite_certified_wall_owns_only_its_domain() {
    aether_structural_wall_t wall{};
    wall.certified = 1;
    wall.normal_xyz[0] = 1.0;
    wall.basis_u_xyz[2] = 1.0;
    wall.basis_v_xyz[1] = 1.0;
    wall.plane_value_n_dot_x = 1.0;
    wall.bounds_u_m[0] = -1.0;
    wall.bounds_u_m[1] = 1.0;
    wall.bounds_height_m[0] = 0.0;
    wall.bounds_height_m[1] = 2.0;
    const float candidates[] = {
        1.05f, 1.0f, 0.0f,
        1.20f, 1.0f, 0.0f,
        1.05f, 3.0f, 0.0f,
        1.05f, 1.0f, 2.0f,
    };
    std::uint8_t owned[4]{};
    assert(aether_filter_finite_wall_ownership(
               candidates, 4, 0.0, &wall, 1, 0.08, 0.05, owned, 4) ==
           AETHER_BIRTH_OWNERSHIP_OK);
    assert(owned[0] == 1);
    assert(owned[1] == 0);
    assert(owned[2] == 0);
    assert(owned[3] == 0);

    wall.certified = 0;
    assert(aether_filter_finite_wall_ownership(
               candidates, 4, 0.0, &wall, 1, 0.08, 0.05, owned, 4) ==
           AETHER_BIRTH_OWNERSHIP_OK);
    for (const auto value : owned) assert(value == 0);
}

void test_finite_selected_floor_owns_band_and_underfloor_domain() {
    aether_finite_floor_domain_t floor{};
    floor.certified = 1;
    floor.normal_xyz[1] = 1.0;
    floor.basis_u_xyz[0] = 1.0;
    floor.basis_v_xyz[2] = 1.0;
    floor.bounds_u_m[0] = -1.0;
    floor.bounds_u_m[1] = 1.0;
    floor.bounds_v_m[0] = -1.0;
    floor.bounds_v_m[1] = 1.0;
    const float candidates[] = {
        0.0f, 0.05f, 0.0f,
        0.0f, 0.20f, 0.0f,
        0.0f, -3.00f, 0.0f,
        2.0f, 0.00f, 0.0f,
    };
    std::uint8_t owned[4]{};
    assert(aether_filter_finite_floor_ownership(
               candidates, 4, &floor, 0.08, 0.05, owned, 4) ==
           AETHER_BIRTH_OWNERSHIP_OK);
    assert(owned[0] == 1);  // Near-floor positive-side retention band.
    assert(owned[1] == 0);  // Above the floor's owned slab.
    assert(owned[2] == 1);  // Under-floor layers can never be D-owned.
    assert(owned[3] == 0);  // Finite floor domain, not an infinite plane.

    floor.certified = 0;
    assert(aether_filter_finite_floor_ownership(
               candidates, 4, &floor, 0.08, 0.05, owned, 4) ==
           AETHER_BIRTH_OWNERSHIP_OK);
    for (const auto value : owned) assert(value == 0);
}

void test_invalid_contract_fails_closed() {
    aether_local_manifold_options_t options{};
    aether_local_manifold_options_default(&options);
    options.first_partition = options.second_partition;
    const float sparse[24]{};
    aether_local_manifold_session_t* session = nullptr;
    assert(aether_local_manifold_session_create(
               sparse, 8, &options, &session) ==
           AETHER_BIRTH_OWNERSHIP_ERR_BAD_ARGS);
    assert(session == nullptr);
}

void test_reference_certificate_publishes_only_certified_births() {
    const auto sparse = make_partitioned_planes(0.006f);
    aether_local_manifold_session_t* session =
        create_certificate_session(sparse);
    const float candidates[] = {
        0.000f, 0.002f, 0.000f,
        0.018f, 0.001f, 0.005f,
        0.030f, 0.001f, 0.000f,
    };
    const std::uint8_t eligible[] = {1, 1, 0};
    std::uint8_t birth[5] = {9, 9, 9, 9, 9};
    aether_reference_birth_certificate_result_t result{};
    assert(aether_local_manifold_session_filter_reference_certified(
               session, candidates, 3, eligible, 2, birth, 5, &result) ==
           AETHER_BIRTH_OWNERSHIP_OK);
    assert(result.failed_fold_mask == 0);
    assert(result.pre_certificate_birth_count == 2);
    assert(result.blocked_birth_count == 0);
    assert(result.final_birth_count == 2);
    assert(birth[0] == 1 && birth[1] == 1 && birth[2] == 0);
    assert(birth[3] == 0 && birth[4] == 0);
    aether_local_manifold_session_free(session);
}

void test_reference_certificate_preserves_legacy_production_mask_exactly() {
    const auto sparse = make_partitioned_planes(0.006f);
    aether_local_manifold_session_t* session =
        create_certificate_session(sparse);
    std::vector<float> candidates;
    std::vector<std::uint8_t> eligible;
    for (int sample = -20; sample <= 20; ++sample) {
        candidates.insert(candidates.end(), {
            static_cast<float>(sample) * 0.006f,
            static_cast<float>(sample % 5) * 0.004f,
            static_cast<float>((sample * 7) % 11) * 0.003f});
        eligible.push_back(sample % 7 == 0 ? 0 : 1);
    }
    const int32_t count = static_cast<int32_t>(eligible.size());
    std::vector<std::uint8_t> first(static_cast<std::size_t>(count));
    std::vector<std::uint8_t> second(static_cast<std::size_t>(count));
    std::vector<std::uint8_t> legacy_birth(static_cast<std::size_t>(count));
    std::vector<std::uint8_t> certified_birth(static_cast<std::size_t>(count));
    assert(aether_local_manifold_session_filter(
               session, candidates.data(), count, eligible.data(),
               first.data(), second.data(), legacy_birth.data(), count) ==
           AETHER_BIRTH_OWNERSHIP_OK);
    aether_reference_birth_certificate_result_t result{};
    assert(aether_local_manifold_session_filter_reference_certified(
               session, candidates.data(), count, eligible.data(), 2,
               certified_birth.data(), count, &result) ==
           AETHER_BIRTH_OWNERSHIP_OK);
    int32_t legacy_birth_count = 0;
    for (int32_t index = 0; index < count; ++index) {
        assert(legacy_birth[static_cast<std::size_t>(index)] ==
               (first[static_cast<std::size_t>(index)] &&
                second[static_cast<std::size_t>(index)] ? 1 : 0));
        legacy_birth_count +=
            legacy_birth[static_cast<std::size_t>(index)] != 0 ? 1 : 0;
    }
    assert(result.pre_certificate_birth_count == legacy_birth_count);
    if (result.failed_fold_mask == 0) {
        assert(certified_birth == legacy_birth);
    } else {
        for (const auto born : certified_birth) assert(born == 0);
    }
    aether_local_manifold_session_free(session);
}

void test_reference_certificate_blocks_before_identity_on_any_failed_fold() {
    const auto sparse = make_partitioned_planes(1.0f);
    aether_local_manifold_session_t* session =
        create_certificate_session(sparse);
    const float candidates[] = {
        0.000f, 0.000f, 0.000f,  // Supported by partitions 0 and 1.
        0.000f, 1.000f, 0.000f,  // Truth-favored by blind partition 2.
    };
    std::uint8_t birth[2] = {9, 9};
    aether_reference_birth_certificate_result_t result{};
    assert(aether_local_manifold_session_filter_reference_certified(
               session, candidates, 2, nullptr, 2, birth, 2, &result) ==
           AETHER_BIRTH_OWNERSHIP_OK);
    assert((result.failed_fold_mask & (UINT32_C(1) << 2)) != 0);
    assert(result.pre_certificate_birth_count == 1);
    assert(result.blocked_birth_count == 1);
    assert(result.final_birth_count == 0);
    assert(birth[0] == 0 && birth[1] == 0);
    aether_local_manifold_session_free(session);
}

void test_reference_certificate_accepts_zero_birth_reference() {
    const auto sparse = make_partitioned_planes(0.006f);
    aether_local_manifold_session_t* session =
        create_certificate_session(sparse);
    const float candidates[] = {4.0f, 4.0f, 4.0f};
    std::uint8_t birth[1] = {9};
    aether_reference_birth_certificate_result_t result{};
    assert(aether_local_manifold_session_filter_reference_certified(
               session, candidates, 1, nullptr, 2, birth, 1, &result) ==
           AETHER_BIRTH_OWNERSHIP_OK);
    assert(result.failed_fold_mask == 0);
    assert(result.pre_certificate_birth_count == 0);
    assert(result.blocked_birth_count == 0);
    assert(result.final_birth_count == 0);
    assert(birth[0] == 0);
    aether_local_manifold_session_free(session);
}

}  // namespace

int main() {
    test_dual_partition_local_manifold_birth_gate();
    test_non_certificate_partition_count_keeps_legacy_search_path();
    test_reference_certificate_publishes_only_certified_births();
    test_reference_certificate_preserves_legacy_production_mask_exactly();
    test_reference_certificate_blocks_before_identity_on_any_failed_fold();
    test_reference_certificate_accepts_zero_birth_reference();
    test_finite_certified_wall_owns_only_its_domain();
    test_finite_selected_floor_owns_band_and_underfloor_domain();
    test_invalid_contract_fails_closed();
    return 0;
}
