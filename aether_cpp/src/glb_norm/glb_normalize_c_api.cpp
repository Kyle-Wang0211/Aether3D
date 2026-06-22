// SPDX-License-Identifier: LicenseRef-Aether3D-Proprietary
// Copyright (c) 2024-2026 Aether3D. All rights reserved.
//
// aether_glb_norm — C ABI surface.
//
// Phase 0: scaffolded (this file's prior version returned UNSUPPORTED).
// Phase 1: atlas_merger ported from server-side Python.
// Phase 2: parse_glb + write_glb wired into the C API so
//   `aether_glb_norm_run` actually returns a single-prim GLB on success.
// Phase 3 (this commit): meshoptimizer-driven per-chart quadric-error
//   decimation, runs between parse and atlas-merge whenever total face
//   count exceeds `options.target_face_count`.

#include "aether_glb_norm_c.h"

#include "atlas_merger.h"
#include "glb_io.h"
#include "mesh_simplify.h"

#include <chrono>
#include <cstdint>
#include <cstdlib>
#include <cstring>
#include <string>
#include <utility>
#include <vector>

namespace {

// std::malloc + memcpy — pairs with aether_glb_norm_buffer_free's
// std::free. Crossing an FFI boundary, we cannot free a buffer that
// was new[]/delete[]'d through std::vector — heap allocators differ
// between the host (Swift / Dart / Kotlin / JS) and our C++ static
// lib, especially on Windows / wasm.
bool copy_to_caller_buffer(const std::vector<uint8_t>& src,
                           aether_glb_norm_buffer_t* dst) {
    if (!dst) return false;
    if (src.empty()) {
        dst->data = nullptr;
        dst->size = 0;
        return true;
    }
    void* mem = std::malloc(src.size());
    if (!mem) {
        dst->data = nullptr;
        dst->size = 0;
        return false;
    }
    std::memcpy(mem, src.data(), src.size());
    dst->data = static_cast<uint8_t*>(mem);
    dst->size = src.size();
    return true;
}

bool fire_progress(aether_glb_norm_progress_fn cb, void* ud,
                   float frac, const char* phase) {
    if (!cb) return true;
    return cb(frac, phase, ud) == 0;
}

}  // namespace

