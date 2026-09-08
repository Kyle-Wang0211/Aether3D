// SPDX-License-Identifier: LicenseRef-Aether3D-Proprietary
// Copyright (c) 2024-2026 Aether3D. All rights reserved.
//
// glb_norm_bench — P0 mesh fast-load decimation + P1 texture-size benchmark.
//
// Two modes:
//
//  (1) FACE-BUDGET sweep (default / --budgets): runs aether_glb_norm_run
//      over a set of input GLBs at a sweep of target_face_count budgets
//      {500000, 250000, 150000, 100000} and prints a per-(input × budget)
//      table. Exercises the meshopt_simplifyWithAttributes path.
//
//  (2) ATLAS-SIZE sweep (--atlas N,M,P): the P1 texture-compression lever.
//      Fixes the face budget (default 150000, override with --face-budget)
//      and sweeps the output atlas side over {8192, 4096, 2048}. For each
//      input × atlas size it reports: atlas px, total GLB bytes, the
//      PNG-vs-mesh byte split (the headline P1 finding — texture dominates),
//      and normalize wall-time.
//
// Both modes report output / input size ratio so the knee is visible.
//
// To pin a SPECIFIC atlas size N we set BOTH target_atlas_size = N AND
// max_atlas_size = N. merge_atlases() honors target_atlas_size via
// next_pow2_ge() but then clamps to max_atlas_size and may grow `side`
// via the retry-on-overflow loop up to max_atlas_size — so pinning both
// is the only way to force an exact size. (For 2048 the single oversized
// chart is globally downscaled in atlas_merger Step 4 to fit, so packing
// still succeeds.)
//
// Usage:
//   glb_norm_bench <input1.glb> [<input2.glb> ...]
//   glb_norm_bench --budgets 500000,250000,150000,100000,50000 <in.glb> ...
//   glb_norm_bench --atlas 8192,4096,2048 <in.glb> ...
//   glb_norm_bench --atlas 8192,4096,2048 --face-budget 150000 <in.glb> ...
//   glb_norm_bench --dump-dir /tmp/bench_out <in.glb>   (writes each result GLB)
//
// If no inputs are given, it errors (no implicit default — bench is
// always explicit about what it measured).

#include "aether_glb_norm_c.h"

#include <chrono>
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
        std::fprintf(stderr, "bench: cannot open '%s' (errno=%d)\n",
                     path.c_str(), errno);
        return false;
    }
    std::fseek(f, 0, SEEK_END);
    const long n = std::ftell(f);
    std::fseek(f, 0, SEEK_SET);
    if (n < 0) { std::fclose(f); return false; }
    out.resize(static_cast<size_t>(n));
    const size_t got = std::fread(out.data(), 1, out.size(), f);
    std::fclose(f);
    return got == out.size();
}

bool write_file(const std::string& path, const uint8_t* data, size_t size) {
    std::FILE* f = std::fopen(path.c_str(), "wb");
    if (!f) return false;
    const size_t put = std::fwrite(data, 1, size, f);
    std::fclose(f);
    return put == size;
}

std::string basename_of(const std::string& p) {
    const auto slash = p.find_last_of('/');
    return slash == std::string::npos ? p : p.substr(slash + 1);
}

std::vector<uint32_t> parse_budgets(const std::string& csv) {
    std::vector<uint32_t> out;
    std::size_t i = 0;
    while (i < csv.size()) {
        std::size_t j = csv.find(',', i);
        if (j == std::string::npos) j = csv.size();
        const std::string tok = csv.substr(i, j - i);
        if (!tok.empty()) out.push_back(static_cast<uint32_t>(std::strtoul(tok.c_str(), nullptr, 10)));
        i = j + 1;
    }
    return out;
}

