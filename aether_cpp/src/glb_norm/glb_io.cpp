// SPDX-License-Identifier: LicenseRef-Aether3D-Proprietary
// Copyright (c) 2024-2026 Aether3D. All rights reserved.
//
// glb_io.cpp — Phase 2 GLB read/write.
//
// parse_glb uses cgltf (parser only — declarations included here, the
// CGLTF_IMPLEMENTATION lives in src/pocketworld/glb_loader.cpp). Texture
// bytes are decoded through stb_image (same single-TU constraint:
// declarations only; STB_IMAGE_IMPLEMENTATION is in glb_loader.cpp).
//
// write_glb owns STB_IMAGE_WRITE_IMPLEMENTATION (no other TU defines
// it) and emits the merged atlas as embedded PNG.
//
// We hand-roll the GLB writer instead of pulling in cgltf_write.h —
// the output schema is fixed (one mesh, one prim, one material, one
// texture, one PNG) and easier to spell directly than to construct via
// the cgltf_data tree. JSON has no user-supplied strings, so the only
// escaping we'd need is for filenames / generators, which we hard-code.
//
// Critical material rule (verified against three.js + Khronos validator,
// repeats a real server-side bug from trimesh's emitter): the output
// material MUST set metallicFactor explicitly to 0.0. The glTF default
// is 1.0 (fully metallic), which under PBR with no environment IBL
// renders the entire model black. Conversely we DO NOT write
// baseColorFactor=[1,1,1,1] — let the spec default apply. trimesh's
// uint8 cast of the float made this exact bug ship to production once.

#include "glb_io.h"

#include <algorithm>
#include <array>
#include <cmath>
#include <cstdarg>
#include <cstdint>
#include <cstdio>
#include <cstring>
#include <limits>
#include <utility>
#include <vector>

// cgltf + stb_image impl-macros: ODR-safe single-TU rule says exactly
// one source file in the link graph defines them. Dawn-ON builds get
// them from src/pocketworld/glb_loader.cpp (the GPU loader path);
// Dawn-OFF builds (notably the Phase 0/1 build_phase0 verification dir
// configured with -DAETHER_ENABLE_DAWN=OFF) don't compile glb_loader.cpp,
// so glb_io.cpp picks up ownership instead. AETHER_ENABLE_DAWN is the
// CMake-set compile def that distinguishes the two link graphs.
#ifndef AETHER_ENABLE_DAWN
#  define CGLTF_IMPLEMENTATION
#  define STB_IMAGE_IMPLEMENTATION
// glTF only embeds PNG / JPEG. Same trim-set as glb_loader.cpp.
#  define STBI_NO_BMP
#  define STBI_NO_GIF
#  define STBI_NO_HDR
#  define STBI_NO_PIC
#  define STBI_NO_PNM
#  define STBI_NO_TGA
#  define STBI_NO_PSD
#endif
#include "cgltf.h"
#include "stb_image.h"

// stb_image_write's built-in zlib (miniz-style) emits PNGs ~20-50%
// larger than real zlib. aether3d_core already links system zlib for
// SPZ + other paths, so wire the deflate stream through compress2().
// This is the explicit STBIW_ZLIB_COMPRESS hook documented in
// stb_image_write.h. On the baseline_apr25.glb acceptance asset this
// drops the output PNG by ~30% and brings the output / input ratio
// from 1.23 to within the ±20% acceptance band.
#include <zlib.h>
namespace aether::glb_norm::detail {
extern "C" unsigned char* stbiw_zlib_compress_via_zlib(
    unsigned char* data, int data_len, int* out_len, int quality);
}  // namespace aether::glb_norm::detail
#define STBIW_ZLIB_COMPRESS aether::glb_norm::detail::stbiw_zlib_compress_via_zlib
#define STB_IMAGE_WRITE_IMPLEMENTATION
// Memory-callback emit only (we hand back a std::vector<uint8_t> via
// stbi_write_png_to_func). No need for the stdio convenience wrappers.
#define STBI_WRITE_NO_STDIO
#include "stb_image_write.h"

