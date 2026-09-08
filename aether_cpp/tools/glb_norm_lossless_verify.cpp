// SPDX-License-Identifier: LicenseRef-Aether3D-Proprietary
// Copyright (c) 2024-2026 Aether3D. All rights reserved.
//
// glb_norm_lossless_verify — empirically prove (or refute) that the
// community FULL-quality tier is lossless.
//
// Full-tier options (matches Dart kCommunityFullNormOptions):
//   target_face_count = 0    (no decimation)
//   target_atlas_size = 0    (auto)
//   max_atlas_size    = 16384
//   texture_format    = PNG
//
// For each input GLB it:
//   1. Parses the INPUT GLB's first primitive: face count, vertex count,
//      and decodes the embedded baseColor texture (dims + RGB pixels).
//   2. Runs aether_glb_norm_run with the FULL opts.
//   3. Parses the OUTPUT GLB: face count, vertex count, output atlas
//      dims, and decodes the output baseColor atlas (RGB pixels).
//   4. Reports:
//        - faces in vs out (must be identical — no triangle dropped).
//        - verts in vs out (atlas-merge may re-index; should not drop
//          geometry — for these single-prim captures it is a pass-through).
//        - atlas dims in vs out + the merger's reported scale_factor proxy
//          (does the 85%-of-side^2 global resize fire? scale==1.0 means no
//          downscale).
//        - texture PSNR: source texture vs output atlas. Because the atlas
//          merger CROPS each chart to its UV bbox, edge-dilates, and
//          re-lays-out into a (possibly different-sized) power-of-2 atlas,
//          a direct full-image PSNR is only meaningful when the output
//          dims equal the source dims AND no resize fired. We compute and
//          report BOTH a same-size direct PSNR (when dims match) and a
//          UV-resampled PSNR: for a dense grid of UVs we sample the source
//          texture (at the chart's original UV) and the output atlas (at
//          the REMAPPED UV) and compare — this is the texel fidelity the
//          renderer actually sees, independent of atlas layout.
//
// This deliberately re-runs the SAME atlas_merger the producer uses, so
// the remapped UVs we sample with are the exact ones written into the GLB.

#include "aether_glb_norm_c.h"
#include "atlas_merger.h"
#include "glb_io.h"

#include <algorithm>
#include <cmath>
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <string>
#include <vector>

// stb_image: declarations only. The IMPLEMENTATION is owned by
// aether3d_core (glb_io.cpp in the Dawn-OFF link graph / glb_loader.cpp in
// Dawn-ON), so we just link against it — defining the impl here too would
// duplicate ~42 symbols. We only call stbi_load_from_memory / stbi_image_free.
#include "stb_image.h"

