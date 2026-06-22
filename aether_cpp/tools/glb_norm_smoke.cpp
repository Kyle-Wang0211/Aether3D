// SPDX-License-Identifier: LicenseRef-Aether3D-Proprietary
// Copyright (c) 2024-2026 Aether3D. All rights reserved.
//
// glb_norm_smoke — Phase 2 round-trip smoke for aether_glb_norm.
//
// Reads a multi-prim GLB, runs it through aether_glb_norm_run, writes
// the single-prim output to disk, and prints the input/output stats.
// The acceptance baseline is ~/Desktop/baseline_apr25.glb (a Polycam-
// like 64-prim photogrammetry scan, 402 K faces, 41.9 MB) — Phase 2
// must accept it, return AETHER_GLB_NORM_OK, and emit a GLB that
// passes the Khronos validator + renders textured + lit (NOT black)
// in three.js gltf-viewer.
//
// Usage:
//   glb_norm_smoke [<input.glb> [<output.glb>]]
//
// Defaults:
//   input  = $HOME/Desktop/baseline_apr25.glb
//   output = <input>.normalized.glb (next to input)

#include "aether_glb_norm_c.h"

#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <string>
#include <vector>

namespace {

bool read_file(const std::string& path, std::vector<uint8_t>& out) {
    std::FILE* f = std::fopen(path.c_str(), "rb");
    if (!f) {
        std::fprintf(stderr, "smoke: cannot open input '%s' (errno=%d)\n",
                     path.c_str(), errno);
        return false;
    }
    if (std::fseek(f, 0, SEEK_END) != 0) {
        std::fclose(f);
        return false;
    }
    const long n = std::ftell(f);
    if (n < 0) {
        std::fclose(f);
        return false;
    }
    if (std::fseek(f, 0, SEEK_SET) != 0) {
        std::fclose(f);
        return false;
    }
    out.resize(static_cast<size_t>(n));
    const size_t got = std::fread(out.data(), 1, out.size(), f);
    std::fclose(f);
    if (got != out.size()) {
        std::fprintf(stderr, "smoke: short read %zu/%zu\n", got, out.size());
        return false;
    }
    return true;
}

bool write_file(const std::string& path, const uint8_t* data, size_t size) {
    std::FILE* f = std::fopen(path.c_str(), "wb");
    if (!f) {
        std::fprintf(stderr, "smoke: cannot open output '%s' (errno=%d)\n",
                     path.c_str(), errno);
        return false;
    }
    const size_t put = std::fwrite(data, 1, size, f);
    std::fclose(f);
    if (put != size) {
        std::fprintf(stderr, "smoke: short write %zu/%zu\n", put, size);
        return false;
    }
    return true;
}

int progress_print(float fraction, const char* phase, void* /*ud*/) {
    std::fprintf(stderr, "  [%5.1f%%] %s\n", fraction * 100.0, phase);
    std::fflush(stderr);
    return 0;
}

std::string default_input_path() {
    const char* home = std::getenv("HOME");
    return std::string(home ? home : "") + "/Desktop/baseline_apr25.glb";
}

std::string default_output_for(const std::string& input) {
    // Strip a trailing .glb if present, append .normalized.glb.
    const std::string suffix = ".glb";
    std::string base = input;
    if (base.size() >= suffix.size() &&
        base.compare(base.size() - suffix.size(), suffix.size(), suffix) == 0) {
        base.erase(base.size() - suffix.size());
    }
    return base + ".normalized.glb";
}

}  // namespace

int main(int argc, char** argv) {
    const std::string input_path =
        (argc >= 2) ? argv[1] : default_input_path();
    const std::string output_path =
        (argc >= 3) ? argv[2] : default_output_for(input_path);

    std::fprintf(stderr, "smoke: input  = %s\n", input_path.c_str());
    std::fprintf(stderr, "smoke: output = %s\n", output_path.c_str());

    std::vector<uint8_t> in_bytes;
    if (!read_file(input_path, in_bytes)) {
        return 2;
    }
    std::fprintf(stderr, "smoke: input size = %zu bytes (%.2f MB)\n",
                 in_bytes.size(),
                 static_cast<double>(in_bytes.size()) / (1024.0 * 1024.0));

    aether_glb_norm_options_t opts;
    aether_glb_norm_options_default(&opts);

    // Phase-3 override hook: AETHER_GLB_NORM_TARGET_FACES lets a test
    // script force the simplify path on a small input (or disable it
    // with =0). Untouched in production; defaults stay at 500_000.
    if (const char* tf = std::getenv("AETHER_GLB_NORM_TARGET_FACES")) {
        const long parsed = std::strtol(tf, nullptr, 10);
        if (parsed >= 0) {
            opts.target_face_count = static_cast<uint32_t>(parsed);
            std::fprintf(stderr, "smoke: target_face_count override = %u\n",
                         opts.target_face_count);
        }
    }

    aether_glb_norm_buffer_t out_buf{};
    aether_glb_norm_stats_t  stats{};
    const aether_glb_norm_result_t rc = aether_glb_norm_run(
        in_bytes.data(), in_bytes.size(),
        &opts,
        progress_print, /*user_data=*/nullptr,
        &out_buf, &stats);

    std::fprintf(stderr, "smoke: result = %s (%d)\n",
                 aether_glb_norm_result_str(rc), static_cast<int>(rc));
    std::fprintf(stderr, "smoke: stats input  prims=%u  mats=%u  faces=%u\n",
                 stats.input_primitive_count, stats.input_material_count,
                 stats.input_face_count);
    std::fprintf(stderr, "smoke: stats output prims=%u  mats=%u  faces=%u  atlas=%dpx  elapsed=%.3fs\n",
                 stats.output_primitive_count, stats.output_material_count,
                 stats.output_face_count, stats.output_atlas_size,
                 static_cast<double>(stats.elapsed_seconds));

    if (rc != AETHER_GLB_NORM_OK) {
        if (out_buf.data) aether_glb_norm_buffer_free(&out_buf);
        return 3;
    }

    // Sanity: GLB magic.
    if (out_buf.size < 12 ||
        std::memcmp(out_buf.data, "glTF", 4) != 0) {
        std::fprintf(stderr, "smoke: output not a GLB (missing magic)\n");
        aether_glb_norm_buffer_free(&out_buf);
        return 4;
    }

    if (!write_file(output_path, out_buf.data, out_buf.size)) {
        aether_glb_norm_buffer_free(&out_buf);
        return 5;
    }
    std::fprintf(stderr, "smoke: output size = %zu bytes (%.2f MB)\n",
                 out_buf.size,
                 static_cast<double>(out_buf.size) / (1024.0 * 1024.0));

    // Output-vs-input size delta check (acceptance criteria says ±20%
    // is the expected band — log it loud so the wrapper can pick it up).
    const double ratio = static_cast<double>(out_buf.size) /
                         static_cast<double>(in_bytes.size());
    std::fprintf(stderr, "smoke: output / input = %.3f\n", ratio);

    aether_glb_norm_buffer_free(&out_buf);

    if (stats.output_primitive_count != 1 || stats.output_material_count != 1) {
        std::fprintf(stderr, "smoke: FAIL — expected single-prim/single-mat output\n");
        return 6;
    }
    std::fprintf(stderr, "smoke: PASS\n");
    return 0;
}
