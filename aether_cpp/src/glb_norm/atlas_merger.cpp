// SPDX-License-Identifier: LicenseRef-Aether3D-Proprietary
// Copyright (c) 2024-2026 Aether3D. All rights reserved.
//
// atlas_merger.cpp — port of pipeline/atlas_merger.py (server-side
// reference). Algorithm:
//
//   1. Per-chart UV bbox in [0,1].
//   2. Crop each chart RGB to (bbox_px ± 4 px) — the 4 px is intra-
//      chart sampling slack, separate from the 8 px atlas-neighbor
//      dilation in step 5.
//   3. Pick smallest pow2 atlas size with chart-pixel density ≈
//      target_utilization (default 0.7), bounded [1024, max].
//   4. If Σ chart pixels > 0.85 × side² (leaves slack for dilation
//      + rect-pack overhead), resize all charts by a global scale
//      factor √(0.85·side² / Σ).
//   5. Edge-replicate-pad each chart by edge_dilate_px (default 8).
//   6. stb_rect_pack into the atlas.
//   7. Composite, with chart-pixel-mean RGB (excluding texrecon's
//      own padding, RGB-sum < 15) as background — black bg makes
//      mip pyramids darken the model at low LOD.
//   8. Remap UVs to atlas coords.
//
// stb single-header impls live in this TU and only this TU (the
// CMake comment for glb_loader.cpp captures the same constraint).

#include "atlas_merger.h"

#include <algorithm>
#include <array>
#include <cmath>
#include <cstdint>
#include <cstdlib>
#include <cstring>
#include <vector>

#define STB_RECT_PACK_IMPLEMENTATION
#include "stb_rect_pack.h"

#define STB_IMAGE_RESIZE_IMPLEMENTATION
#include "stb_image_resize2.h"