namespace aether::glb_norm::detail {
extern "C" unsigned char* stbiw_zlib_compress_via_zlib(
    unsigned char* data, int data_len, int* out_len, int quality) {
    // stbiw passes quality 0..10 (effectively level 0..9 with some
    // gibberish at 10 — clamp to zlib's 0..9 range). At level 9 the
    // PNG is roughly the same size as `pngcrush -ow` but ~50× faster.
    int level = quality;
    if (level < 0) level = Z_DEFAULT_COMPRESSION;
    if (level > 9) level = 9;
    uLongf dest_len = compressBound(static_cast<uLong>(data_len));
    auto* dest = static_cast<unsigned char*>(std::malloc(dest_len));
    if (!dest) {
        *out_len = 0;
        return nullptr;
    }
    const int r = compress2(dest, &dest_len, data,
                            static_cast<uLong>(data_len), level);
    if (r != Z_OK) {
        std::free(dest);
        *out_len = 0;
        return nullptr;
    }
    *out_len = static_cast<int>(dest_len);
    return dest;
}
}  // namespace aether::glb_norm::detail

namespace aether::glb_norm {

namespace {

void glb_io_log(std::string* err, const char* fmt, ...) {
    // Always log to stderr (mirrors glb_loader.cpp), and additionally
    // capture into *err if the caller asked for an error string.
    char buf[512];
    va_list args;
    va_start(args, fmt);
    int n = std::vsnprintf(buf, sizeof(buf), fmt, args);
    va_end(args);
    if (n < 0) n = 0;
    if (static_cast<size_t>(n) >= sizeof(buf)) n = sizeof(buf) - 1;
    std::fprintf(stderr, "[Aether3D][glb_io] %.*s\n", n, buf);
    if (err) {
        if (!err->empty()) err->append("; ");
        err->append(buf, static_cast<size_t>(n));
    }
}

// 4×4 column-major matrix transforms — same convention as glb_loader.cpp.
void transform_point(const float m[16], float x, float y, float z,
                     float& ox, float& oy, float& oz) {
    ox = m[0]*x + m[4]*y + m[8]*z  + m[12];
    oy = m[1]*x + m[5]*y + m[9]*z  + m[13];
    oz = m[2]*x + m[6]*y + m[10]*z + m[14];
}
void transform_dir(const float m[16], float x, float y, float z,
                   float& ox, float& oy, float& oz) {
    ox = m[0]*x + m[4]*y + m[8]*z;
    oy = m[1]*x + m[5]*y + m[9]*z;
    oz = m[2]*x + m[6]*y + m[10]*z;
    const float len2 = ox*ox + oy*oy + oz*oz;
    if (len2 > 1e-12f) {
        const float inv = 1.0f / std::sqrt(len2);
        ox *= inv; oy *= inv; oz *= inv;
    }
}

bool read_attr_floats(const cgltf_accessor* acc, std::size_t i,
                      float* out, std::size_t n) {
    if (!acc) return false;
    return cgltf_accessor_read_float(acc, i, out, n);
}

std::vector<uint32_t> read_indices_u32(const cgltf_accessor* acc,
                                       std::size_t fallback_count) {
    std::vector<uint32_t> out;
    if (!acc) {
        // Non-indexed primitive — generate trivial 0..fallback_count.
        out.resize(fallback_count);
        for (std::size_t i = 0; i < fallback_count; ++i) {
            out[i] = static_cast<uint32_t>(i);
        }
        return out;
    }
    out.resize(acc->count);
    for (std::size_t i = 0; i < acc->count; ++i) {
        cgltf_uint v = 0;
        cgltf_accessor_read_uint(acc, i, &v, 1);
        out[i] = static_cast<uint32_t>(v);
    }
    return out;
}

// Decode an embedded glTF image into RGB bytes. Honors only the
// inline buffer-view path; external URIs are not in scope (Phase 2
// brief: "extract baseColorTexture → image bytes via
// data->images[*].buffer_view"). Returns true on success.
bool decode_image_to_rgb(const cgltf_image* img,
                         std::vector<uint8_t>& rgb,
                         int& w, int& h, std::string* err) {
    if (!img || !img->buffer_view) {
        glb_io_log(err, "image has no embedded buffer_view");
        return false;
    }
    const cgltf_buffer_view* bv = img->buffer_view;
    if (!bv->buffer || !bv->buffer->data) {
        glb_io_log(err, "image buffer_view has no backing data — "
                   "did you forget cgltf_load_buffers?");
        return false;
    }
    const uint8_t* src = static_cast<const uint8_t*>(bv->buffer->data) + bv->offset;
    int comp = 0;
    stbi_uc* pixels = stbi_load_from_memory(src, static_cast<int>(bv->size),
                                            &w, &h, &comp,
                                            /*desired_channels=*/3);
    if (!pixels) {
        glb_io_log(err, "stbi_load_from_memory failed: %s",
                   stbi_failure_reason());
        return false;
    }
    if (w <= 0 || h <= 0) {
        glb_io_log(err, "decoded image has invalid dimensions w=%d h=%d", w, h);
        stbi_image_free(pixels);
        return false;
    }
    rgb.assign(pixels, pixels + static_cast<size_t>(w) * h * 3);
    stbi_image_free(pixels);
    return true;
}

// 1×1 fallback chart from a baseColorFactor (or white if no PBR
// material). Lets prims without an embedded texture flow through the
// merger uniformly. Each output pixel is just the factor color.
void synth_constant_chart(const float bcf[4],
                          std::vector<uint8_t>& rgb,
                          int& w, int& h) {
    auto to_byte = [](float c) -> uint8_t {
        if (!(c == c)) return 255;        // NaN guard
        if (c <= 0.0f) return 0;
        if (c >= 1.0f) return 255;
        return static_cast<uint8_t>(std::round(c * 255.0f));
    };
    w = 1; h = 1;
    rgb.assign(3, 0);
    rgb[0] = to_byte(bcf[0]);
    rgb[1] = to_byte(bcf[1]);
    rgb[2] = to_byte(bcf[2]);
}

}  // namespace

bool parse_glb(const uint8_t* bytes, std::size_t size, InputGlb& out,
               std::string* err) {
    out = InputGlb{};
    if (!bytes || size == 0) {
        glb_io_log(err, "empty input bytes");
        return false;
    }

    cgltf_options opts{};
    cgltf_data* data = nullptr;
    cgltf_result r = cgltf_parse(&opts, bytes, size, &data);
    if (r != cgltf_result_success) {
        glb_io_log(err, "cgltf_parse failed: status=%d", static_cast<int>(r));
        return false;
    }
    // Manual cleanup at every exit path — cgltf is C, no RAII helper.
    auto cleanup = [&]() { if (data) cgltf_free(data); };

    // For embedded GLBs the BIN chunk ships as data->bin /
    // data->bin_size. Pass nullptr as the gltf_path arg so cgltf
    // doesn't try to resolve external .bin files; the binary chunk
    // is already in memory.
    r = cgltf_load_buffers(&opts, data, nullptr);
    if (r != cgltf_result_success) {
        glb_io_log(err, "cgltf_load_buffers failed: status=%d",
                   static_cast<int>(r));
        cleanup();
        return false;
    }
    r = cgltf_validate(data);
    if (r != cgltf_result_success) {
        glb_io_log(err, "cgltf_validate failed: status=%d",
                   static_cast<int>(r));
        cleanup();
        return false;
    }

    out.input_material_count = static_cast<uint32_t>(data->materials_count);

    // Walk scene → node tree (matches glb_loader.cpp). Some assets
    // bake unit / orientation conversions into the root node; without
    // applying the world transform we'd emit positions in an alternate
    // basis from what the asset author authored. Photogrammetry GLBs
    // generally have identity transforms, so this is a no-op there
    // but harmless to apply.
    using NodeMeshPair = std::pair<const cgltf_node*, const cgltf_mesh*>;
    std::vector<NodeMeshPair> draws;
    auto walk = [&draws](const cgltf_node* n, auto& self) -> void {
        if (!n) return;
        if (n->mesh) draws.emplace_back(n, n->mesh);
        for (cgltf_size c = 0; c < n->children_count; ++c) {
            self(n->children[c], self);
        }
    };
    if (data->scenes_count > 0) {
        const cgltf_scene* scene = data->scene ? data->scene : &data->scenes[0];
        for (cgltf_size i = 0; i < scene->nodes_count; ++i) {
            walk(scene->nodes[i], walk);
        }
    } else {
        for (cgltf_size i = 0; i < data->nodes_count; ++i) {
            walk(&data->nodes[i], walk);
        }
    }
    if (draws.empty()) {
        // No scene graph → enumerate meshes directly (rare in practice).
        for (cgltf_size i = 0; i < data->meshes_count; ++i) {
            draws.emplace_back(nullptr, &data->meshes[i]);
        }
    }

    uint32_t primitive_count = 0;
    for (const auto& d : draws) {
        primitive_count += static_cast<uint32_t>(d.second->primitives_count);
    }
    out.charts.reserve(primitive_count);
    out.chart_vertex_ranges.reserve(primitive_count);
    out.chart_face_ranges.reserve(primitive_count);

    for (const auto& d : draws) {
        const cgltf_node* node = d.first;
        const cgltf_mesh& mesh = *d.second;
        float xform[16];
        if (node) {
            cgltf_node_transform_world(node, xform);
        } else {
            std::memset(xform, 0, sizeof(xform));
            xform[0] = xform[5] = xform[10] = xform[15] = 1.0f;
        }
        for (cgltf_size pi = 0; pi < mesh.primitives_count; ++pi) {
            const cgltf_primitive& prim = mesh.primitives[pi];
            ++out.input_primitive_count;
            if (prim.type != cgltf_primitive_type_triangles) {
                glb_io_log(err, "prim %zu: non-triangle topology %d skipped",
                           pi, static_cast<int>(prim.type));
                continue;
            }

            const cgltf_accessor* acc_pos = nullptr;
            const cgltf_accessor* acc_nrm = nullptr;
            const cgltf_accessor* acc_uv  = nullptr;
            for (cgltf_size ai = 0; ai < prim.attributes_count; ++ai) {
                const cgltf_attribute& attr = prim.attributes[ai];
                if (attr.type == cgltf_attribute_type_position) acc_pos = attr.data;
                else if (attr.type == cgltf_attribute_type_normal) acc_nrm = attr.data;
                else if (attr.type == cgltf_attribute_type_texcoord && attr.index == 0) acc_uv = attr.data;
            }
            if (!acc_pos) {
                glb_io_log(err, "prim %zu: missing POSITION; skipped", pi);
                continue;
            }
            if (!acc_uv) {
                // No TEXCOORD_0 — atlas merger needs UVs to compute
                // per-chart bbox. Skip rather than guess.
                glb_io_log(err, "prim %zu: missing TEXCOORD_0; skipped", pi);
                continue;
            }

            const std::size_t vcount = acc_pos->count;
            const uint32_t vstart = static_cast<uint32_t>(out.positions.size() / 3);

            // Per-vertex positions / normals (world-baked) + UVs.
            std::vector<float> uvs_local(vcount * 2);
            for (std::size_t v = 0; v < vcount; ++v) {
                float p[3] = {0,0,0};
                float n[3] = {0,1,0};
                float u[2] = {0,0};
                read_attr_floats(acc_pos, v, p, 3);
                if (acc_nrm) read_attr_floats(acc_nrm, v, n, 3);
                read_attr_floats(acc_uv, v, u, 2);
                float wp[3];
                float wn[3];
                transform_point(xform, p[0], p[1], p[2], wp[0], wp[1], wp[2]);
                if (acc_nrm) {
                    transform_dir(xform, n[0], n[1], n[2], wn[0], wn[1], wn[2]);
                } else {
                    wn[0] = 0; wn[1] = 1; wn[2] = 0;
                }
                out.positions.push_back(wp[0]);
                out.positions.push_back(wp[1]);
                out.positions.push_back(wp[2]);
                out.normals.push_back(wn[0]);
                out.normals.push_back(wn[1]);
                out.normals.push_back(wn[2]);
                uvs_local[2*v + 0] = u[0];
                uvs_local[2*v + 1] = u[1];
            }
            out.chart_vertex_ranges.emplace_back(vstart, static_cast<uint32_t>(vcount));

            // Indices → global, offset by vstart.
            std::vector<uint32_t> idx = read_indices_u32(prim.indices, vcount);
            const uint32_t face_start = static_cast<uint32_t>(out.indices.size() / 3);
            const uint32_t face_count = static_cast<uint32_t>(idx.size() / 3);
            for (uint32_t v : idx) out.indices.push_back(v + vstart);
            out.chart_face_ranges.emplace_back(face_start, face_count);

            // Material → baseColor RGB image (or 1×1 from baseColorFactor).
            ChartInput chart;
            chart.uvs = std::move(uvs_local);
            const cgltf_material* m = prim.material;
            const cgltf_texture* tex = nullptr;
            float bcf[4] = {1.0f, 1.0f, 1.0f, 1.0f};
            if (m && m->has_pbr_metallic_roughness) {
                const auto& pbr = m->pbr_metallic_roughness;
                bcf[0] = pbr.base_color_factor[0];
                bcf[1] = pbr.base_color_factor[1];
                bcf[2] = pbr.base_color_factor[2];
                bcf[3] = pbr.base_color_factor[3];
                if (pbr.base_color_texture.texture) {
                    tex = pbr.base_color_texture.texture;
                }
            }
            if (tex && tex->image) {
                if (!decode_image_to_rgb(tex->image, chart.atlas_rgb,
                                         chart.atlas_w, chart.atlas_h, err)) {
                    cleanup();
                    return false;
                }
            } else {
                synth_constant_chart(bcf, chart.atlas_rgb,
                                     chart.atlas_w, chart.atlas_h);
            }
            out.charts.push_back(std::move(chart));
        }
    }

    cleanup();

    if (out.charts.empty()) {
        glb_io_log(err, "no usable primitives in input GLB");
        return false;
    }
    return true;
}

// ─── GLB writer ─────────────────────────────────────────────────────────
namespace {

// stb_image_write callback — appends to a std::vector<uint8_t>.
void png_append_cb(void* context, void* data, int size) {
    auto* dst = static_cast<std::vector<uint8_t>*>(context);
    const auto* src = static_cast<const uint8_t*>(data);
    dst->insert(dst->end(), src, src + size);
}

bool encode_png_to_memory(const AtlasMergerResult& m,
                          std::vector<uint8_t>& png_bytes,
                          std::string* err) {
    png_bytes.clear();
    // Max zlib level — small extra CPU vs default 8, several MB
    // smaller PNG on a typical photogrammetry atlas.
    stbi_write_png_compression_level = 9;
    const int stride = m.output_w * 3;
    const int ok = stbi_write_png_to_func(
        png_append_cb, &png_bytes,
        m.output_w, m.output_h, /*comp=*/3,
        m.output_rgb.data(), stride);
    if (!ok || png_bytes.empty()) {
        glb_io_log(err, "stbi_write_png_to_func failed (w=%d h=%d)",
                   m.output_w, m.output_h);
        return false;
    }
    return true;
}

// Compact float formatter — %.9g preserves the round-trip for
// IEEE-754 single precision, which is all glTF cares about for
// vertex positions, normals, and UVs. Strips trailing junk.
void append_float(std::string& s, float v) {
    char buf[32];
    if (std::isfinite(v)) {
        std::snprintf(buf, sizeof(buf), "%.9g", static_cast<double>(v));
    } else {
        // glTF doesn't permit non-finite values; substitute 0 and
        // log. The merger upstream shouldn't produce these for
        // correctly-formed inputs.
        std::snprintf(buf, sizeof(buf), "0");
    }
    s.append(buf);
}

void append_uint(std::string& s, uint64_t v) {
    char buf[32];
    std::snprintf(buf, sizeof(buf), "%llu", static_cast<unsigned long long>(v));
    s.append(buf);
}

// 4-byte align — glTF requires both chunk bodies and bufferView
// offsets to be 4-byte aligned.
uint64_t align4(uint64_t v) { return (v + 3u) & ~uint64_t(3u); }

}  // namespace

bool write_glb(const InputGlb& in, const AtlasMergerResult& merged,
               std::vector<uint8_t>& out_bytes, std::string* err) {
    out_bytes.clear();

    if (in.positions.empty() || (in.positions.size() % 3) != 0) {
        glb_io_log(err, "positions empty or not a multiple of 3");
        return false;
    }
    if (in.indices.empty() || (in.indices.size() % 3) != 0) {
        glb_io_log(err, "indices empty or not a multiple of 3");
        return false;
    }
    if (in.normals.size() != in.positions.size()) {
        glb_io_log(err, "normals.size (%zu) != positions.size (%zu)",
                   in.normals.size(), in.positions.size());
        return false;
    }
    if (merged.output_w <= 0 || merged.output_h <= 0 ||
        merged.output_rgb.size() !=
            static_cast<size_t>(merged.output_w) *
            static_cast<size_t>(merged.output_h) * 3u) {
        glb_io_log(err, "merged atlas dims/buffer mismatch");
        return false;
    }
    if (merged.remapped_uvs.size() != in.charts.size() ||
        merged.remapped_uvs.size() != in.chart_vertex_ranges.size()) {
        glb_io_log(err, "remapped_uvs / charts / chart_vertex_ranges "
                   "size mismatch");
        return false;
    }

    // Build the global per-vertex UV array by stitching merged.remapped_uvs
    // back into vertex slots via chart_vertex_ranges.
    const uint32_t vcount = static_cast<uint32_t>(in.positions.size() / 3);
    std::vector<float> global_uvs(static_cast<size_t>(vcount) * 2u, 0.0f);
    for (size_t ci = 0; ci < in.charts.size(); ++ci) {
        const uint32_t vstart = in.chart_vertex_ranges[ci].first;
        const uint32_t vc     = in.chart_vertex_ranges[ci].second;
        const auto& uv = merged.remapped_uvs[ci];
        if (uv.size() != static_cast<size_t>(vc) * 2u) {
            glb_io_log(err, "chart %zu remapped_uvs size %zu != "
                       "expected %u (vc*2)", ci, uv.size(), vc * 2u);
            return false;
        }
        std::memcpy(global_uvs.data() + static_cast<size_t>(vstart) * 2u,
                    uv.data(),
                    uv.size() * sizeof(float));
    }

    // POSITION min/max — required by glTF spec for the position
    // accessor (used by viewers for view-frustum culling without
    // walking the vertex buffer).
    float pmin[3] = { std::numeric_limits<float>::infinity(),
                      std::numeric_limits<float>::infinity(),
                      std::numeric_limits<float>::infinity() };
    float pmax[3] = { -std::numeric_limits<float>::infinity(),
                      -std::numeric_limits<float>::infinity(),
                      -std::numeric_limits<float>::infinity() };
    for (uint32_t v = 0; v < vcount; ++v) {
        for (int j = 0; j < 3; ++j) {
            const float p = in.positions[3*v + j];
            if (p < pmin[j]) pmin[j] = p;
            if (p > pmax[j]) pmax[j] = p;
        }
    }
    if (!std::isfinite(pmin[0])) {
        glb_io_log(err, "POSITION min/max contains non-finite values "
                   "(empty mesh?)");
        return false;
    }

    // Encode merged atlas as PNG.
    std::vector<uint8_t> png_bytes;
    if (!encode_png_to_memory(merged, png_bytes, err)) {
        return false;
    }

    // Pre-compute bufferView byte sizes + offsets in BIN.
    const uint64_t pos_bytes = static_cast<uint64_t>(in.positions.size()) * sizeof(float);
    const uint64_t nrm_bytes = static_cast<uint64_t>(in.normals.size())   * sizeof(float);
    const uint64_t uv_bytes  = static_cast<uint64_t>(global_uvs.size())   * sizeof(float);
    const uint64_t idx_bytes = static_cast<uint64_t>(in.indices.size())   * sizeof(uint32_t);
    const uint64_t png_bytes_len = static_cast<uint64_t>(png_bytes.size());

    // Each bufferView starts at a 4-byte boundary. Float / uint32
    // arrays are naturally aligned, but the PNG bufferView needs
    // padding bytes since PNG length isn't constrained to multiples
    // of 4.
    const uint64_t pos_off = 0;
    const uint64_t nrm_off = align4(pos_off + pos_bytes);
    const uint64_t uv_off  = align4(nrm_off + nrm_bytes);
    const uint64_t idx_off = align4(uv_off + uv_bytes);
    const uint64_t png_off = align4(idx_off + idx_bytes);
    const uint64_t bin_payload = png_off + png_bytes_len;
    const uint64_t bin_total   = align4(bin_payload);   // chunk-padded

    // Build JSON. Compact (no whitespace) — keeps parse time down
    // for the receiver and shrinks the file.
    std::string j;
    j.reserve(2048);
    j.append("{\"asset\":{\"version\":\"2.0\",\"generator\":\"aether_glb_norm/2\"}");
    j.append(",\"scene\":0");
    j.append(",\"scenes\":[{\"nodes\":[0]}]");
    j.append(",\"nodes\":[{\"mesh\":0}]");
    j.append(",\"meshes\":[{\"primitives\":[{\"attributes\":{\"POSITION\":0,\"NORMAL\":1,\"TEXCOORD_0\":2},\"indices\":3,\"material\":0}]}]");
    // Material — explicit metallicFactor=0 (glTF default 1.0 == fully
    // metallic == black under no-IBL renderers). doubleSided=false to
    // match the existing pipeline. baseColorFactor intentionally
    // omitted (let spec default [1,1,1,1] apply).
    j.append(",\"materials\":[{\"name\":\"merged\",\"pbrMetallicRoughness\":{\"baseColorTexture\":{\"index\":0},\"metallicFactor\":0.0},\"doubleSided\":false}]");
    j.append(",\"textures\":[{\"source\":0}]");
    j.append(",\"images\":[{\"mimeType\":\"image/png\",\"bufferView\":4}]");

    // Accessors.
    j.append(",\"accessors\":[");
    j.append("{\"bufferView\":0,\"componentType\":5126,\"count\":");
    append_uint(j, vcount);
    j.append(",\"type\":\"VEC3\",\"min\":[");
    append_float(j, pmin[0]); j.push_back(',');
    append_float(j, pmin[1]); j.push_back(',');
    append_float(j, pmin[2]);
    j.append("],\"max\":[");
    append_float(j, pmax[0]); j.push_back(',');
    append_float(j, pmax[1]); j.push_back(',');
    append_float(j, pmax[2]);
    j.append("]}");
    j.append(",{\"bufferView\":1,\"componentType\":5126,\"count\":");
    append_uint(j, vcount);
    j.append(",\"type\":\"VEC3\"}");
    j.append(",{\"bufferView\":2,\"componentType\":5126,\"count\":");
    append_uint(j, vcount);
    j.append(",\"type\":\"VEC2\"}");
    j.append(",{\"bufferView\":3,\"componentType\":5125,\"count\":");
    append_uint(j, in.indices.size());
    j.append(",\"type\":\"SCALAR\"}");
    j.append("]");

    // BufferViews. byteOffset omitted when 0 — strict validators
    // accept either form, but compact output is conventional.
    j.append(",\"bufferViews\":[");
    j.append("{\"buffer\":0,\"byteOffset\":0,\"byteLength\":");
    append_uint(j, pos_bytes); j.append(",\"target\":34962}");        // ARRAY_BUFFER
    j.append(",{\"buffer\":0,\"byteOffset\":");
    append_uint(j, nrm_off); j.append(",\"byteLength\":");
    append_uint(j, nrm_bytes); j.append(",\"target\":34962}");
    j.append(",{\"buffer\":0,\"byteOffset\":");
    append_uint(j, uv_off);  j.append(",\"byteLength\":");
    append_uint(j, uv_bytes); j.append(",\"target\":34962}");
    j.append(",{\"buffer\":0,\"byteOffset\":");
    append_uint(j, idx_off); j.append(",\"byteLength\":");
    append_uint(j, idx_bytes); j.append(",\"target\":34963}");        // ELEMENT_ARRAY_BUFFER
    j.append(",{\"buffer\":0,\"byteOffset\":");
    append_uint(j, png_off); j.append(",\"byteLength\":");
    append_uint(j, png_bytes_len); j.append("}");                     // image: no `target`
    j.append("]");

    j.append(",\"buffers\":[{\"byteLength\":");
    append_uint(j, bin_payload);
    j.append("}]}");

    // Pad JSON chunk content to 4-byte boundary with 0x20 (space).
    const uint64_t json_unpadded = j.size();
    const uint64_t json_padded   = align4(json_unpadded);
    j.append(static_cast<size_t>(json_padded - json_unpadded), ' ');

    // Compose GLB:
    //   header (12 B) + JSON chunk header (8) + json + BIN chunk header (8) + BIN
    constexpr uint32_t kGlbMagic     = 0x46546C67u;  // 'glTF'
    constexpr uint32_t kGlbVersion   = 2u;
    constexpr uint32_t kChunkTypeJson = 0x4E4F534Au; // 'JSON'
    constexpr uint32_t kChunkTypeBin  = 0x004E4942u; // 'BIN\0'

    const uint64_t total =
        12u + 8u + json_padded + 8u + bin_total;

    if (total > std::numeric_limits<uint32_t>::max()) {
        glb_io_log(err, "output GLB > 4 GiB; not representable in GLB header");
        return false;
    }

    out_bytes.resize(static_cast<size_t>(total));
    uint8_t* p = out_bytes.data();
    auto put_u32 = [&p](uint32_t v) {
        // Little-endian write — GLB spec is LE, all our targets
        // (iOS/Android/HarmonyOS/Web) are LE.
        p[0] = static_cast<uint8_t>(v        & 0xFF);
        p[1] = static_cast<uint8_t>((v >>  8) & 0xFF);
        p[2] = static_cast<uint8_t>((v >> 16) & 0xFF);
        p[3] = static_cast<uint8_t>((v >> 24) & 0xFF);
        p += 4;
    };

    // GLB header.
    put_u32(kGlbMagic);
    put_u32(kGlbVersion);
    put_u32(static_cast<uint32_t>(total));

    // JSON chunk.
    put_u32(static_cast<uint32_t>(json_padded));
    put_u32(kChunkTypeJson);
    std::memcpy(p, j.data(), json_padded);
    p += json_padded;

    // BIN chunk.
    put_u32(static_cast<uint32_t>(bin_total));
    put_u32(kChunkTypeBin);
    uint8_t* bin0 = p;
    // Zero the BIN region first so any inter-bufferView padding
    // bytes (idx → png boundary, post-png trailing pad) stay 0.
    std::memset(bin0, 0, static_cast<size_t>(bin_total));
    std::memcpy(bin0 + pos_off, in.positions.data(), pos_bytes);
    std::memcpy(bin0 + nrm_off, in.normals.data(),   nrm_bytes);
    std::memcpy(bin0 + uv_off,  global_uvs.data(),   uv_bytes);
    std::memcpy(bin0 + idx_off, in.indices.data(),   idx_bytes);
    std::memcpy(bin0 + png_off, png_bytes.data(),    png_bytes_len);

    return true;
}

}  // namespace aether::glb_norm