namespace {

bool read_file(const std::string& path, std::vector<uint8_t>& out) {
    std::FILE* f = std::fopen(path.c_str(), "rb");
    if (!f) { std::fprintf(stderr, "verify: cannot open '%s'\n", path.c_str()); return false; }
    std::fseek(f, 0, SEEK_END);
    const long n = std::ftell(f);
    std::fseek(f, 0, SEEK_SET);
    if (n < 0) { std::fclose(f); return false; }
    out.resize(static_cast<size_t>(n));
    const size_t got = std::fread(out.data(), 1, out.size(), f);
    std::fclose(f);
    return got == out.size();
}

std::string basename_of(const std::string& p) {
    const auto slash = p.find_last_of('/');
    return slash == std::string::npos ? p : p.substr(slash + 1);
}

// Minimal GLB JSON-chunk + BIN-chunk locator. Returns pointers into `glb`.
struct GlbView {
    const char* json = nullptr;
    size_t json_len = 0;
    const uint8_t* bin = nullptr;
    size_t bin_len = 0;
};
bool view_glb(const std::vector<uint8_t>& glb, GlbView& v) {
    if (glb.size() < 20) return false;
    if (std::memcmp(glb.data(), "glTF", 4) != 0) return false;
    const uint32_t json_len =
        glb[12] | (glb[13] << 8) | (glb[14] << 16) | (uint32_t(glb[15]) << 24);
    if (20u + json_len > glb.size()) return false;
    v.json = reinterpret_cast<const char*>(glb.data() + 20);
    v.json_len = json_len;
    size_t off = 20u + json_len;
    if (off + 8 <= glb.size()) {
        const uint32_t bin_len = glb[off] | (glb[off+1] << 8) | (glb[off+2] << 16) |
                                 (uint32_t(glb[off+3]) << 24);
        // off+4..off+8 = 'BIN\0'
        v.bin = glb.data() + off + 8;
        v.bin_len = bin_len;
    }
    return true;
}

// Tolerant string scan helpers for the compact JSON (no nested-object
// parsing needed for the few integers we read).
long find_int_after(const std::string& json, size_t from, const char* key) {
    size_t k = json.find(key, from);
    if (k == std::string::npos) return -1;
    k += std::strlen(key);
    while (k < json.size() && (json[k] == ' ' || json[k] == ':')) ++k;
    return std::strtol(json.c_str() + k, nullptr, 10);
}

// Decode the FIRST baseColor texture image from a GLB into RGB.
// Handles both our compact writer output and the source captures
// (single image, mimeType image/png, bufferView index). We just decode
// images[0].
bool decode_first_image_rgb(const std::vector<uint8_t>& glb,
                            std::vector<uint8_t>& rgb, int& w, int& h) {
    GlbView v;
    if (!view_glb(glb, v)) return false;
    const std::string json(v.json, v.json_len);
    // images[0].bufferView
    size_t imgs = json.find("\"images\":[");
    if (imgs == std::string::npos) return false;
    long bv_idx = find_int_after(json, imgs, "\"bufferView\":");
    if (bv_idx < 0) return false;
    // Walk bufferViews to the bv_idx-th element, read byteOffset+byteLength.
    size_t bvs = json.find("\"bufferViews\":[");
    if (bvs == std::string::npos) return false;
    size_t pos = bvs;
    long byte_off = 0, byte_len = 0;
    for (long i = 0; i <= bv_idx; ++i) {
        size_t k = json.find("\"byteLength\":", pos);
        if (k == std::string::npos) return false;
        // byteOffset may precede byteLength in the same element.
        size_t elem_start = json.rfind('{', k);
        long bo = find_int_after(json, elem_start, "\"byteOffset\":");
        byte_off = (bo < 0) ? 0 : bo;
        byte_len = std::strtol(json.c_str() + k + std::strlen("\"byteLength\":"), nullptr, 10);
        pos = k + 1;
    }
    if (!v.bin || byte_off < 0 || byte_len <= 0 ||
        static_cast<size_t>(byte_off) + byte_len > v.bin_len) return false;
    int comp = 0;
    stbi_uc* px = stbi_load_from_memory(v.bin + byte_off, static_cast<int>(byte_len),
                                        &w, &h, &comp, 3);
    if (!px) return false;
    rgb.assign(px, px + static_cast<size_t>(w) * h * 3);
    stbi_image_free(px);
    return true;
}

double psnr_same_size(const std::vector<uint8_t>& a, const std::vector<uint8_t>& b) {
    if (a.size() != b.size() || a.empty()) return -1.0;
    double mse = 0.0;
    for (size_t i = 0; i < a.size(); ++i) {
        const double d = double(a[i]) - double(b[i]);
        mse += d * d;
    }
    mse /= double(a.size());
    if (mse == 0.0) return 1e9;  // +inf sentinel
    return 10.0 * std::log10(255.0 * 255.0 / mse);
}

// Nearest-neighbour sample RGB at (u,v) in [0,1], top-left origin.
// Uses the same texel-center convention as a GPU sampler: texel index =
// floor(u * w). Lets us check whether matched UVs land on identical texels
// (pure integer re-layout) without the double-bilinear blur of two
// independent interpolations confounding the loss measurement.
inline void sample_rgb_nn(const std::vector<uint8_t>& img, int w, int h,
                          double u, double v, double out[3]) {
    int x = int(std::floor(u * w));
    int y = int(std::floor(v * h));
    if (x < 0) x = 0; if (x >= w) x = w - 1;
    if (y < 0) y = 0; if (y >= h) y = h - 1;
    for (int c = 0; c < 3; ++c)
        out[c] = img[(size_t(y) * w + x) * 3 + c];
}

// Bilinear sample RGB at (u,v) in [0,1], top-left origin.
inline void sample_rgb(const std::vector<uint8_t>& img, int w, int h,
                       double u, double v, double out[3]) {
    double x = u * (w - 1);
    double y = v * (h - 1);
    if (x < 0) x = 0; if (x > w - 1) x = w - 1;
    if (y < 0) y = 0; if (y > h - 1) y = h - 1;
    int x0 = int(std::floor(x)), y0 = int(std::floor(y));
    int x1 = std::min(x0 + 1, w - 1), y1 = std::min(y0 + 1, h - 1);
    double fx = x - x0, fy = y - y0;
    for (int c = 0; c < 3; ++c) {
        const double p00 = img[(size_t(y0) * w + x0) * 3 + c];
        const double p10 = img[(size_t(y0) * w + x1) * 3 + c];
        const double p01 = img[(size_t(y1) * w + x0) * 3 + c];
        const double p11 = img[(size_t(y1) * w + x1) * 3 + c];
        const double top = p00 * (1 - fx) + p10 * fx;
        const double bot = p01 * (1 - fx) + p11 * fx;
        out[c] = top * (1 - fy) + bot * fy;
    }
}

}  // namespace