namespace aether::glb_norm {

namespace {

// Crop slack in pixels — keeps per-vertex UVs from sampling beyond
// the cropped chart due to bbox rounding / float imprecision.
constexpr int kCropPaddingPx = 4;

// Upper bound on a single dimension we'll ever try to pack into.
// 16384 is the largest pow2 we report on any platform; iOS / Android
// drivers vary at that ceiling, so the C ABI defaults to 8K. Kept
// here for clarity even though opts.max_atlas_size enforces it.
constexpr int kHardMaxAtlasSize = 16384;

// Lower bound — anything smaller than 1K wastes a Filament shader-
// compile slot on a sub-1MP atlas, defeating the purpose.
constexpr int kMinAtlasSize = 1024;

int next_pow2_ge(int v) {
    if (v <= kMinAtlasSize) return kMinAtlasSize;
    int p = kMinAtlasSize;
    while (p < v && p < kHardMaxAtlasSize) p <<= 1;
    return p;
}

struct CroppedChart {
    int chart_index = 0;          // index into inputs[]
    int crop_x0 = 0;              // origin in source atlas, pixels
    int crop_y0 = 0;
    int src_w = 0;                // source size before resize
    int src_h = 0;
    int dst_w = 0;                // size after global resize
    int dst_h = 0;
    std::vector<uint8_t> rgb;     // dst_w × dst_h × 3 — pre-dilation
    int packed_x = -1;            // output atlas position (pre-dilation
    int packed_y = -1;            // origin = packed_x + dilate_px etc.)
};

// Clamp a UV scalar to [0,1] without branching pessimization.
float clamp01(float v) {
    if (v < 0.0f) return 0.0f;
    if (v > 1.0f) return 1.0f;
    return v;
}

// Per-chart UV bbox. Returns false on a chart with zero UVs.
bool compute_uv_bbox(const std::vector<float>& uvs,
                     float& umin, float& vmin,
                     float& umax, float& vmax) {
    if (uvs.size() < 2 || (uvs.size() % 2) != 0) return false;
    umin = vmin = 1.0f;
    umax = vmax = 0.0f;
    bool seen = false;
    for (size_t i = 0; i + 1 < uvs.size(); i += 2) {
        const float u = clamp01(uvs[i + 0]);
        const float v = clamp01(uvs[i + 1]);
        if (!seen) {
            umin = umax = u;
            vmin = vmax = v;
            seen = true;
        } else {
            if (u < umin) umin = u;
            if (u > umax) umax = u;
            if (v < vmin) vmin = v;
            if (v > vmax) vmax = v;
        }
    }
    return seen;
}

// Crop a source atlas to (bbox_px ± kCropPaddingPx). Output rgb is
// row-major RGB, dst size in CroppedChart is set.
void crop_chart(const ChartInput& in, float umin, float vmin,
                float umax, float vmax, CroppedChart& out) {
    const int W = in.atlas_w;
    const int H = in.atlas_h;
    int x0 = static_cast<int>(std::floor(static_cast<double>(umin) * W)) - kCropPaddingPx;
    int y0 = static_cast<int>(std::floor(static_cast<double>(vmin) * H)) - kCropPaddingPx;
    int x1 = static_cast<int>(std::ceil(static_cast<double>(umax) * W)) + kCropPaddingPx;
    int y1 = static_cast<int>(std::ceil(static_cast<double>(vmax) * H)) + kCropPaddingPx;
    if (x0 < 0) x0 = 0;
    if (y0 < 0) y0 = 0;
    if (x1 > W) x1 = W;
    if (y1 > H) y1 = H;
    if (x1 <= x0) x1 = x0 + 1;     // degenerate UV → 1 px
    if (y1 <= y0) y1 = y0 + 1;
    if (x1 > W) { x1 = W; x0 = W - 1; }
    if (y1 > H) { y1 = H; y0 = H - 1; }

    const int w = x1 - x0;
    const int h = y1 - y0;
    out.crop_x0 = x0;
    out.crop_y0 = y0;
    out.src_w = w;
    out.src_h = h;
    out.dst_w = w;
    out.dst_h = h;
    out.rgb.resize(static_cast<size_t>(w) * static_cast<size_t>(h) * 3u);
    for (int y = 0; y < h; ++y) {
        const uint8_t* src_row =
            in.atlas_rgb.data() + (static_cast<size_t>(y0 + y) * W + x0) * 3u;
        uint8_t* dst_row = out.rgb.data() + static_cast<size_t>(y) * w * 3u;
        std::memcpy(dst_row, src_row, static_cast<size_t>(w) * 3u);
    }
}

// Resize one chart's RGB by `scale` (≤1.0 for downscale). Updates
// dst_w/dst_h and rgb in place. Linear-byte filter (no sRGB
// linearization) to match cv2.resize semantics in the Python ref —
// see divergence note in the Phase 1 report.
bool resize_chart(CroppedChart& c, double scale) {
    if (scale >= 0.999) return true;     // no-op band
    int new_w = static_cast<int>(std::round(c.dst_w * scale));
    int new_h = static_cast<int>(std::round(c.dst_h * scale));
    if (new_w < 1) new_w = 1;
    if (new_h < 1) new_h = 1;
    std::vector<uint8_t> resized(static_cast<size_t>(new_w) * new_h * 3u);
    unsigned char* ok = stbir_resize_uint8_linear(
        c.rgb.data(), c.dst_w, c.dst_h, /*input_stride*/ 0,
        resized.data(), new_w, new_h, /*output_stride*/ 0,
        STBIR_RGB);
    if (!ok) return false;
    c.dst_w = new_w;
    c.dst_h = new_h;
    c.rgb = std::move(resized);
    return true;
}

// Apply np.pad mode='edge' on all 4 sides by `pad` pixels. Returns
// a new buffer of size (w + 2·pad) × (h + 2·pad).
std::vector<uint8_t> edge_dilate(const std::vector<uint8_t>& src,
                                 int w, int h, int pad,
                                 int& out_w, int& out_h) {
    out_w = w + 2 * pad;
    out_h = h + 2 * pad;
    std::vector<uint8_t> dst(static_cast<size_t>(out_w) * out_h * 3u);
    auto src_px = [&](int x, int y) -> const uint8_t* {
        if (x < 0) x = 0;
        if (x >= w) x = w - 1;
        if (y < 0) y = 0;
        if (y >= h) y = h - 1;
        return src.data() + (static_cast<size_t>(y) * w + x) * 3u;
    };
    for (int y = 0; y < out_h; ++y) {
        for (int x = 0; x < out_w; ++x) {
            const uint8_t* p = src_px(x - pad, y - pad);
            uint8_t* d = dst.data() + (static_cast<size_t>(y) * out_w + x) * 3u;
            d[0] = p[0]; d[1] = p[1]; d[2] = p[2];
        }
    }
    return dst;
}

// Chart-pixel-mean RGB excluding texrecon padding (sum<15). Falls
// back to mid-grey on an all-padding input — black would darken the
// mip pyramid and defeat the whole reason this pass exists.
void compute_mean_bg(const std::vector<CroppedChart>& charts,
                     uint8_t& bg_r, uint8_t& bg_g, uint8_t& bg_b) {
    uint64_t r_sum = 0, g_sum = 0, b_sum = 0;
    uint64_t count = 0;
    for (const auto& c : charts) {
        const size_t pix = static_cast<size_t>(c.dst_w) * c.dst_h;
        for (size_t i = 0; i < pix; ++i) {
            const uint8_t r = c.rgb[i * 3 + 0];
            const uint8_t g = c.rgb[i * 3 + 1];
            const uint8_t b = c.rgb[i * 3 + 2];
            if (static_cast<int>(r) + g + b >= 15) {
                r_sum += r;
                g_sum += g;
                b_sum += b;
                ++count;
            }
        }
    }
    if (count == 0) {
        bg_r = bg_g = bg_b = 128;
        return;
    }
    bg_r = static_cast<uint8_t>(r_sum / count);
    bg_g = static_cast<uint8_t>(g_sum / count);
    bg_b = static_cast<uint8_t>(b_sum / count);
}

// Pack the (post-resize, post-dilate) chart sizes into a `side`²
// atlas. Returns true iff every chart placed. Mutates packed_x/y
// on each chart on success — these are the ORIGIN of the dilated
// rect in atlas pixels.
bool try_pack(int side, int dilate_px,
              std::vector<CroppedChart>& charts) {
    const int n = static_cast<int>(charts.size());
    std::vector<stbrp_rect> rects(static_cast<size_t>(n));
    for (int i = 0; i < n; ++i) {
        rects[i].id = i;
        rects[i].w = charts[i].dst_w + 2 * dilate_px;
        rects[i].h = charts[i].dst_h + 2 * dilate_px;
        rects[i].x = 0;
        rects[i].y = 0;
        rects[i].was_packed = 0;
        if (rects[i].w > side || rects[i].h > side) return false;
    }
    stbrp_context ctx;
    std::vector<stbrp_node> nodes(static_cast<size_t>(side));
    stbrp_init_target(&ctx, side, side, nodes.data(),
                      static_cast<int>(nodes.size()));
    const int all_packed = stbrp_pack_rects(&ctx, rects.data(), n);
    if (!all_packed) return false;
    for (int i = 0; i < n; ++i) {
        const auto& r = rects[i];
        if (!r.was_packed) return false;
        // Rects in `rects` may be reordered by the packer; r.id is
        // the original index.
        charts[r.id].packed_x = r.x;
        charts[r.id].packed_y = r.y;
    }
    return true;
}

}  // namespace

bool merge_atlases(const std::vector<ChartInput>& inputs,
                   const AtlasMergerOptions& opts,
                   AtlasMergerResult& result) {
    result.output_rgb.clear();
    result.output_w = 0;
    result.output_h = 0;
    result.remapped_uvs.clear();
    result.chosen_atlas_size = 0;
    result.scale_factor = 1.0f;

    if (inputs.empty()) return false;
    const int max_size = opts.max_atlas_size > 0
        ? std::min(opts.max_atlas_size, kHardMaxAtlasSize)
        : kHardMaxAtlasSize;
    const int dilate_px = opts.edge_dilate_px > 0 ? opts.edge_dilate_px : 0;
    const float util = (opts.target_utilization > 0.05f &&
                        opts.target_utilization < 1.0f)
        ? opts.target_utilization : 0.7f;

    // Step 1+2: bbox + crop.
    const int n = static_cast<int>(inputs.size());
    std::vector<CroppedChart> charts(static_cast<size_t>(n));
    for (int i = 0; i < n; ++i) {
        const ChartInput& in = inputs[i];
        if (in.atlas_w <= 0 || in.atlas_h <= 0) return false;
        const size_t expected = static_cast<size_t>(in.atlas_w) *
                                static_cast<size_t>(in.atlas_h) * 3u;
        if (in.atlas_rgb.size() != expected) return false;
        float umin = 0, vmin = 0, umax = 0, vmax = 0;
        if (!compute_uv_bbox(in.uvs, umin, vmin, umax, vmax)) return false;
        charts[i].chart_index = i;
        crop_chart(in, umin, vmin, umax, vmax, charts[i]);
    }

    // Step 3: pick atlas size.
    uint64_t total_chart_px = 0;
    for (const auto& c : charts) {
        total_chart_px += static_cast<uint64_t>(c.dst_w) *
                          static_cast<uint64_t>(c.dst_h);
    }
    int side;
    if (opts.target_atlas_size > 0) {
        side = next_pow2_ge(opts.target_atlas_size);
    } else {
        const double need = static_cast<double>(total_chart_px) /
                            static_cast<double>(util);
        const int approx = static_cast<int>(std::ceil(std::sqrt(need)));
        side = next_pow2_ge(approx);
    }
    if (side > max_size) side = max_size;
    if (side < kMinAtlasSize) side = kMinAtlasSize;
    result.chosen_atlas_size = side;

    // Step 4: global resize so chart pixels fit ~85 % of side² —
    // the 15 % slack absorbs both dilation and rect-pack waste.
    constexpr double kFitFactor = 0.85;
    const double fit_target = kFitFactor *
        static_cast<double>(side) * static_cast<double>(side);
    double scale = 1.0;
    if (static_cast<double>(total_chart_px) > fit_target) {
        scale = std::sqrt(fit_target /
                          static_cast<double>(total_chart_px));
        for (auto& c : charts) {
            if (!resize_chart(c, scale)) return false;
        }
    }
    result.scale_factor = static_cast<float>(scale);

    // Step 5: edge-dilate every chart.
    if (dilate_px > 0) {
        for (auto& c : charts) {
            int dw = 0, dh = 0;
            std::vector<uint8_t> dilated =
                edge_dilate(c.rgb, c.dst_w, c.dst_h, dilate_px, dw, dh);
            // `dst_w/dst_h` continues to track the UNDILATED chart
            // size — the 2·dilate_px belongs to the rect we feed
            // into the packer, not to the UV-relevant region.
            (void)dw;
            (void)dh;
            c.rgb = std::move(dilated);
        }
    }

    // Step 6: pack.
    if (!try_pack(side, dilate_px, charts)) return false;

    // Step 7: composite. Background = chart-pixel-mean (excl.
    // texrecon padding). Charts go in at (packed_x + dilate_px,
    // packed_y + dilate_px) and bring their dilation rim with them
    // — so we blit (dst_w + 2·dilate_px) × (dst_h + 2·dilate_px).
    uint8_t bg_r = 0, bg_g = 0, bg_b = 0;
    {
        // Mean is over CHART pixels only — re-extract from the
        // pre-dilation strip of each chart's now-dilated buffer.
        // After step 5 c.rgb holds the dilated buffer, but for the
        // mean we want only the inner (dst_w × dst_h) sub-rect.
        std::vector<CroppedChart> inner(charts.size());
        for (size_t i = 0; i < charts.size(); ++i) {
            const auto& c = charts[i];
            const int row_stride = (c.dst_w + 2 * dilate_px) * 3;
            inner[i].dst_w = c.dst_w;
            inner[i].dst_h = c.dst_h;
            inner[i].rgb.resize(static_cast<size_t>(c.dst_w) * c.dst_h * 3u);
            for (int y = 0; y < c.dst_h; ++y) {
                const uint8_t* src_row =
                    c.rgb.data() + (y + dilate_px) * row_stride +
                    dilate_px * 3;
                uint8_t* dst_row =
                    inner[i].rgb.data() + static_cast<size_t>(y) * c.dst_w * 3u;
                std::memcpy(dst_row, src_row,
                            static_cast<size_t>(c.dst_w) * 3u);
            }
        }
        compute_mean_bg(inner, bg_r, bg_g, bg_b);
    }
    result.output_w = side;
    result.output_h = side;
    result.output_rgb.assign(
        static_cast<size_t>(side) * static_cast<size_t>(side) * 3u, 0);
    for (size_t i = 0; i + 2 < result.output_rgb.size(); i += 3) {
        result.output_rgb[i + 0] = bg_r;
        result.output_rgb[i + 1] = bg_g;
        result.output_rgb[i + 2] = bg_b;
    }
    for (const auto& c : charts) {
        const int blit_w = c.dst_w + 2 * dilate_px;
        const int blit_h = c.dst_h + 2 * dilate_px;
        for (int y = 0; y < blit_h; ++y) {
            const uint8_t* src_row =
                c.rgb.data() + static_cast<size_t>(y) * blit_w * 3u;
            const int dst_y = c.packed_y + y;
            if (dst_y < 0 || dst_y >= side) continue;
            uint8_t* dst_row =
                result.output_rgb.data() +
                (static_cast<size_t>(dst_y) * side + c.packed_x) * 3u;
            const int dx_max = std::min(blit_w, side - c.packed_x);
            std::memcpy(dst_row, src_row,
                        static_cast<size_t>(dx_max) * 3u);
        }
    }

    // Step 8: remap UVs. For each input UV (u,v):
    //   src px      = (u * src_W,           v * src_H)
    //   relative    = (src_px - crop_x0,    src_py - crop_y0)
    //   resized px  = relative * scale
    //   dilation    = + dilate_px on both axes
    //   atlas px    = + (packed_x, packed_y)
    //   out UV      = atlas_px / side
    result.remapped_uvs.resize(charts.size());
    const double inv_side = 1.0 / static_cast<double>(side);
    for (size_t i = 0; i < charts.size(); ++i) {
        const ChartInput& in = inputs[i];
        const CroppedChart& c = charts[i];
        std::vector<float>& out_uv = result.remapped_uvs[i];
        out_uv.resize(in.uvs.size());
        const double src_W = in.atlas_w;
        const double src_H = in.atlas_h;
        for (size_t k = 0; k + 1 < in.uvs.size(); k += 2) {
            const double u = clamp01(in.uvs[k + 0]);
            const double v = clamp01(in.uvs[k + 1]);
            const double rel_x = u * src_W - c.crop_x0;
            const double rel_y = v * src_H - c.crop_y0;
            const double atlas_x =
                rel_x * scale + dilate_px + c.packed_x;
            const double atlas_y =
                rel_y * scale + dilate_px + c.packed_y;
            double out_u = atlas_x * inv_side;
            double out_v = atlas_y * inv_side;
            if (out_u < 0.0) out_u = 0.0;
            if (out_u > 1.0) out_u = 1.0;
            if (out_v < 0.0) out_v = 0.0;
            if (out_v > 1.0) out_v = 1.0;
            out_uv[k + 0] = static_cast<float>(out_u);
            out_uv[k + 1] = static_cast<float>(out_v);
        }
    }

    return true;
}

}  // namespace aether::glb_norm