extern "C" {

void aether_glb_norm_options_default(aether_glb_norm_options_t* out) {
    if (!out) return;
    out->target_atlas_size = 0;          // 0 = auto
    out->max_atlas_size = 8192;          // 8K is universally supported on iOS 14+
    out->target_face_count = 500000;     // 500K = visually lossless at 4K texture
    out->allow_oversize_textures = 0;
}

void aether_glb_norm_buffer_free(aether_glb_norm_buffer_t* buf) {
    if (!buf || !buf->data) return;
    std::free(buf->data);
    buf->data = nullptr;
    buf->size = 0;
}

aether_glb_norm_result_t aether_glb_norm_run(
    const uint8_t* input_glb_bytes,
    size_t input_glb_size,
    const aether_glb_norm_options_t* options,
    aether_glb_norm_progress_fn progress_cb,
    void* progress_user_data,
    aether_glb_norm_buffer_t* out_buffer,
    aether_glb_norm_stats_t* out_stats) {
    using clock = std::chrono::steady_clock;
    const auto t0 = clock::now();

    if (out_buffer) {
        out_buffer->data = nullptr;
        out_buffer->size = 0;
    }
    if (out_stats) {
        std::memset(out_stats, 0, sizeof(*out_stats));
    }
    if (!input_glb_bytes || input_glb_size == 0 || !out_buffer) {
        return AETHER_GLB_NORM_ERR_INVALID_GLB;
    }

    aether_glb_norm_options_t opts{};
    if (options) {
        opts = *options;
    } else {
        aether_glb_norm_options_default(&opts);
    }

    // ─── Parse ─────────────────────────────────────────────────────────
    if (!fire_progress(progress_cb, progress_user_data, 0.05f, "parsing")) {
        return AETHER_GLB_NORM_ERR_CANCELLED;
    }
    aether::glb_norm::InputGlb in;
    std::string err;
    if (!aether::glb_norm::parse_glb(input_glb_bytes, input_glb_size,
                                     in, &err)) {
        // Heuristic mapping. The most common failure on a
        // photogrammetry GLB is a missing baseColor texture, which
        // our parser surfaces as an error in decode_image_to_rgb.
        // For unknown failures we fall back to INVALID_GLB.
        if (err.find("stbi_load_from_memory failed") != std::string::npos) {
            return AETHER_GLB_NORM_ERR_PNG_DECODE;
        }
        if (err.find("no usable primitives") != std::string::npos) {
            return AETHER_GLB_NORM_ERR_NO_TEXTURES;
        }
        return AETHER_GLB_NORM_ERR_INVALID_GLB;
    }
    if (out_stats) {
        out_stats->input_primitive_count = in.input_primitive_count;
        out_stats->input_material_count  = in.input_material_count;
        out_stats->input_face_count =
            static_cast<uint32_t>(in.indices.size() / 3u);
    }

    // ─── Simplify mesh (Phase 3) ───────────────────────────────────────
    // Per-chart quadric-error decimation via meshoptimizer. Triggered
    // only when total face count exceeds target_face_count; runs BEFORE
    // atlas merge so the atlas packer sees the smaller per-chart UV
    // sets (and so chart_face_ranges shrinks before write_glb stitches).
    //
    // We split the global target proportionally to each chart's face
    // share. meshopt_SimplifyLockBorder pins chart-boundary vertices,
    // which is what stops cracks from forming where adjacent charts
    // meet — chart boundaries are exactly the per-prim borders the
    // simplifier would otherwise free to collapse independently.
    {
        const uint32_t total_faces =
            static_cast<uint32_t>(in.indices.size() / 3u);
        if (opts.target_face_count > 0 && total_faces > opts.target_face_count) {
            if (!fire_progress(progress_cb, progress_user_data, 0.15f,
                               "decimating mesh")) {
                return AETHER_GLB_NORM_ERR_CANCELLED;
            }

            const bool has_normals =
                (in.normals.size() == in.positions.size());

            std::vector<float> new_positions;
            std::vector<float> new_normals;
            std::vector<uint32_t> new_indices;
            std::vector<std::pair<uint32_t, uint32_t>> new_vrng;
            std::vector<std::pair<uint32_t, uint32_t>> new_frng;
            new_positions.reserve(in.positions.size());
            if (has_normals) new_normals.reserve(in.normals.size());
            new_indices.reserve(in.indices.size());
            new_vrng.reserve(in.charts.size());
            new_frng.reserve(in.charts.size());

            for (std::size_t ci = 0; ci < in.charts.size(); ++ci) {
                const uint32_t vstart = in.chart_vertex_ranges[ci].first;
                const uint32_t vcount = in.chart_vertex_ranges[ci].second;
                const uint32_t fstart = in.chart_face_ranges[ci].first;
                const uint32_t fcount = in.chart_face_ranges[ci].second;

                std::vector<float> cp(
                    in.positions.begin() + 3u * vstart,
                    in.positions.begin() + 3u * (vstart + vcount));
                std::vector<float> cn;
                if (has_normals) {
                    cn.assign(in.normals.begin() + 3u * vstart,
                              in.normals.begin() + 3u * (vstart + vcount));
                }
                std::vector<float> cu = in.charts[ci].uvs;
                std::vector<uint32_t> ci_idx;
                ci_idx.reserve(static_cast<std::size_t>(fcount) * 3u);
                for (uint32_t k = 0; k < fcount * 3u; ++k) {
                    ci_idx.push_back(in.indices[3u * fstart + k] - vstart);
                }

                // Round-to-nearest split with a 4-face floor to keep
                // tiny charts (e.g. background props) from getting
                // wiped out entirely on aggressive global targets.
                const std::uint64_t prod =
                    static_cast<std::uint64_t>(fcount) *
                    static_cast<std::uint64_t>(opts.target_face_count);
                uint32_t chart_target = static_cast<uint32_t>(
                    (prod + static_cast<std::uint64_t>(total_faces) / 2u) /
                    static_cast<std::uint64_t>(total_faces));
                if (chart_target < 4u) chart_target = 4u;

                // On simplify failure (rare — happens only on degenerate
                // input the simplifier can't make progress on), the
                // function leaves cp/cn/cu/ci_idx untouched, so the
                // original chart geometry just falls through unchanged.
                (void)aether::glb_norm::simplify_chart_inplace(
                    cp, ci_idx, cn, cu, chart_target);

                const uint32_t out_vstart =
                    static_cast<uint32_t>(new_positions.size() / 3u);
                const uint32_t out_vcount =
                    static_cast<uint32_t>(cp.size() / 3u);
                const uint32_t out_fstart =
                    static_cast<uint32_t>(new_indices.size() / 3u);
                const uint32_t out_fcount =
                    static_cast<uint32_t>(ci_idx.size() / 3u);

                new_positions.insert(new_positions.end(),
                                     cp.begin(), cp.end());
                if (has_normals) {
                    new_normals.insert(new_normals.end(),
                                       cn.begin(), cn.end());
                }
                in.charts[ci].uvs = std::move(cu);
                for (uint32_t idx : ci_idx) {
                    new_indices.push_back(idx + out_vstart);
                }
                new_vrng.emplace_back(out_vstart, out_vcount);
                new_frng.emplace_back(out_fstart, out_fcount);
            }

            in.positions = std::move(new_positions);
            in.normals   = std::move(new_normals);
            in.indices   = std::move(new_indices);
            in.chart_vertex_ranges = std::move(new_vrng);
            in.chart_face_ranges   = std::move(new_frng);
        }
    }

    // ─── Pack atlas ────────────────────────────────────────────────────
    if (!fire_progress(progress_cb, progress_user_data, 0.30f, "packing atlas")) {
        return AETHER_GLB_NORM_ERR_CANCELLED;
    }
    aether::glb_norm::AtlasMergerOptions am_opts;
    am_opts.target_atlas_size = opts.target_atlas_size;
    am_opts.max_atlas_size    = opts.max_atlas_size > 0 ? opts.max_atlas_size : 8192;
    // target_utilization + edge_dilate_px stay at the merger defaults
    // (0.7 utilization, 8 px dilate) — the C ABI doesn't expose these
    // because the Python reference impl ran at the same defaults and
    // we're matching that behavior exactly.

    aether::glb_norm::AtlasMergerResult merged;
    if (!aether::glb_norm::merge_atlases(in.charts, am_opts, merged)) {
        return AETHER_GLB_NORM_ERR_PACKING_FAILED;
    }
    if (out_stats) {
        out_stats->output_atlas_size = merged.chosen_atlas_size;
    }

    // ─── Write GLB ─────────────────────────────────────────────────────
    if (!fire_progress(progress_cb, progress_user_data, 0.85f, "encoding glb")) {
        return AETHER_GLB_NORM_ERR_CANCELLED;
    }
    std::vector<uint8_t> out_glb;
    if (!aether::glb_norm::write_glb(in, merged, out_glb, &err)) {
        if (err.find("stbi_write_png_to_func failed") != std::string::npos) {
            return AETHER_GLB_NORM_ERR_PNG_ENCODE;
        }
        return AETHER_GLB_NORM_ERR_INTERNAL;
    }

    // ─── Hand off to caller ────────────────────────────────────────────
    if (!copy_to_caller_buffer(out_glb, out_buffer)) {
        return AETHER_GLB_NORM_ERR_OUT_OF_MEMORY;
    }
    if (out_stats) {
        out_stats->output_primitive_count = 1;
        out_stats->output_material_count  = 1;
        out_stats->output_face_count =
            static_cast<uint32_t>(in.indices.size() / 3u);
        const auto t1 = clock::now();
        const auto dt =
            std::chrono::duration_cast<std::chrono::microseconds>(t1 - t0).count();
        out_stats->elapsed_seconds = static_cast<float>(dt) / 1.0e6f;
    }
    fire_progress(progress_cb, progress_user_data, 1.0f, "done");
    return AETHER_GLB_NORM_OK;
}

const char* aether_glb_norm_result_str(aether_glb_norm_result_t code) {
    switch (code) {
        case AETHER_GLB_NORM_OK:                  return "ok";
        case AETHER_GLB_NORM_ERR_INVALID_GLB:     return "invalid_glb";
        case AETHER_GLB_NORM_ERR_NO_MATERIALS:    return "no_materials";
        case AETHER_GLB_NORM_ERR_NO_TEXTURES:     return "no_textures";
        case AETHER_GLB_NORM_ERR_PNG_DECODE:      return "png_decode";
        case AETHER_GLB_NORM_ERR_PACKING_FAILED:  return "packing_failed";
        case AETHER_GLB_NORM_ERR_PNG_ENCODE:      return "png_encode";
        case AETHER_GLB_NORM_ERR_OUT_OF_MEMORY:   return "out_of_memory";
        case AETHER_GLB_NORM_ERR_CANCELLED:       return "cancelled";
        case AETHER_GLB_NORM_ERR_UNSUPPORTED:     return "unsupported";
        case AETHER_GLB_NORM_ERR_INTERNAL:        return "internal";
    }
    return "unknown";
}

}  // extern "C"
