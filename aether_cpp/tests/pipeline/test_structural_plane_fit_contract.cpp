#include "aether_structural_plane_fit_c.h"

#include <array>
#include <cassert>
#include <cmath>
#include <vector>

namespace {

void test_bad_arguments_fail_closed() {
    aether_structural_plane_fit_options_t options{};
    aether_structural_plane_fit_options_default(&options);
    int count = -1;
    const double floor[3] = {0.0, 1.0, 0.0};
    assert(aether_structural_fit_walls(
               nullptr, 0, floor, 0.0, &options, nullptr, 0, &count) == 1);
    aether_structural_floor_t fitted{};
    assert(aether_structural_fit_floor(nullptr, 0, floor, &fitted) == 1);
}

void test_floor_fit_is_gravity_guided_and_outlier_robust() {
    std::vector<float> xyz;
    auto append = [&](double x, double y, double z) {
        xyz.push_back(static_cast<float>(x));
        xyz.push_back(static_cast<float>(y));
        xyz.push_back(static_cast<float>(z));
    };
    // y = 0.12 + 0.01x - 0.006z, sampled broadly enough to certify.
    for (int ix = 0; ix <= 40; ++ix) {
        const double x = -2.0 + 0.1 * ix;
        for (int iz = 0; iz <= 30; ++iz) {
            const double z = -1.5 + 0.1 * iz;
            const double jitter = ((ix * 17 + iz * 13) % 7 - 3) * 0.0004;
            append(x, 0.12 + 0.01 * x - 0.006 * z + jitter, z);
        }
    }
    // Sparse non-floor structure must not pull the modal fit away.
    for (int index = 0; index < 300; ++index) {
        append(-2.0 + 0.013 * index, 0.5 + 0.006 * index,
               -1.5 + 0.009 * index);
    }
    const double up[3] = {0.0, 1.0, 0.0};
    aether_structural_floor_t floor{};
    assert(aether_structural_fit_floor(
               xyz.data(), static_cast<int>(xyz.size() / 3), up, &floor) == 0);
    assert(floor.certified == 1);
    assert(floor.support_points >= 1200);
    assert(floor.coverage_cells_10cm >= 700);
    assert(floor.rms_error_m < 0.002);
    const double normal_length = std::sqrt(
        floor.normal_xyz[0] * floor.normal_xyz[0] +
        floor.normal_xyz[1] * floor.normal_xyz[1] +
        floor.normal_xyz[2] * floor.normal_xyz[2]);
    assert(std::fabs(normal_length - 1.0) < 1e-9);
    assert(floor.normal_xyz[1] > 0.99);
    assert(std::fabs(floor.value_n_dot_x - 0.12) < 0.003);
}

void test_parallel_floor_layers_remain_separate_proposals() {
    std::vector<float> xyz;
    auto append = [&](double x, double y, double z) {
        xyz.push_back(static_cast<float>(x));
        xyz.push_back(static_cast<float>(y));
        xyz.push_back(static_cast<float>(z));
    };
    for (int ix = 0; ix <= 30; ++ix) {
        const double x = -1.5 + 0.1 * ix;
        for (int iz = 0; iz <= 25; ++iz) {
            const double z = -1.25 + 0.1 * iz;
            append(x, -0.60 + ((ix + iz) % 3 - 1) * 0.0003, z);
            if ((ix + iz) % 2 == 0) {
                append(x, -0.37 + ((ix * 3 + iz) % 3 - 1) * 0.0003, z);
            }
        }
    }
    // Above-floor structure defines a realistic scene height envelope; both
    // parallel layers still lie in the gravity-low proposal region.
    for (int index = 0; index < 500; ++index) {
        append(-1.5 + 0.006 * index, 0.4 + 0.002 * (index % 250),
               -1.25 + 0.005 * (index % 500));
    }
    const double up[3] = {0.0, 1.0, 0.0};
    aether_structural_floor_proposal_options_t options{};
    aether_structural_floor_proposal_options_default(&options);
    std::array<aether_structural_floor_proposal_t, 16> proposals{};
    int count = 0;
    assert(aether_structural_propose_floors(
               xyz.data(), static_cast<int>(xyz.size() / 3), up, 0.5,
               &options, proposals.data(), static_cast<int>(proposals.size()),
               &count) == 0);
    assert(count == 2);
    assert(proposals[0].proposal_index == 0);
    assert(proposals[1].proposal_index == 1);
    assert(std::fabs(proposals[0].value_n_dot_x + 0.60) < 0.002);
    assert(std::fabs(proposals[1].value_n_dot_x + 0.37) < 0.002);
    assert(proposals[0].support_points_20mm >
           proposals[1].support_points_20mm);
    assert(proposals[0].coverage_cells_10cm >= 500);
    assert(proposals[1].coverage_cells_10cm >= 300);
}

void test_rectangular_sparse_room_produces_certified_walls() {
    std::vector<float> xyz;
    auto append = [&](double x, double y, double z) {
        xyz.push_back(static_cast<float>(x));
        xyz.push_back(static_cast<float>(y));
        xyz.push_back(static_cast<float>(z));
    };
    // Four dense first-party sparse wall supports plus a ceiling band. Small
    // deterministic texture offsets keep the center plane uniquely prominent
    // over the +/-5cm and +/-10cm certification probes.
    for (int iy = 0; iy <= 40; ++iy) {
        const double y = 0.05 + 0.05 * iy;
        for (int it = 0; it <= 60; ++it) {
            const double t = -1.5 + 0.05 * it;
            append(-2.0, y, t);
            append(2.0, y, t);
            append(t, y, -1.5);
            append(t, y, 1.5);
        }
    }
    for (int ix = 0; ix <= 40; ++ix) {
        for (int iz = 0; iz <= 30; ++iz) {
            append(-2.0 + 0.1 * ix, 2.2, -1.5 + 0.1 * iz);
        }
    }
    aether_structural_plane_fit_options_t options{};
    aether_structural_plane_fit_options_default(&options);
    const double floor[3] = {0.0, 1.0, 0.0};
    std::array<aether_structural_wall_t, 6> walls{};
    int count = 0;
    assert(aether_structural_fit_walls(
               xyz.data(), static_cast<int>(xyz.size() / 3), floor, 0.0,
               &options, walls.data(), static_cast<int>(walls.size()), &count) == 0);
    assert(count >= 2);
    int certified = 0;
    for (int index = 0; index < count; ++index) {
        certified += walls[static_cast<std::size_t>(index)].certified != 0;
        const auto& wall = walls[static_cast<std::size_t>(index)];
        assert(std::fabs(wall.normal_xyz[1]) < 1e-9);
        assert(std::fabs(wall.basis_v_xyz[1] - 1.0) < 1e-9);
    }
    assert(certified >= 2);
}

void test_camera_envelope_proposes_boundaries_but_not_crossing_layer() {
    std::vector<float> xyz;
    auto append = [&](double x, double y, double z) {
        xyz.push_back(static_cast<float>(x));
        xyz.push_back(static_cast<float>(y));
        xyz.push_back(static_cast<float>(z));
    };
    for (int iy = 0; iy <= 40; ++iy) {
        const double y = 0.05 + 0.05 * iy;
        for (int it = 0; it <= 60; ++it) {
            const double t = -1.5 + 0.05 * it;
            append(-2.0, y, t);
            append(2.0, y, t);
            append(t, y, -1.5);
            append(t, y, 1.5);
            // A dense interior layer crosses the camera trajectory and must
            // not survive the envelope proposal gate.
            append(0.0, y, t);
        }
    }
    const std::array<double, 15> cameras = {
        -1.0, 1.0, 0.0,
        -0.5, 1.0, 0.0,
         0.0, 1.0, 0.0,
         0.5, 1.0, 0.0,
         1.0, 1.0, 0.0,
    };
    const double floor[3] = {0.0, 1.0, 0.0};
    aether_structural_envelope_wall_options_t options{};
    aether_structural_envelope_wall_options_default(&options);
    std::array<aether_structural_envelope_wall_t, 32> walls{};
    int count = 0;
    assert(aether_structural_propose_envelope_walls(
               xyz.data(), static_cast<int>(xyz.size() / 3), cameras.data(), 5,
               floor, 0.0, &options, walls.data(),
               static_cast<int>(walls.size()), &count) == 0);
    assert(count >= 4);
    for (int index = 0; index < count; ++index) {
        const auto& wall = walls[static_cast<std::size_t>(index)];
        assert(wall.camera_distance_min_m >= -0.05 ||
               wall.camera_distance_max_m <= 0.05);
        assert(!(std::fabs(wall.normal_xyz[0]) > 0.99 &&
                 std::fabs(wall.plane_value_n_dot_x) < 0.10));
    }
}

}  // namespace

int main() {
    test_bad_arguments_fail_closed();
    test_floor_fit_is_gravity_guided_and_outlier_robust();
    test_parallel_floor_layers_remain_separate_proposals();
    test_rectangular_sparse_room_produces_certified_walls();
    test_camera_envelope_proposes_boundaries_but_not_crossing_layer();
    return 0;
}
