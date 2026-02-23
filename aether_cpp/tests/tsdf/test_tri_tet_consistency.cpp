// SPDX-License-Identifier: LicenseRef-Aether3D-Proprietary
// Copyright (c) 2024-2026 Aether3D. All rights reserved.

#include "aether/tsdf/tri_tet_consistency.h"

#include <cmath>
#include <cstdio>
#include <limits>
#include <vector>

namespace {

bool approx(float a, float b, float eps = 1e-6f) {
    return std::fabs(a - b) <= eps;
}

std::vector<aether::tsdf::TriTetVertex> sample_vertices(int view_count) {
    using aether::math::Vec3;
    using aether::tsdf::TriTetVertex;
    return {
        TriTetVertex{0, Vec3(0, 0, 0), view_count},
        TriTetVertex{1, Vec3(1, 0, 0), view_count},
        TriTetVertex{2, Vec3(0, 1, 0), view_count},
        TriTetVertex{3, Vec3(1, 1, 0), view_count},
        TriTetVertex{4, Vec3(0, 0, 1), view_count},
        TriTetVertex{5, Vec3(1, 0, 1), view_count},
        TriTetVertex{6, Vec3(0, 1, 1), view_count},
        TriTetVertex{7, Vec3(1, 1, 1), view_count},
    };
}

}  // namespace

int main() {
    int failed = 0;
    using namespace aether::tsdf;

    {
        int table0[20]{};
        int table1[20]{};
        if (kuhn5_table(0, table0) != aether::core::Status::kOk ||
            kuhn5_table(1, table1) != aether::core::Status::kOk) {
            std::fprintf(stderr, "kuhn5_table failed\n");
            failed++;
        }
        if (!(table0[0] == 0 && table0[1] == 1 && table0[2] == 3 && table0[3] == 7)) {
            std::fprintf(stderr, "kuhn5 parity0 mismatch\n");
            failed++;
        }
        if (!(table1[0] == 1 && table1[1] == 0 && table1[2] == 2 && table1[3] == 6)) {
            std::fprintf(stderr, "kuhn5 parity1 mismatch\n");
            failed++;
        }
    }

    {
        const auto vertices = sample_vertices(4);
        int raw[20]{};
        (void)kuhn5_table(0, raw);
        std::vector<TriTetTetrahedron> tetrahedra;
        tetrahedra.reserve(5u);
        for (int i = 0; i < 5; ++i) {
            tetrahedra.push_back(
                TriTetTetrahedron{i, raw[i * 4], raw[i * 4 + 1], raw[i * 4 + 2], raw[i * 4 + 3]});
        }
        const TriTetTriangle tri{
            aether::math::Vec3(0.2f, 0.2f, 0.2f),
            aether::math::Vec3(0.3f, 0.2f, 0.2f),
            aether::math::Vec3(0.2f, 0.3f, 0.2f)};
        const TriTetConfig cfg{3, 2, 2.0f};
        TriTetBinding binding{};
        TriTetReport report{};
        const auto st = evaluate_tri_tet_consistency(
            &tri,
            1u,
            vertices.data(),
            vertices.size(),
            tetrahedra.data(),
            tetrahedra.size(),
            cfg,
            &binding,
            1u,
            &report);
        if (st != aether::core::Status::kOk) {
            std::fprintf(stderr, "evaluate_tri_tet_consistency measured path failed\n");
            failed++;
        } else {
            if (report.measured_count != 1 || report.unknown_count != 0 || !approx(report.combined_score, 1.0f)) {
                std::fprintf(stderr, "measured classification mismatch\n");
                failed++;
            }
            if (binding.classification != TriTetConsistencyClass::kMeasured) {
                std::fprintf(stderr, "binding measured class mismatch\n");
                failed++;
            }
        }
    }

    {
        const auto vertices = sample_vertices(1);
        int raw[20]{};
        (void)kuhn5_table(0, raw);
        std::vector<TriTetTetrahedron> tetrahedra;
        tetrahedra.reserve(5u);
        for (int i = 0; i < 5; ++i) {
            tetrahedra.push_back(
                TriTetTetrahedron{i, raw[i * 4], raw[i * 4 + 1], raw[i * 4 + 2], raw[i * 4 + 3]});
        }
        const TriTetTriangle tri{
            aether::math::Vec3(0.6f, 0.6f, 0.6f),
            aether::math::Vec3(0.7f, 0.6f, 0.6f),
            aether::math::Vec3(0.6f, 0.7f, 0.6f)};
        const TriTetConfig cfg{3, 2, 2.0f};
        TriTetBinding binding{};
        TriTetReport report{};
        const auto st = evaluate_tri_tet_consistency(
            &tri,
            1u,
            vertices.data(),
            vertices.size(),
            tetrahedra.data(),
            tetrahedra.size(),
            cfg,
            &binding,
            1u,
            &report);
        if (st != aether::core::Status::kOk) {
            std::fprintf(stderr, "evaluate_tri_tet_consistency unknown path failed\n");
            failed++;
        } else {
            if (report.measured_count != 0 || report.unknown_count != 1 || !approx(report.combined_score, 0.1f)) {
                std::fprintf(stderr, "unknown classification mismatch\n");
                failed++;
            }
            if (binding.classification != TriTetConsistencyClass::kUnknown) {
                std::fprintf(stderr, "binding unknown class mismatch\n");
                failed++;
            }
        }
    }

    {
        const TriTetConfig cfg{};
        TriTetReport report{};
        const auto st = evaluate_tri_tet_consistency(
            nullptr,
            0u,
            nullptr,
            0u,
            nullptr,
            0u,
            cfg,
            nullptr,
            0u,
            &report);
        if (st != aether::core::Status::kOk) {
            std::fprintf(stderr, "empty input should be ok\n");
            failed++;
        }
        if (!(report.measured_count == 0 && report.estimated_count == 0 && report.unknown_count == 0 &&
              approx(report.combined_score, 0.0f))) {
            std::fprintf(stderr, "empty report mismatch\n");
            failed++;
        }
    }

    return failed;
}
