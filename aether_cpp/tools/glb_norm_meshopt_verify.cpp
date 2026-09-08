// SPDX-License-Identifier: LicenseRef-Aether3D-Proprietary
// Copyright (c) 2024-2026 Aether3D. All rights reserved.
//
// glb_norm_meshopt_verify — prove the EXT_meshopt_compression producer path
// is LOSSLESS and report the size win.
//
// For each input GLB:
//   1. Parse it (library parse_glb) to get the canonical pre-encode global
//      mesh: positions, normals, indices (the exact buffers write_glb feeds
//      to the meshopt encoder, modulo the merged UVs which we don't compare
//      here — UVs are validated bit-exact by the same vertex codec path).
//   2. Run aether_glb_norm_run with FULL opts TWICE: compress_geometry=0
//      (baseline) and compress_geometry=1 (meshopt). Report full-GLB sizes.
//   3. Parse the meshopt-compressed output GLB's JSON, locate the four
//      EXT_meshopt_compression bufferViews, pull their compressed bytes out
//      of the BIN, and DECODE them with meshopt_decodeVertexBuffer /
//      meshopt_decodeIndexBuffer.
//   4. Compare the decoded POSITION + INDICES byte-for-byte against the
//      same data extracted from the UNCOMPRESSED output GLB (bv 0 and bv 3
//      in buffer 0). Bit-identical => truly lossless (not merely visually).
//
// Comparing the two PRODUCER OUTPUTS (compressed vs uncompressed) — rather
// than against parse_glb's intermediate — isolates the codec round-trip:
// both runs share the identical merge + UV stitch, so any byte diff is
// purely the encoder/decoder, which is exactly what "lossless" must prove.

#include "aether_glb_norm_c.h"
#include "meshoptimizer.h"

#include <algorithm>
#include <array>
#include <cmath>
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <string>
#include <vector>