// Extract the embedded baseColor PNG byte length from a normalized GLB.
//
// write_glb() emits a fixed-shape glTF: image bufferView index 4 holds
// the PNG (mesh = bufferViews 0..3 = pos/nrm/uv/idx). We parse the JSON
// chunk and read the 5th bufferView's "byteLength". Returns 0 on any
// parse miss (caller treats 0 as "unknown" and skips the split line).
//
// This avoids re-linking cgltf into the bench — the JSON is compact and
// deterministic, so a tolerant string scan is sufficient and robust.
uint64_t extract_png_bytes(const uint8_t* glb, size_t glb_size) {
    // GLB header: magic(4) version(4) length(4); then JSON chunk:
    // chunkLength(4) chunkType(4)='JSON' then JSON text.
    if (glb_size < 20) return 0;
    const uint32_t json_len =
        glb[12] | (glb[13] << 8) | (glb[14] << 16) |
        (static_cast<uint32_t>(glb[15]) << 24);
    if (20u + json_len > glb_size) return 0;
    const std::string json(reinterpret_cast<const char*>(glb + 20),
                           static_cast<size_t>(json_len));

    // Find "bufferViews":[ ... ] and walk to the 5th element's byteLength.
    const std::string key = "\"bufferViews\":[";
    size_t bv = json.find(key);
    if (bv == std::string::npos) return 0;
    size_t pos = bv + key.size();

    // Count "byteLength" occurrences; the 5th (index 4) is the PNG.
    const std::string bl = "\"byteLength\":";
    uint64_t last = 0;
    for (int i = 0; i < 5; ++i) {
        size_t k = json.find(bl, pos);
        if (k == std::string::npos) return 0;
        k += bl.size();
        last = std::strtoull(json.c_str() + k, nullptr, 10);
        pos = k;
    }
    return last;  // bufferView 4 byteLength = PNG bytes
}

}  // namespace

