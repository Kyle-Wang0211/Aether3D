#include "aether_structural_candidate_c.h"

#include <array>
#include <cassert>
#include <cmath>
#include <cstdint>
#include <vector>

namespace {

void expect_close(double actual, double expected) {
    assert(std::abs(actual - expected) < 1e-12);
}

aether_structural_frame_t frame(double camera_x) {
    aether_structural_frame_t value{};
    // Camera looks along +Z with a 100px focal length and principal point 50.
    const double projection[12] = {
        100.0, 0.0, 50.0, -100.0 * camera_x,
        0.0, 100.0, 50.0, 0.0,
        0.0, 0.0, 1.0, 0.0,
    };
    for (int index = 0; index < 12; ++index) {
        value.projection_row_major_3x4[index] = projection[index];
    }
    value.camera_center_xyz[0] = camera_x;
    value.width = 100;
    value.height = 100;
    return value;
}

void test_grid_is_u_major_and_center_hypothesis_first() {
    aether_structural_grid_spec_t spec{};
    spec.normal_xyz[2] = 1.0;
    spec.basis_u_xyz[0] = 1.0;
    spec.basis_v_xyz[1] = 1.0;
    spec.plane_value_n_dot_x = 2.0;
    spec.u_min = -0.1;
    spec.u_max = 0.1;
    spec.v_min = 0.0;
    spec.v_max = 0.1;
    spec.grid_m = 0.1;
    int32_t candidates = 0;
    assert(aether_structural_grid_count(&spec, &candidates) == 0);
    assert(candidates == 6);
    const double offsets[] = {0.0, -0.05, 0.05};
    std::vector<double> centers(static_cast<std::size_t>(candidates) * 3);
    std::vector<double> points(static_cast<std::size_t>(candidates) * 9);
    assert(aether_structural_grid_build(
               &spec,
               offsets,
               3,
               centers.data(),
               static_cast<int32_t>(centers.size()),
               points.data(),
               static_cast<int32_t>(points.size())) == 0);
    // v varies fastest, matching numpy meshgrid(indexing="ij").
    expect_close(centers[0], -0.1);
    expect_close(centers[1], 0.0);
    expect_close(centers[2], 2.0);
    expect_close(centers[3], -0.1);
    expect_close(centers[4], 0.1);
    expect_close(centers[5], 2.0);
    expect_close(centers[6], 0.0);
    // The publishable center is hypothesis zero; competitors move only normal.
    expect_close(points[0], centers[0]);
    expect_close(points[1], centers[1]);
    expect_close(points[2], centers[2]);
    expect_close(points[5], 1.95);
    expect_close(points[8], 2.05);

    const double invalid_offsets[] = {0.01};
    assert(aether_structural_grid_build(
               &spec,
               invalid_offsets,
               1,
               centers.data(),
               static_cast<int32_t>(centers.size()),
               points.data(),
               static_cast<int32_t>(points.size())) == 1);
}

void test_per_point_views_are_head_on_then_frame_index() {
    const std::array<aether_structural_frame_t, 3> frames = {
        frame(-0.2), frame(0.2), frame(0.0)};
    const double centers[] = {0.0, 0.0, 2.0};
    const double points[] = {
        0.0, 0.0, 2.0,
        0.0, 0.0, 2.05,
    };
    const double normal[] = {0.0, 0.0, 1.0};
    aether_structural_view_options_t options{};
    aether_structural_view_options_default(&options);
    options.maximum_views = 2;
    std::uint8_t visible[6]{};
    int32_t indices[2]{};
    int32_t counts[1]{};
    assert(aether_structural_prepare_views(
               centers,
               1,
               points,
               2,
               frames.data(),
               3,
               normal,
               &options,
               visible,
               6,
               indices,
               2,
               counts,
               1) == 0);
    assert(counts[0] == 2);
    assert(indices[0] == 2);  // centered camera is most head-on
    assert(indices[1] == 0);  // symmetric tie resolves to lower frame index
    for (std::uint8_t value : visible) {
        assert(value == 1);
    }
}

void test_tile_views_rank_coverage_before_incidence() {
    const std::array<aether_structural_frame_t, 3> frames = {
        frame(-0.4), frame(0.4), frame(0.0)};
    const double centers[] = {
        -0.2, 0.0, 2.0,
        0.2, 0.0, 2.0,
    };
    const double normal[] = {0.0, 0.0, 1.0};
    aether_structural_view_options_t options{};
    aether_structural_view_options_default(&options);
    options.maximum_views = 2;
    options.mode = AETHER_STRUCTURAL_VIEWS_PER_TILE;
    std::uint8_t visible[6]{};
    int32_t indices[4]{};
    int32_t counts[2]{};
    assert(aether_structural_prepare_views(
               centers,
               2,
               centers,
               2,
               frames.data(),
               3,
               normal,
               &options,
               visible,
               6,
               indices,
               4,
               counts,
               2) == 0);
    assert(counts[0] == 2 && counts[1] == 2);
    assert(indices[0] == 2);
    assert(indices[1] == 0);
    assert(indices[2] == indices[0]);
    assert(indices[3] == indices[1]);
}

}  // namespace

int main() {
    test_grid_is_u_major_and_center_hypothesis_first();
    test_per_point_views_are_head_on_then_frame_index();
    test_tile_views_rank_coverage_before_incidence();
    return 0;
}