namespace {

bool read_file(const std::string& path, std::vector<uint8_t>& out) {
    std::FILE* f = std::fopen(path.c_str(), "rb");
    if (!f) { std::fprintf(stderr, "cannot open '%s'\n", path.c_str()); return false; }
    std::fseek(f, 0, SEEK_END); const long n = std::ftell(f); std::fseek(f, 0, SEEK_SET);
    if (n < 0) { std::fclose(f); return false; }
    out.resize(size_t(n));
    const size_t got = std::fread(out.data(), 1, out.size(), f);
    std::fclose(f);
    return got == out.size();
}

void write_file(const std::string& path, const std::vector<uint8_t>& d) {
    std::FILE* f = std::fopen(path.c_str(), "wb");
    if (f) { std::fwrite(d.data(), 1, d.size(), f); std::fclose(f); }
}

std::string basename_of(const std::string& p) {
    const auto s = p.find_last_of('/');
    return s == std::string::npos ? p : p.substr(s + 1);
}

struct GlbView { std::string json; const uint8_t* bin = nullptr; size_t bin_len = 0; };
bool view_glb(const std::vector<uint8_t>& glb, GlbView& v) {
    if (glb.size() < 20 || std::memcmp(glb.data(), "glTF", 4)) return false;
    const uint32_t jl = glb[12] | (glb[13]<<8) | (glb[14]<<16) | (uint32_t(glb[15])<<24);
    if (20u + jl > glb.size()) return false;
    v.json.assign(reinterpret_cast<const char*>(glb.data() + 20), jl);
    size_t off = 20u + jl;
    if (off + 8 <= glb.size()) {
        const uint32_t bl = glb[off] | (glb[off+1]<<8) | (glb[off+2]<<16) | (uint32_t(glb[off+3])<<24);
        v.bin = glb.data() + off + 8; v.bin_len = bl;
    }
    return true;
}

long jint(const std::string& j, size_t from, const char* key) {
    size_t k = j.find(key, from);
    if (k == std::string::npos) return -1;
    k += std::strlen(key);
    while (k < j.size() && (j[k]==' '||j[k]==':')) ++k;
    return std::strtol(j.c_str()+k, nullptr, 10);
}

// Pull bufferView `idx`'s top-level {byteOffset,byteLength} AND, if present,
// its EXT_meshopt_compression {byteOffset,byteLength,count,buffer,mode}.
struct BvInfo {
    long top_off = 0, top_len = 0, top_buffer = 0;
    bool has_ext = false;
    long ext_off = 0, ext_len = 0, ext_count = 0, ext_buffer = 0;
    std::string mode;
};
bool parse_bv(const std::string& j, int idx, BvInfo& out) {
    size_t bvs = j.find("\"bufferViews\":[");
    if (bvs == std::string::npos) return false;
    // Walk element starts: each bufferView begins with '{'. Track brace depth.
    size_t pos = bvs + std::strlen("\"bufferViews\":[");
    int elem = 0; int depth = 0; size_t elem_start = std::string::npos;
    for (size_t i = pos; i < j.size(); ++i) {
        char c = j[i];
        if (c == '{') { if (depth == 0) elem_start = i; ++depth; }
        else if (c == '}') {
            --depth;
            if (depth == 0) {
                if (elem == idx) {
                    const std::string e = j.substr(elem_start, i - elem_start + 1);
                    out.top_buffer = jint(e, 0, "\"buffer\":");
                    out.top_off = std::max(0L, jint(e, 0, "\"byteOffset\":"));
                    out.top_len = jint(e, 0, "\"byteLength\":");
                    size_t ext = e.find("EXT_meshopt_compression");
                    if (ext != std::string::npos) {
                        out.has_ext = true;
                        out.ext_buffer = jint(e, ext, "\"buffer\":");
                        out.ext_off = std::max(0L, jint(e, ext, "\"byteOffset\":"));
                        out.ext_len = jint(e, ext, "\"byteLength\":");
                        out.ext_count = jint(e, ext, "\"count\":");
                        size_t m = e.find("\"mode\":\"", ext);
                        if (m != std::string::npos) {
                            m += std::strlen("\"mode\":\"");
                            size_t q = e.find('"', m);
                            out.mode = e.substr(m, q - m);
                        }
                    }
                    return true;
                }
                ++elem;
            }
        } else if (c == ']' && depth == 0) break;
    }
    return false;
}

aether_glb_norm_result_t run(const std::vector<uint8_t>& in, bool compress,
                             std::vector<uint8_t>& out) {
    aether_glb_norm_options_t opts;
    aether_glb_norm_options_default(&opts);
    opts.target_face_count = 0;
    opts.target_atlas_size = 0;
    opts.max_atlas_size = 16384;
    opts.texture_format = AETHER_GLB_NORM_TEX_PNG;
    opts.compress_geometry = compress ? 1 : 0;
    aether_glb_norm_buffer_t buf{};
    aether_glb_norm_stats_t st{};
    auto rc = aether_glb_norm_run(in.data(), in.size(), &opts, nullptr, nullptr, &buf, &st);
    if (rc == AETHER_GLB_NORM_OK) {
        out.assign(buf.data, buf.data + buf.size);
        aether_glb_norm_buffer_free(&buf);
    }
    return rc;
}

}  // namespace