int main(int argc, char** argv) {
    std::vector<uint32_t> budgets = {500000, 250000, 150000, 100000};
    std::vector<uint32_t> atlas_sizes;            // non-empty => atlas mode
    uint32_t face_budget = 150000;                // fixed budget in atlas mode
    std::vector<std::string> inputs;
    std::string dump_dir;

    for (int a = 1; a < argc; ++a) {
        const std::string arg = argv[a];
        if (arg == "--budgets" && a + 1 < argc) {
            budgets = parse_budgets(argv[++a]);
        } else if (arg == "--atlas" && a + 1 < argc) {
            atlas_sizes = parse_budgets(argv[++a]);
        } else if (arg == "--face-budget" && a + 1 < argc) {
            face_budget = static_cast<uint32_t>(
                std::strtoul(argv[++a], nullptr, 10));
        } else if (arg == "--dump-dir" && a + 1 < argc) {
            dump_dir = argv[++a];
        } else {
            inputs.push_back(arg);
        }
    }

    if (inputs.empty()) {
        std::fprintf(stderr,
            "usage: glb_norm_bench [--budgets a,b,c] [--dump-dir DIR] "
            "<in1.glb> [in2.glb ...]\n"
            "       glb_norm_bench --atlas 8192,4096,2048 "
            "[--face-budget 150000] <in1.glb> ...\n");
        return 2;
    }

    // ─── ATLAS-SIZE SWEEP (P1 texture-compression lever) ────────────────
    if (!atlas_sizes.empty()) {
        std::printf("# aether_glb_norm ATLAS-SIZE sweep "
                    "(face budget fixed at %u)\n", face_budget);
        std::printf("%-22s %8s %8s %14s %12s %12s %10s %8s\n",
                    "input", "atlas_px", "faces", "glb_bytes",
                    "png_bytes", "mesh_bytes", "wall_s", "glb/in");
        std::printf("%s\n", std::string(100, '-').c_str());

        for (const std::string& path : inputs) {
            std::vector<uint8_t> in_bytes;
            if (!read_file(path, in_bytes)) {
                std::fprintf(stderr, "bench: skipping unreadable '%s'\n",
                             path.c_str());
                continue;
            }
            const std::string name = basename_of(path);
            const double in_mb =
                static_cast<double>(in_bytes.size()) / (1024.0 * 1024.0);

            for (uint32_t side : atlas_sizes) {
                aether_glb_norm_options_t opts;
                aether_glb_norm_options_default(&opts);
                opts.target_face_count = face_budget;
                // Pin the exact size: both target AND max must be `side`,
                // else the merger's retry loop can grow up to max.
                opts.target_atlas_size = static_cast<int>(side);
                opts.max_atlas_size    = static_cast<int>(side);

                aether_glb_norm_buffer_t out_buf{};
                aether_glb_norm_stats_t  stats{};

                const auto t0 = std::chrono::steady_clock::now();
                const aether_glb_norm_result_t rc = aether_glb_norm_run(
                    in_bytes.data(), in_bytes.size(), &opts,
                    nullptr, nullptr, &out_buf, &stats);
                const auto t1 = std::chrono::steady_clock::now();
                const double wall =
                    std::chrono::duration_cast<std::chrono::microseconds>(
                        t1 - t0).count() / 1.0e6;

                if (rc != AETHER_GLB_NORM_OK) {
                    std::printf("%-22s %8u   ERROR=%s\n", name.c_str(), side,
                                aether_glb_norm_result_str(rc));
                    if (out_buf.data) aether_glb_norm_buffer_free(&out_buf);
                    continue;
                }

                const uint64_t png = extract_png_bytes(out_buf.data,
                                                        out_buf.size);
                const uint64_t mesh =
                    png > 0 && png <= out_buf.size
                        ? static_cast<uint64_t>(out_buf.size) - png
                        : 0;
                const double glb_ratio =
                    static_cast<double>(out_buf.size) /
                    static_cast<double>(in_bytes.size());

                std::printf("%-22s %8d %8u %14zu %12llu %12llu %10.3f %8.3f\n",
                            name.c_str(),
                            stats.output_atlas_size,
                            stats.output_face_count,
                            out_buf.size,
                            static_cast<unsigned long long>(png),
                            static_cast<unsigned long long>(mesh),
                            wall, glb_ratio);

                if (!dump_dir.empty()) {
                    char ob[64];
                    std::snprintf(ob, sizeof(ob), "_atlas%u.glb", side);
                    const std::string outp = dump_dir + "/" + name + ob;
                    if (write_file(outp, out_buf.data, out_buf.size))
                        std::fprintf(stderr, "bench: wrote %s\n", outp.c_str());
                }

                aether_glb_norm_buffer_free(&out_buf);
            }
            std::printf("# %s = %.2f MB input\n", name.c_str(), in_mb);
        }
        std::fflush(stdout);
        return 0;
    }

    std::printf("# aether_glb_norm decimation benchmark "
                "(meshopt_simplifyWithAttributes, UV+normal weighted)\n");
    std::printf("%-22s %12s %10s %12s %12s %10s %8s %7s\n",
                "input", "in_faces", "budget", "out_faces",
                "out_bytes", "wall_s", "atlas_px", "out/in");
    std::printf("%s\n", std::string(98, '-').c_str());

    for (const std::string& path : inputs) {
        std::vector<uint8_t> in_bytes;
        if (!read_file(path, in_bytes)) {
            std::fprintf(stderr, "bench: skipping unreadable '%s'\n",
                         path.c_str());
            continue;
        }
        const std::string name = basename_of(path);
        const double in_mb =
            static_cast<double>(in_bytes.size()) / (1024.0 * 1024.0);

        for (uint32_t budget : budgets) {
            aether_glb_norm_options_t opts;
            aether_glb_norm_options_default(&opts);
            opts.target_face_count = budget;

            aether_glb_norm_buffer_t out_buf{};
            aether_glb_norm_stats_t  stats{};

            const auto t0 = std::chrono::steady_clock::now();
            const aether_glb_norm_result_t rc = aether_glb_norm_run(
                in_bytes.data(), in_bytes.size(),
                &opts,
                /*progress_cb=*/nullptr, /*user_data=*/nullptr,
                &out_buf, &stats);
            const auto t1 = std::chrono::steady_clock::now();
            const double wall =
                std::chrono::duration_cast<std::chrono::microseconds>(t1 - t0)
                    .count() / 1.0e6;

            if (rc != AETHER_GLB_NORM_OK) {
                std::printf("%-22s %12u %10u   ERROR=%s\n",
                            name.c_str(), stats.input_face_count, budget,
                            aether_glb_norm_result_str(rc));
                if (out_buf.data) aether_glb_norm_buffer_free(&out_buf);
                continue;
            }

            const double ratio =
                static_cast<double>(out_buf.size) /
                static_cast<double>(in_bytes.size());

            std::printf("%-22s %12u %10u %12u %12zu %10.3f %8d %7.3f\n",
                        name.c_str(),
                        stats.input_face_count,
                        budget,
                        stats.output_face_count,
                        out_buf.size,
                        wall,
                        stats.output_atlas_size,
                        ratio);

            if (!dump_dir.empty()) {
                char ob[64];
                std::snprintf(ob, sizeof(ob), "_%uK.glb", budget / 1000);
                const std::string outp =
                    dump_dir + "/" + name + ob;
                if (!write_file(outp, out_buf.data, out_buf.size)) {
                    std::fprintf(stderr, "bench: failed to write %s\n",
                                 outp.c_str());
                } else {
                    std::fprintf(stderr, "bench: wrote %s\n", outp.c_str());
                }
            }

            aether_glb_norm_buffer_free(&out_buf);
        }
        std::printf("# %s = %.2f MB input\n", name.c_str(), in_mb);
    }

    std::fflush(stdout);
    return 0;
}
