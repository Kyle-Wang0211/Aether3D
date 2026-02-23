// SPDX-License-Identifier: LicenseRef-Aether3D-Proprietary
// Copyright (c) 2024-2026 Aether3D. All rights reserved.

#include "aether/tsdf/spatial_quantizer.h"

#include <cmath>
#include <cstdint>
#include <cstdio>

namespace {

bool approx(double a, double b, double eps = 1e-9) {
    return std::fabs(a - b) <= eps;
}

}  // namespace

int main() {
    int failed = 0;
    using namespace aether::tsdf;

    {
        QuantizedPosition pos{};
        const auto st = quantize_world_position(
            1.5,
            2.7,
            3.9,
            0.0,
            0.0,
            0.0,
            1.0,
            &pos);
        if (st != aether::core::Status::kOk) {
            std::fprintf(stderr, "quantize_world_position returned error\n");
            failed++;
        }
        if (!(pos.x == 1 && pos.y == 2 && pos.z == 3)) {
            std::fprintf(stderr, "quantize_world_position mismatch\n");
            failed++;
        }
    }

    {
        std::uint64_t code = 0u;
        const auto st = morton_encode_21bit(10, 20, 30, &code);
        if (st != aether::core::Status::kOk) {
            std::fprintf(stderr, "morton_encode_21bit returned error\n");
            failed++;
        }

        QuantizedPosition decoded{};
        const auto st_decode = morton_decode_21bit(code, &decoded);
        if (st_decode != aether::core::Status::kOk) {
            std::fprintf(stderr, "morton_decode_21bit returned error\n");
            failed++;
        }
        if (!(decoded.x == 10 && decoded.y == 20 && decoded.z == 30)) {
            std::fprintf(stderr, "morton round-trip mismatch\n");
            failed++;
        }
    }

    {
        QuantizedPosition pos{};
        pos.x = -7;
        pos.y = 42;
        pos.z = 9;
        double wx = 0.0;
        double wy = 0.0;
        double wz = 0.0;
        const auto st = dequantize_world_position(
            pos,
            0.5,
            -1.0,
            2.0,
            0.1,
            &wx,
            &wy,
            &wz);
        if (st != aether::core::Status::kOk) {
            std::fprintf(stderr, "dequantize_world_position returned error\n");
            failed++;
        }
        if (!approx(wx, -0.2) || !approx(wy, 3.2) || !approx(wz, 2.9)) {
            std::fprintf(stderr, "dequantize_world_position mismatch\n");
            failed++;
        }
    }

    {
        QuantizedPosition pos{};
        const auto st = quantize_world_position(
            1.0,
            2.0,
            3.0,
            0.0,
            0.0,
            0.0,
            0.0,
            &pos);
        if (st == aether::core::Status::kOk) {
            std::fprintf(stderr, "expected invalid argument for zero cell size\n");
            failed++;
        }
    }

    return failed;
}
