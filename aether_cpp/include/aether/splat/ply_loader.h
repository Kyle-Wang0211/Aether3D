// SPDX-License-Identifier: LicenseRef-Aether3D-Proprietary
// Copyright (c) 2024-2026 Aether3D. All rights reserved.

#ifndef AETHER_CPP_SPLAT_PLY_LOADER_H
#define AETHER_CPP_SPLAT_PLY_LOADER_H

#ifdef __cplusplus

#include <cmath>
#include <cerrno>
#include <cstddef>
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <vector>

#include "aether/core/status.h"
#include "aether/splat/packed_splats.h"

namespace aether {
namespace splat {

// ═══════════════════════════════════════════════════════════════════════
// PLY Loader: Parse 3DGS standard PLY files
// ═══════════════════════════════════════════════════════════════════════
// Supports both ASCII and binary little-endian PLY formats.
//
// Expected 3DGS properties:
//   x, y, z                       — position
//   f_dc_0, f_dc_1, f_dc_2       — DC spherical harmonics (→ color)
//   opacity                       — raw opacity (before sigmoid)
//   scale_0, scale_1, scale_2     — log-space scale
//   rot_0, rot_1, rot_2, rot_3   — quaternion (w, x, y, z)

/// Result of loading a PLY file.
struct PlyLoadResult {
    std::vector<GaussianParams> gaussians;
    std::size_t vertex_count{0};
};

/// PLY file format type.
enum class PlyFormat : std::uint8_t {
    kUnknown = 0,
    kAscii = 1,
    kBinaryLittleEndian = 2,
    kBinaryBigEndian = 3,
};

/// Property descriptor parsed from the PLY header.
struct PlyProperty {
    char name[64];
    enum class Type : std::uint8_t {
        kFloat = 0,
        kDouble = 1,
        kUchar = 2,
        kInt = 3,
        kShort = 4,
        kUnknown = 255,
    } type;