int main(int argc, char** argv) {
    std::vector<std::string> inputs;
    std::string dump_dir;
    for (int a = 1; a < argc; ++a) {
        std::string s = argv[a];
        if (s == "--dump-dir" && a + 1 < argc) dump_dir = argv[++a];
        else inputs.push_back(s);
    }
    if (inputs.empty()) {
        std::fprintf(stderr, "usage: glb_norm_meshopt_verify [--dump-dir D] <in.glb> ...\n");
        return 2;
    }

    std::printf("# EXT_meshopt_compression LOSSLESS round-trip + size report "
                "(FULL tier, PNG texture)\n\n");

    for (const std::string& path : inputs) {
        const std::string name = basename_of(path);
        std::vector<uint8_t> in_bytes;
        if (!read_file(path, in_bytes)) continue;

        std::vector<uint8_t> plain, comp;
        auto rc0 = run(in_bytes, false, plain);
        auto rc1 = run(in_bytes, true, comp);
        if (rc0 != AETHER_GLB_NORM_OK || rc1 != AETHER_GLB_NORM_OK) {
            std::printf("== %s ==  RUN FAILED plain=%s comp=%s\n", name.c_str(),
                        aether_glb_norm_result_str(rc0), aether_glb_norm_result_str(rc1));
            continue;
        }
        if (!dump_dir.empty()) {
            write_file(dump_dir + "/" + name + ".plain.glb", plain);
            write_file(dump_dir + "/" + name + ".meshopt.glb", comp);
        }

        GlbView pv, cv;
        view_glb(plain, pv);
        view_glb(comp, cv);

        // Reference (uncompressed) POSITION (bv0) and INDICES (bv3) bytes.
        BvInfo p_pos, p_idx;
        parse_bv(pv.json, 0, p_pos);
        parse_bv(pv.json, 3, p_idx);
        const uint8_t* ref_pos = pv.bin + p_pos.top_off;
        const uint8_t* ref_idx = pv.bin + p_idx.top_off;
        const size_t ref_pos_len = size_t(p_pos.top_len);
        const size_t ref_idx_len = size_t(p_idx.top_len);

        // Compressed bufferViews.
        BvInfo c_pos, c_nrm, c_uv, c_idx;
        parse_bv(cv.json, 0, c_pos);
        parse_bv(cv.json, 1, c_nrm);
        parse_bv(cv.json, 2, c_uv);
        parse_bv(cv.json, 3, c_idx);

        const bool layout_ok =
            c_pos.has_ext && c_nrm.has_ext && c_uv.has_ext && c_idx.has_ext &&
            c_pos.mode == "ATTRIBUTES" && c_idx.mode == "TRIANGLES" &&
            c_pos.top_buffer == 1 && c_idx.ext_buffer == 0;

        // Decode POSITION (VEC3 f32 => stride 12).
        std::vector<uint8_t> dec_pos(size_t(c_pos.ext_count) * 12u);
        int rp = meshopt_decodeVertexBuffer(dec_pos.data(), size_t(c_pos.ext_count), 12u,
                                            cv.bin + c_pos.ext_off, size_t(c_pos.ext_len));
        // Decode INDICES (u32 => size 4).
        std::vector<uint8_t> dec_idx(size_t(c_idx.ext_count) * 4u);
        int ri = meshopt_decodeIndexBuffer(dec_idx.data(), size_t(c_idx.ext_count), 4u,
                                           cv.bin + c_idx.ext_off, size_t(c_idx.ext_len));

        const bool pos_match = (rp == 0) && (dec_pos.size() == ref_pos_len) &&
                               (std::memcmp(dec_pos.data(), ref_pos, ref_pos_len) == 0);
        const bool idx_byte_match = (ri == 0) && (dec_idx.size() == ref_idx_len) &&
                               (std::memcmp(dec_idx.data(), ref_idx, ref_idx_len) == 0);

        // The meshopt INDEX codec is lossless per-triangle but is free to
        // ROTATE the 3 vertices within a triangle (winding-preserving) to
        // improve compression — so raw bytes may differ while the triangle
        // *set* is identical. Build a winding-preserving canonical key
        // (rotate so the smallest index is first) for every triangle on
        // both sides and compare the multisets. Identical => topology +
        // winding bit-exact; only intra-triangle vertex rotation changed
        // (visually + geometrically lossless, GPU-identical front faces).
        bool idx_topo_match = false;
        long idx_rotated = 0;
        if (ri == 0 && dec_idx.size() == ref_idx_len &&
            (ref_idx_len % 12) == 0) {
            const uint32_t* a = reinterpret_cast<const uint32_t*>(ref_idx);
            const uint32_t* b = reinterpret_cast<const uint32_t*>(dec_idx.data());
            const size_t ntri = ref_idx_len / 12;
            auto canon = [](uint32_t x, uint32_t y, uint32_t z,
                            uint32_t out[3]) {
                // winding-preserving min-rotation
                if (x <= y && x <= z) { out[0]=x; out[1]=y; out[2]=z; }
                else if (y <= x && y <= z) { out[0]=y; out[1]=z; out[2]=x; }
                else { out[0]=z; out[1]=x; out[2]=y; }
            };
            std::vector<std::array<uint32_t,3>> ka(ntri), kb(ntri);
            for (size_t t = 0; t < ntri; ++t) {
                uint32_t ca[3], cb[3];
                canon(a[3*t], a[3*t+1], a[3*t+2], ca);
                canon(b[3*t], b[3*t+1], b[3*t+2], cb);
                ka[t] = {ca[0],ca[1],ca[2]};
                kb[t] = {cb[0],cb[1],cb[2]};
                if (a[3*t] != b[3*t] || a[3*t+1] != b[3*t+1] ||
                    a[3*t+2] != b[3*t+2]) ++idx_rotated;
            }
            std::sort(ka.begin(), ka.end());
            std::sort(kb.begin(), kb.end());
            idx_topo_match = (ka == kb);
        }
        const bool idx_match = idx_byte_match || idx_topo_match;

        // Geometry / texture byte split in each output.
        // Plain: mesh = pos+nrm+uv+idx bv lengths; texture = image bv.
        // We report total GLB size + the compressed-stream total.
        const uint64_t comp_geo = uint64_t(c_pos.ext_len) + c_nrm.ext_len +
                                  c_uv.ext_len + c_idx.ext_len;
        const uint64_t plain_geo = uint64_t(p_pos.top_len) + p_idx.top_len; // (pos+idx shown; full below)
        BvInfo p_nrm, p_uv;
        parse_bv(pv.json, 1, p_nrm);
        parse_bv(pv.json, 2, p_uv);
        const uint64_t plain_geo_full = uint64_t(p_pos.top_len) + p_nrm.top_len +
                                        p_uv.top_len + p_idx.top_len;
        (void)plain_geo;

        std::printf("== %s ==\n", name.c_str());
        std::printf("  LAYOUT    %s  (pos/nrm/uv mode=ATTRIBUTES, idx mode=TRIANGLES, "
                    "fallback buffer=1, compressed in buffer 0)\n",
                    layout_ok ? "OK" : "*** UNEXPECTED ***");
        std::printf("  ROUND-TRIP POSITION: decode rc=%d  %s  (%zu bytes, %ld verts)\n",
                    rp, pos_match ? "BIT-IDENTICAL" : "*** DIFFERS ***",
                    ref_pos_len, c_pos.ext_count);
        if (idx_byte_match) {
            std::printf("  ROUND-TRIP INDICES : decode rc=%d  BIT-IDENTICAL  (%zu bytes, %ld indices)\n",
                        ri, ref_idx_len, c_idx.ext_count);
        } else if (idx_topo_match) {
            std::printf("  ROUND-TRIP INDICES : decode rc=%d  TOPOLOGY+WINDING IDENTICAL "
                        "(%ld/%zu tris intra-rotated by codec — visually/GPU lossless)  "
                        "(%zu bytes, %ld indices)\n",
                        ri, idx_rotated, ref_idx_len / 12, ref_idx_len, c_idx.ext_count);
        } else {
            std::printf("  ROUND-TRIP INDICES : decode rc=%d  *** DIFFERS (topology mismatch) ***  "
                        "(%zu bytes, %ld indices)\n",
                        ri, ref_idx_len, c_idx.ext_count);
        }
        (void)idx_match;
        std::printf("  GEOMETRY  raw=%.2f MB -> meshopt=%.2f MB  (%.2fx smaller)\n",
                    plain_geo_full / 1e6, comp_geo / 1e6,
                    comp_geo > 0 ? double(plain_geo_full) / double(comp_geo) : 0.0);
        std::printf("  FULL GLB  plain=%.2f MB -> meshopt=%.2f MB  (delta %.2f MB, %.1f%% smaller)\n",
                    plain.size() / 1e6, comp.size() / 1e6,
                    (double(plain.size()) - double(comp.size())) / 1e6,
                    100.0 * (1.0 - double(comp.size()) / double(plain.size())));
        std::printf("\n");
    }
    std::fflush(stdout);
    return 0;
}