int main(int argc, char** argv) {
    std::vector<std::string> inputs;
    for (int a = 1; a < argc; ++a) inputs.push_back(argv[a]);
    if (inputs.empty()) {
        std::fprintf(stderr, "usage: glb_norm_lossless_verify <in1.glb> ...\n");
        return 2;
    }

    std::printf("# FULL-TIER LOSSLESS VERIFICATION "
                "(target_face=0, target_atlas=0, max_atlas=16384, PNG)\n\n");

    for (const std::string& path : inputs) {
        const std::string name = basename_of(path);
        std::vector<uint8_t> in_bytes;
        if (!read_file(path, in_bytes)) continue;

        // ── Input geometry + texture (via library parse for exactness) ──
        aether::glb_norm::InputGlb parsed;
        std::string perr;
        if (!aether::glb_norm::parse_glb(in_bytes.data(), in_bytes.size(),
                                         parsed, &perr)) {
            std::printf("%-26s PARSE FAILED: %s\n", name.c_str(), perr.c_str());
            continue;
        }
        const uint32_t in_faces = uint32_t(parsed.indices.size() / 3);
        const uint32_t in_verts = uint32_t(parsed.positions.size() / 3);

        std::vector<uint8_t> src_rgb;
        int src_w = 0, src_h = 0;
        const bool have_src = decode_first_image_rgb(in_bytes, src_rgb, src_w, src_h);

        // ── Run the normalizer with FULL opts ──
        aether_glb_norm_options_t opts;
        aether_glb_norm_options_default(&opts);
        opts.target_face_count = 0;        // no decimation
        opts.target_atlas_size = 0;        // auto
        opts.max_atlas_size = 16384;
        opts.texture_format = AETHER_GLB_NORM_TEX_PNG;

        aether_glb_norm_buffer_t out_buf{};
        aether_glb_norm_stats_t stats{};
        const aether_glb_norm_result_t rc = aether_glb_norm_run(
            in_bytes.data(), in_bytes.size(), &opts, nullptr, nullptr,
            &out_buf, &stats);
        if (rc != AETHER_GLB_NORM_OK) {
            std::printf("%-26s RUN FAILED: %s\n", name.c_str(),
                        aether_glb_norm_result_str(rc));
            if (out_buf.data) aether_glb_norm_buffer_free(&out_buf);
            continue;
        }
        std::vector<uint8_t> out_bytes(out_buf.data, out_buf.data + out_buf.size);
        aether_glb_norm_buffer_free(&out_buf);

        // ── Output geometry + atlas ──
        GlbView ov;
        view_glb(out_bytes, ov);
        const std::string ojson(ov.json, ov.json_len);
        // POSITION accessor 0 count == output vert count; indices accessor 3.
        // Use stats (authoritative) for faces; verts from POSITION accessor.
        long out_verts = find_int_after(ojson, ojson.find("\"accessors\":["),
                                        "\"count\":");
        const uint32_t out_faces = stats.output_face_count;

        std::vector<uint8_t> out_rgb;
        int out_w = 0, out_h = 0;
        const bool have_out = decode_first_image_rgb(out_bytes, out_rgb, out_w, out_h);

        // ── Re-run atlas_merger to learn scale_factor + remapped UVs ──
        aether::glb_norm::AtlasMergerOptions am_opts;
        am_opts.target_atlas_size = 0;
        am_opts.max_atlas_size = 16384;
        aether::glb_norm::AtlasMergerResult merged;
        const bool merged_ok =
            aether::glb_norm::merge_atlases(parsed.charts, am_opts, merged);

        // ── Report ──
        std::printf("== %s ==\n", name.c_str());
        std::printf("  GEOMETRY  faces in=%u out=%u  %s   verts in=%u out=%ld  %s\n",
                    in_faces, out_faces,
                    (in_faces == out_faces) ? "MATCH (no triangle dropped)"
                                            : "*** MISMATCH ***",
                    in_verts, out_verts,
                    (long(in_verts) == out_verts) ? "MATCH"
                        : "(re-index; check no drop)");

        if (have_src && have_out) {
            std::printf("  TEXTURE   source=%dx%d  output atlas=%dx%d  %s\n",
                        src_w, src_h, out_w, out_h,
                        (out_w >= src_w && out_h >= src_h)
                            ? "no downscale of atlas side"
                            : "(atlas smaller than source — see scale_factor)");
        }
        if (merged_ok) {
            std::printf("  MERGER    chosen_atlas=%dpx  scale_factor=%.6f  %s\n",
                        merged.chosen_atlas_size, merged.scale_factor,
                        (merged.scale_factor >= 0.999f)
                            ? "85%-resize did NOT fire (scale==1.0, no downscale)"
                            : "*** 85%-resize FIRED — chart pixels downscaled ***");
        }

        // Same-size direct PSNR (only meaningful if dims equal).
        if (have_src && have_out && src_w == out_w && src_h == out_h) {
            const double p = psnr_same_size(src_rgb, out_rgb);
            if (p >= 1e8)
                std::printf("  PSNR(direct, same dims) = +inf (BIT-IDENTICAL)\n");
            else
                std::printf("  PSNR(direct, same dims) = %.2f dB\n", p);
        } else if (have_src && have_out) {
            std::printf("  PSNR(direct) = n/a (atlas dims %dx%d != source %dx%d; "
                        "atlas was re-laid-out)\n", out_w, out_h, src_w, src_h);
        }

        // UV-resampled PSNR: what the renderer actually samples. For each
        // chart, walk a stride of its per-vertex UVs; sample the source
        // texture at the original UV (frac-wrapped) and the output atlas at
        // the remapped UV; accumulate MSE. This is layout-independent.
        if (have_src && have_out && merged_ok &&
            merged.remapped_uvs.size() == parsed.charts.size()) {
            double mse_bil = 0.0, mse_nn = 0.0;
            uint64_t cnt = 0, exact_nn = 0;
            for (size_t ci = 0; ci < parsed.charts.size(); ++ci) {
                const auto& src_uv = parsed.charts[ci].uvs;
                const auto& dst_uv = merged.remapped_uvs[ci];
                if (src_uv.size() != dst_uv.size()) continue;
                for (size_t k = 0; k + 1 < src_uv.size(); k += 2) {
                    double su = src_uv[k] - std::floor(src_uv[k]);
                    double sv = src_uv[k + 1] - std::floor(src_uv[k + 1]);
                    double du = dst_uv[k], dv = dst_uv[k + 1];
                    double a[3], b[3], an[3], bn[3];
                    sample_rgb(src_rgb, src_w, src_h, su, sv, a);
                    sample_rgb(out_rgb, out_w, out_h, du, dv, b);
                    sample_rgb_nn(src_rgb, src_w, src_h, su, sv, an);
                    sample_rgb_nn(out_rgb, out_w, out_h, du, dv, bn);
                    bool exact = true;
                    for (int c = 0; c < 3; ++c) {
                        mse_bil += (a[c] - b[c]) * (a[c] - b[c]);
                        mse_nn  += (an[c] - bn[c]) * (an[c] - bn[c]);
                        if (an[c] != bn[c]) exact = false;
                    }
                    if (exact) ++exact_nn;
                    cnt += 3;
                }
            }
            if (cnt > 0) {
                mse_bil /= double(cnt);
                mse_nn  /= double(cnt);
                auto db = [](double mse) {
                    return mse <= 0.0 ? 1e9 : 10.0 * std::log10(255.0 * 255.0 / mse);
                };
                const double pb = db(mse_bil), pn = db(mse_nn);
                const uint64_t taps = cnt / 3;
                std::printf("  PSNR(UV-resampled bilinear, %llu taps) = %s%.2f dB\n",
                            (unsigned long long)taps,
                            pb >= 1e8 ? "+inf / " : "", pb >= 1e8 ? 0.0 : pb);
                std::printf("  PSNR(UV-resampled nearest,  %llu taps) = %s%.2f dB  "
                            "(%.2f%% texels bit-identical)\n",
                            (unsigned long long)taps,
                            pn >= 1e8 ? "+inf / " : "", pn >= 1e8 ? 0.0 : pn,
                            100.0 * double(exact_nn) / double(taps));
            }
        }
        std::printf("\n");
    }
    std::fflush(stdout);
    return 0;
}