    std::size_t byte_size() const noexcept {
        switch (type) {
            case Type::kFloat:  return 4;
            case Type::kDouble: return 8;
            case Type::kUchar:  return 1;
            case Type::kInt:    return 4;
            case Type::kShort:  return 2;
            default:            return 0;
        }
    }
};

/// Load a 3DGS PLY file into GaussianParams array.
///
/// Supports standard 3DGS properties: position, color (SH DC),
/// opacity (sigmoid-encoded), scale (log-encoded), rotation (quaternion).
///
/// Parameters:
///   path   — file path to the PLY file
///   result — output PlyLoadResult with parsed Gaussians
///
/// Returns core::Status::kOk on success.
inline core::Status load_ply(const char* path, PlyLoadResult& result) noexcept {
    result.gaussians.clear();
    result.vertex_count = 0;

    std::FILE* file = std::fopen(path, "rb");
    if (!file) return core::Status::kInvalidArgument;

    // ─── Parse Header ───────────────────────────────────────────────
    char line[512];
    PlyFormat format = PlyFormat::kUnknown;
    std::size_t vertex_count = 0;
    std::vector<PlyProperty> properties;
    bool in_vertex_element = false;

    while (std::fgets(line, sizeof(line), file)) {
        // Remove newline
        std::size_t len = std::strlen(line);
        while (len > 0 && (line[len - 1] == '\n' || line[len - 1] == '\r')) {
            line[--len] = '\0';
        }

        if (std::strcmp(line, "end_header") == 0) break;

        if (std::strncmp(line, "ply", 3) == 0) continue;
        if (std::strncmp(line, "comment", 7) == 0) continue;

        if (std::strncmp(line, "format ", 7) == 0) {
            if (std::strstr(line, "ascii")) {
                format = PlyFormat::kAscii;
            } else if (std::strstr(line, "binary_little_endian")) {
                format = PlyFormat::kBinaryLittleEndian;
            } else if (std::strstr(line, "binary_big_endian")) {
                format = PlyFormat::kBinaryBigEndian;
            }
            continue;
        }

        if (std::strncmp(line, "element vertex", 14) == 0) {
            vertex_count = static_cast<std::size_t>(std::atol(line + 15));
            in_vertex_element = true;
            continue;
        }

        if (std::strncmp(line, "element ", 8) == 0) {
            in_vertex_element = false;
            continue;
        }

        if (in_vertex_element && std::strncmp(line, "property ", 9) == 0) {
            PlyProperty prop{};
            char type_str[32] = {};
            char name_str[64] = {};

            if (std::sscanf(line, "property %31s %63s", type_str, name_str) == 2) {
                std::strncpy(prop.name, name_str, sizeof(prop.name) - 1);

                if (std::strcmp(type_str, "float") == 0 ||
                    std::strcmp(type_str, "float32") == 0) {
                    prop.type = PlyProperty::Type::kFloat;
                } else if (std::strcmp(type_str, "double") == 0 ||
                           std::strcmp(type_str, "float64") == 0) {
                    prop.type = PlyProperty::Type::kDouble;
                } else if (std::strcmp(type_str, "uchar") == 0 ||
                           std::strcmp(type_str, "uint8") == 0) {
                    prop.type = PlyProperty::Type::kUchar;
                } else if (std::strcmp(type_str, "int") == 0 ||
                           std::strcmp(type_str, "int32") == 0) {
                    prop.type = PlyProperty::Type::kInt;
                } else if (std::strcmp(type_str, "short") == 0 ||
                           std::strcmp(type_str, "int16") == 0) {
                    prop.type = PlyProperty::Type::kShort;
                } else {
                    prop.type = PlyProperty::Type::kUnknown;
                }

                properties.push_back(prop);
            }
        }
    }

    if (format == PlyFormat::kUnknown || vertex_count == 0) {
        std::fclose(file);
        return core::Status::kInvalidArgument;
    }

    if (format == PlyFormat::kBinaryBigEndian) {
        // Not commonly used for 3DGS
        std::fclose(file);
        return core::Status::kInvalidArgument;
    }

    // ─── Find Property Indices ──────────────────────────────────────
    auto find_prop = [&](const char* name) -> int {
        for (std::size_t i = 0; i < properties.size(); ++i) {
            if (std::strcmp(properties[i].name, name) == 0) {
                return static_cast<int>(i);
            }
        }
        return -1;
    };

    int idx_x     = find_prop("x");
    int idx_y     = find_prop("y");
    int idx_z     = find_prop("z");
    int idx_dc0   = find_prop("f_dc_0");
    int idx_dc1   = find_prop("f_dc_1");
    int idx_dc2   = find_prop("f_dc_2");
    // Fallback: some PLY exporters (Polycam, Luma, etc.) use red/green/blue
    int idx_red   = find_prop("red");
    int idx_green = find_prop("green");
    int idx_blue  = find_prop("blue");
    int idx_opac  = find_prop("opacity");
    int idx_s0    = find_prop("scale_0");
    int idx_s1    = find_prop("scale_1");
    int idx_s2    = find_prop("scale_2");
    int idx_r0    = find_prop("rot_0");
    int idx_r1    = find_prop("rot_1");
    int idx_r2    = find_prop("rot_2");
    int idx_r3    = find_prop("rot_3");

    // SH degree-1 coefficients: f_rest_0 through f_rest_8
    // Layout in standard 3DGS PLY: 3 channels × 3 basis functions
    // f_rest_0..2 = R channel (Y_1^{-1}, Y_1^0, Y_1^{+1})
    // f_rest_3..5 = G channel
    // f_rest_6..8 = B channel
    int idx_sh1[9];
    bool has_sh1 = true;
    for (int i = 0; i < 9; ++i) {
        char sh_name[16];
        std::snprintf(sh_name, sizeof(sh_name), "f_rest_%d", i);
        idx_sh1[i] = find_prop(sh_name);
        if (idx_sh1[i] < 0) has_sh1 = false;
    }

    // Determine color source: SH DC coefficients or direct RGB
    bool has_sh_color = (idx_dc0 >= 0 && idx_dc1 >= 0 && idx_dc2 >= 0);
    bool has_rgb_color = (idx_red >= 0 && idx_green >= 0 && idx_blue >= 0);

    // Position is required
    if (idx_x < 0 || idx_y < 0 || idx_z < 0) {
        std::fclose(file);
        return core::Status::kInvalidArgument;
    }

    // Compute per-vertex byte stride (for binary format)
    std::size_t stride = 0;
    std::vector<std::size_t> offsets(properties.size());
    for (std::size_t i = 0; i < properties.size(); ++i) {
        offsets[i] = stride;
        stride += properties[i].byte_size();
    }

    // ─── Helper: Read Property Value ────────────────────────────────
    auto read_float_prop = [](const std::uint8_t* row, std::size_t offset,
                               PlyProperty::Type type) -> float {
        switch (type) {
            case PlyProperty::Type::kFloat: {
                float v;
                std::memcpy(&v, row + offset, sizeof(v));
                return v;
            }
            case PlyProperty::Type::kDouble: {
                double v;
                std::memcpy(&v, row + offset, sizeof(v));
                return static_cast<float>(v);
            }
            case PlyProperty::Type::kUchar: {
                return static_cast<float>(row[offset]) / 255.0f;
            }
            case PlyProperty::Type::kInt: {
                std::int32_t v;
                std::memcpy(&v, row + offset, sizeof(v));
                return static_cast<float>(v);
            }
            case PlyProperty::Type::kShort: {
                std::int16_t v;
                std::memcpy(&v, row + offset, sizeof(v));
                return static_cast<float>(v);
            }
            default:
                return 0.0f;
        }
    };

    // ─── Read Vertices ──────────────────────────────────────────────
    result.gaussians.resize(vertex_count);
    result.vertex_count = vertex_count;

    if (format == PlyFormat::kBinaryLittleEndian) {
        // Read all vertex data at once
        std::vector<std::uint8_t> buffer(stride * vertex_count);
        std::size_t read = std::fread(buffer.data(), 1, buffer.size(), file);
        if (read < buffer.size()) {
            std::fclose(file);
            return core::Status::kInvalidArgument;
        }

        for (std::size_t v = 0; v < vertex_count; ++v) {
            const std::uint8_t* row = buffer.data() + v * stride;
            GaussianParams& g = result.gaussians[v];

            // Position
            g.position[0] = read_float_prop(row, offsets[idx_x], properties[idx_x].type);
            g.position[1] = read_float_prop(row, offsets[idx_y], properties[idx_y].type);
            g.position[2] = read_float_prop(row, offsets[idx_z], properties[idx_z].type);

            // Color: prefer SH DC coefficients, fall back to direct RGB
            constexpr float kSH_C0 = 0.28209479177387814f;
            if (has_sh_color) {
                // SH DC to color: c = sh0 * C0 + 0.5
                float sh0 = read_float_prop(row, offsets[idx_dc0], properties[idx_dc0].type);
                float sh1 = read_float_prop(row, offsets[idx_dc1], properties[idx_dc1].type);
                float sh2 = read_float_prop(row, offsets[idx_dc2], properties[idx_dc2].type);
                g.color[0] = sh0 * kSH_C0 + 0.5f;
                g.color[1] = sh1 * kSH_C0 + 0.5f;
                g.color[2] = sh2 * kSH_C0 + 0.5f;
            } else if (has_rgb_color) {
                // Direct RGB: read_float_prop handles uchar→[0,1] and float→float
                g.color[0] = read_float_prop(row, offsets[idx_red], properties[idx_red].type);
                g.color[1] = read_float_prop(row, offsets[idx_green], properties[idx_green].type);
                g.color[2] = read_float_prop(row, offsets[idx_blue], properties[idx_blue].type);
            } else {
                g.color[0] = g.color[1] = g.color[2] = 0.5f;
            }
            // Clamp to [0, 1]
            for (int c = 0; c < 3; ++c) {
                if (g.color[c] < 0.0f) g.color[c] = 0.0f;
                if (g.color[c] > 1.0f) g.color[c] = 1.0f;
            }

            // Opacity: sigmoid(raw_opacity)
            if (idx_opac >= 0) {
                float raw = read_float_prop(row, offsets[idx_opac], properties[idx_opac].type);
                g.opacity = 1.0f / (1.0f + std::exp(-raw));
            } else {
                g.opacity = 1.0f;
            }

            // Scale: exp(log_scale)
            if (idx_s0 >= 0 && idx_s1 >= 0 && idx_s2 >= 0) {
                g.scale[0] = std::exp(read_float_prop(row, offsets[idx_s0], properties[idx_s0].type));
                g.scale[1] = std::exp(read_float_prop(row, offsets[idx_s1], properties[idx_s1].type));
                g.scale[2] = std::exp(read_float_prop(row, offsets[idx_s2], properties[idx_s2].type));
            } else {
                g.scale[0] = g.scale[1] = g.scale[2] = 0.01f;
            }

            // Rotation: quaternion (w, x, y, z), normalize
            if (idx_r0 >= 0 && idx_r1 >= 0 && idx_r2 >= 0 && idx_r3 >= 0) {
                g.rotation[0] = read_float_prop(row, offsets[idx_r0], properties[idx_r0].type);
                g.rotation[1] = read_float_prop(row, offsets[idx_r1], properties[idx_r1].type);
                g.rotation[2] = read_float_prop(row, offsets[idx_r2], properties[idx_r2].type);
                g.rotation[3] = read_float_prop(row, offsets[idx_r3], properties[idx_r3].type);
                // Normalize quaternion
                float len = std::sqrt(
                    g.rotation[0] * g.rotation[0] + g.rotation[1] * g.rotation[1] +
                    g.rotation[2] * g.rotation[2] + g.rotation[3] * g.rotation[3]);
                if (len > 1e-8f) {
                    float inv = 1.0f / len;
                    g.rotation[0] *= inv;
                    g.rotation[1] *= inv;
                    g.rotation[2] *= inv;
                    g.rotation[3] *= inv;
                } else {
                    g.rotation[0] = 1.0f;
                    g.rotation[1] = g.rotation[2] = g.rotation[3] = 0.0f;
                }
            } else {
                g.rotation[0] = 1.0f;
                g.rotation[1] = g.rotation[2] = g.rotation[3] = 0.0f;
            }

            // SH degree-1 coefficients
            if (has_sh1) {
                for (int i = 0; i < 9; ++i) {
                    g.sh1[i] = read_float_prop(row, offsets[idx_sh1[i]],
                                                properties[idx_sh1[i]].type);
                }
            } else {
                std::memset(g.sh1, 0, sizeof(g.sh1));
            }
        }
    } else {
        // ASCII format
        for (std::size_t v = 0; v < vertex_count; ++v) {
            if (!std::fgets(line, sizeof(line), file)) {
                std::fclose(file);
                return core::Status::kInvalidArgument;
            }

            // Parse all property values as floats
            std::vector<float> values(properties.size(), 0.0f);
            const char* ptr = line;
            for (std::size_t p = 0; p < properties.size() && ptr; ++p) {
                while (*ptr == ' ' || *ptr == '\t') ++ptr;
                char* end = nullptr;
                values[p] = std::strtof(ptr, &end);
                ptr = end;
            }

            GaussianParams& g = result.gaussians[v];

            g.position[0] = values[idx_x];
            g.position[1] = values[idx_y];
            g.position[2] = values[idx_z];

            constexpr float kSH_C0_a = 0.28209479177387814f;
            if (has_sh_color) {
                g.color[0] = values[idx_dc0] * kSH_C0_a + 0.5f;
                g.color[1] = values[idx_dc1] * kSH_C0_a + 0.5f;
                g.color[2] = values[idx_dc2] * kSH_C0_a + 0.5f;
            } else if (has_rgb_color) {
                // Direct RGB (uchar→[0,255] or float→[0,1])
                g.color[0] = values[idx_red];
                g.color[1] = values[idx_green];
                g.color[2] = values[idx_blue];
                // If uchar, strtof reads as 0-255 → normalize
                if (properties[idx_red].type == PlyProperty::Type::kUchar) {
                    g.color[0] /= 255.0f;
                    g.color[1] /= 255.0f;
                    g.color[2] /= 255.0f;
                }
            } else {
                g.color[0] = g.color[1] = g.color[2] = 0.5f;
            }
            for (int c = 0; c < 3; ++c) {
                if (g.color[c] < 0.0f) g.color[c] = 0.0f;
                if (g.color[c] > 1.0f) g.color[c] = 1.0f;
            }

            if (idx_opac >= 0) {
                float raw = values[idx_opac];
                g.opacity = 1.0f / (1.0f + std::exp(-raw));
            } else {
                g.opacity = 1.0f;
            }

            if (idx_s0 >= 0) {
                g.scale[0] = std::exp(values[idx_s0]);
                g.scale[1] = std::exp(values[idx_s1]);
                g.scale[2] = std::exp(values[idx_s2]);
            } else {
                g.scale[0] = g.scale[1] = g.scale[2] = 0.01f;
            }

            if (idx_r0 >= 0) {
                g.rotation[0] = values[idx_r0];
                g.rotation[1] = values[idx_r1];
                g.rotation[2] = values[idx_r2];
                g.rotation[3] = values[idx_r3];
                float len = std::sqrt(
                    g.rotation[0] * g.rotation[0] + g.rotation[1] * g.rotation[1] +
                    g.rotation[2] * g.rotation[2] + g.rotation[3] * g.rotation[3]);
                if (len > 1e-8f) {
                    float inv = 1.0f / len;
                    for (int i = 0; i < 4; ++i) g.rotation[i] *= inv;
                } else {
                    g.rotation[0] = 1.0f;
                    g.rotation[1] = g.rotation[2] = g.rotation[3] = 0.0f;
                }
            } else {
                g.rotation[0] = 1.0f;
                g.rotation[1] = g.rotation[2] = g.rotation[3] = 0.0f;
            }

            // SH degree-1 coefficients
            if (has_sh1) {
                for (int i = 0; i < 9; ++i) {
                    g.sh1[i] = values[idx_sh1[i]];
                }
            } else {
                std::memset(g.sh1, 0, sizeof(g.sh1));
            }
        }
    }

    std::fclose(file);
    return core::Status::kOk;
}

/// Write GaussianParams to a binary PLY file.
inline core::Status write_ply(const char* path,
                                const GaussianParams* gaussians,
                                std::size_t count) noexcept {
    std::FILE* file = std::fopen(path, "wb");
    if (!file) {
        std::fprintf(stderr,
            "[Aether3D][Export] write_ply fopen FAILED path=%s errno=%d (%s)\n",
            path ? path : "(null)",
            errno,
            std::strerror(errno));
        return core::Status::kInvalidArgument;
    }

    // Write header
    std::fprintf(file, "ply\n");
    std::fprintf(file, "format binary_little_endian 1.0\n");
    std::fprintf(file, "element vertex %zu\n", count);
    std::fprintf(file, "property float x\n");
    std::fprintf(file, "property float y\n");
    std::fprintf(file, "property float z\n");
    std::fprintf(file, "property float f_dc_0\n");
    std::fprintf(file, "property float f_dc_1\n");
    std::fprintf(file, "property float f_dc_2\n");
    std::fprintf(file, "property float opacity\n");
    std::fprintf(file, "property float scale_0\n");
    std::fprintf(file, "property float scale_1\n");
    std::fprintf(file, "property float scale_2\n");
    std::fprintf(file, "property float rot_0\n");
    std::fprintf(file, "property float rot_1\n");
    std::fprintf(file, "property float rot_2\n");
    std::fprintf(file, "property float rot_3\n");
    // SH degree-1 coefficients (9 values: 3 channels × 3 basis functions)
    for (int sh = 0; sh < 9; ++sh) {
        std::fprintf(file, "property float f_rest_%d\n", sh);
    }
    std::fprintf(file, "end_header\n");

    // Write binary data
    constexpr float kInvSH_C0 = 1.0f / 0.28209479177387814f;

    for (std::size_t i = 0; i < count; ++i) {
        const GaussianParams& g = gaussians[i];
        float row[23];  // 14 base + 9 SH

        // Position
        row[0] = g.position[0];
        row[1] = g.position[1];
        row[2] = g.position[2];

        // Color → SH DC: sh0 = (c - 0.5) / C0
        row[3] = (g.color[0] - 0.5f) * kInvSH_C0;
        row[4] = (g.color[1] - 0.5f) * kInvSH_C0;
        row[5] = (g.color[2] - 0.5f) * kInvSH_C0;

        // Opacity → raw: logit(opacity)
        float op = g.opacity;
        if (op <= 0.0f) op = 1e-6f;
        if (op >= 1.0f) op = 1.0f - 1e-6f;
        row[6] = std::log(op / (1.0f - op));

        // Scale → log scale
        row[7] = std::log(g.scale[0] > 0.0f ? g.scale[0] : 1e-8f);
        row[8] = std::log(g.scale[1] > 0.0f ? g.scale[1] : 1e-8f);
        row[9] = std::log(g.scale[2] > 0.0f ? g.scale[2] : 1e-8f);

        // Rotation (quaternion)
        row[10] = g.rotation[0];
        row[11] = g.rotation[1];
        row[12] = g.rotation[2];
        row[13] = g.rotation[3];

        // SH degree-1 coefficients
        for (int sh = 0; sh < 9; ++sh) {
            row[14 + sh] = g.sh1[sh];
        }

        if (std::fwrite(row, sizeof(float), 23, file) != 23) {
            std::fprintf(stderr,
                "[Aether3D][Export] write_ply fwrite FAILED path=%s vertex=%zu errno=%d (%s)\n",
                path ? path : "(null)",
                i,
                errno,
                std::strerror(errno));
            std::fclose(file);
            return core::Status::kInvalidArgument;
        }
    }

    std::fclose(file);
    return core::Status::kOk;
}

}  // namespace splat
}  // namespace aether

#endif  // __cplusplus

#endif  // AETHER_CPP_SPLAT_PLY_LOADER_H
