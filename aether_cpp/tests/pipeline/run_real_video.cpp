// SPDX-License-Identifier: LicenseRef-Aether3D-Proprietary
// Real video → 3DGS pipeline driver.
// Reads raw BGRA frames + poses from JSON, runs PipelineCoordinator, exports PLY.

#include "aether/pipeline/pipeline_coordinator.h"
#include "aether/render/gpu_device.h"
#include "aether/splat/splat_render_engine.h"
#include "aether/splat/ply_loader.h"
#include "create_test_gpu_device.h"

#include <algorithm>
#include <chrono>
#include <cstdio>
#include <cstring>
#include <fstream>
#include <string>
#include <thread>
#include <vector>

// ── Minimal JSON parser ────────────────────────────────────────────────────

struct FrameEntry {
    std::string path;
    float cam2world[16];  // column-major 4×4
};

struct VideoData {
    int num_frames{0};
    int width{0}, height{0};
    float fx{0}, fy{0}, cx{0}, cy{0};
    std::string output_ply;
    std::vector<FrameEntry> frames;
};

static std::string json_read_string(const std::string& s, std::size_t& pos) {
    while (pos < s.size() && s[pos] != '"') ++pos;
    ++pos;
    std::string out;
    while (pos < s.size() && s[pos] != '"') {
        if (s[pos] == '\\') ++pos;
        out += s[pos++];
    }
    ++pos;
    return out;
}

static double json_read_number(const std::string& s, std::size_t& pos) {
    while (pos < s.size() && s[pos] != '-' && (s[pos] < '0' || s[pos] > '9')) ++pos;
    char* end{};
    double v = std::strtod(s.c_str() + pos, &end);
    pos = static_cast<std::size_t>(end - s.c_str());
    return v;
}

static VideoData parse_json(const std::string& path) {
    std::ifstream f(path);
    std::string s((std::istreambuf_iterator<char>(f)), {});
    std::size_t pos = 0;

    VideoData vd;

    auto find_key = [&](const std::string& key) -> bool {
        auto p = s.find("\"" + key + "\"", pos);
        if (p == std::string::npos) return false;
        pos = p + key.size() + 2;
        return true;
    };

    if (find_key("num_frames")) vd.num_frames = (int)json_read_number(s, pos);
    if (find_key("width"))      vd.width  = (int)json_read_number(s, pos);
    if (find_key("height"))     vd.height = (int)json_read_number(s, pos);
    if (find_key("fx"))         vd.fx  = (float)json_read_number(s, pos);
    if (find_key("fy"))         vd.fy  = (float)json_read_number(s, pos);
    if (find_key("cx"))         vd.cx  = (float)json_read_number(s, pos);
    if (find_key("cy"))         vd.cy  = (float)json_read_number(s, pos);
    if (find_key("output_ply")) vd.output_ply = json_read_string(s, pos);

    auto frames_pos = s.find("\"frames\"", pos);
    if (frames_pos == std::string::npos) return vd;
    pos = frames_pos;

    for (int i = 0; i < vd.num_frames; ++i) {
        auto path_pos = s.find("\"path\"", pos);
        auto mat_pos  = s.find("\"cam2world\"", pos);
        if (path_pos == std::string::npos) break;

        FrameEntry fe;
        pos = path_pos;
        find_key("path");
        fe.path = json_read_string(s, pos);

        pos = mat_pos;
        find_key("cam2world");
        double mat_row[16];
        for (int k = 0; k < 16; ++k)
            mat_row[k] = json_read_number(s, pos);
        // row-major JSON → column-major for pipeline
        for (int r = 0; r < 4; ++r)
            for (int c = 0; c < 4; ++c)
                fe.cam2world[c * 4 + r] = (float)mat_row[r * 4 + c];

        vd.frames.push_back(std::move(fe));
    }

    std::fprintf(stderr, "  Parsed: %d frames, %dx%d, fx=%.0f\n",
                 (int)vd.frames.size(), vd.width, vd.height, (double)vd.fx);
    return vd;
}

// ── Raw BGRA binary loader ─────────────────────────────────────────────────

static bool load_bgra(const std::string& raw_path,
                      std::vector<unsigned char>& bgra,
                      int w, int h) {
    std::ifstream f(raw_path, std::ios::binary);
    if (!f) {
        std::fprintf(stderr, "  Cannot open: %s\n", raw_path.c_str());
        return false;
    }
    std::size_t expected = (std::size_t)w * h * 4;
    bgra.resize(expected);
    f.read(reinterpret_cast<char*>(bgra.data()), (std::streamsize)expected);
    return (std::size_t)f.gcount() == expected;
}

// ── Fake depth: luminance-based variation around a base distance ───────────

static void make_fake_depth(int w, int h,
                            const unsigned char* bgra,
                            float base_depth,
                            std::vector<float>& depth) {
    depth.resize((std::size_t)w * h);
    for (int i = 0; i < w * h; ++i) {
        float lum = (0.299f * bgra[i*4+2] +
                     0.587f * bgra[i*4+1] +
                     0.114f * bgra[i*4+0]) / 255.0f;
        depth[i] = std::max(0.05f, base_depth + (0.5f - lum) * 0.12f);
    }
}

// ── Main ────────────────────────────────────────────────────────────────────

int main(int argc, char** argv) {
    const char* json_path = "/tmp/real_video_poses.json";
    if (argc > 1) json_path = argv[1];

    std::fprintf(stderr,
        "╔══════════════════════════════════════════════════════════╗\n"
        "║  Real Video → 3DGS (Aether3D)                          ║\n"
        "╚══════════════════════════════════════════════════════════╝\n\n");

    std::fprintf(stderr, "Loading: %s\n", json_path);
    VideoData vd = parse_json(json_path);
    if (vd.frames.empty()) {
        std::fprintf(stderr, "ERROR: No frames in JSON.\n");
        return 1;
    }

    // ── GPU device (Metal if available, else Null) ──
    bool using_real_gpu = false;
#if defined(AETHER_TEST_HAS_METAL_GPU)
    auto metal_device = create_test_gpu_device();
    if (metal_device) using_real_gpu = true;
#endif
    aether::render::NullGPUDevice null_device;
    aether::render::GPUDevice& gpu_device = using_real_gpu
#if defined(AETHER_TEST_HAS_METAL_GPU)
        ? *metal_device
#else
        ? null_device
#endif
        : null_device;

    std::fprintf(stderr, "  GPU: %s\n", using_real_gpu ? "★ Metal" : "Null");

    // ── SplatRenderEngine ──
    aether::splat::SplatRenderConfig splat_config;
    splat_config.max_splats = 50000;
    aether::splat::SplatRenderEngine renderer(gpu_device, splat_config);

    // ── CoordinatorConfig ──
    aether::pipeline::CoordinatorConfig config;
    config.training.max_gaussians          = 300000;   // Object-scale: 300K
    config.training.max_iterations         = 5000;
    config.training.densify_interval       = 50;
    config.training.densify_grad_threshold = 0.00005f;
    config.training.render_width           = 384;
    config.training.render_height          = 216;
    config.frame_selection.min_displacement_m = 0.002f;  // 2mm
    config.frame_selection.min_rotation_rad   = 0.017f;  // 1°

    aether::pipeline::PipelineCoordinator coordinator(gpu_device, renderer, config);
    std::fprintf(stderr, "  PipelineCoordinator created\n\n");

    // ── Intrinsics ──
    float intrinsics[9] = {};
    intrinsics[0] = vd.fx;  intrinsics[2] = vd.cx;
    intrinsics[4] = vd.fy;  intrinsics[5] = vd.cy;
    intrinsics[8] = 1.0f;

    // Depth at reduced resolution for fast TSDF
    constexpr int kDepthW = 192, kDepthH = 108;

    std::fprintf(stderr, "Scanning %d real frames (%dx%d)...\n",
                 (int)vd.frames.size(), vd.width, vd.height);

    int accepted = 0, dropped = 0;
    std::vector<unsigned char> bgra;
    std::vector<float> depth_full, depth_small;

    auto scan_start = std::chrono::steady_clock::now();

    for (int i = 0; i < (int)vd.frames.size(); ++i) {
        const auto& fe = vd.frames[i];

        if (!load_bgra(fe.path, bgra, vd.width, vd.height)) continue;

        make_fake_depth(vd.width, vd.height, bgra.data(), 0.30f, depth_full);

        // Downsample depth
        depth_small.resize(kDepthW * kDepthH);
        float sx = (float)vd.width  / kDepthW;
        float sy = (float)vd.height / kDepthH;
        for (int y = 0; y < kDepthH; ++y)
            for (int x = 0; x < kDepthW; ++x) {
                int ix = std::min((int)(x * sx), vd.width - 1);
                int iy = std::min((int)(y * sy), vd.height - 1);
                depth_small[y * kDepthW + x] = depth_full[iy * vd.width + ix];
            }

        int result = coordinator.on_frame(
            bgra.data(), (unsigned)vd.width, (unsigned)vd.height,
            fe.cam2world, intrinsics,
            nullptr, 0,
            nullptr, 0, 0,
            depth_small.data(), kDepthW, kDepthH,
            0);

        if (result == 0) {
            ++accepted;
        } else {
            ++dropped;
            std::this_thread::sleep_for(std::chrono::milliseconds(200));
        }

        if ((i + 1) % 10 == 0 || i == (int)vd.frames.size() - 1) {
            auto snap = coordinator.get_snapshot();
            double elapsed = std::chrono::duration<double>(
                std::chrono::steady_clock::now() - scan_start).count();
            std::fprintf(stderr, "  [%3d/%d] accepted=%d dropped=%d gaussians=%zu %.1fs\n",
                         i + 1, (int)vd.frames.size(),
                         accepted, dropped, snap.num_gaussians, elapsed);
        }
    }

    coordinator.finish_scanning();

    double scan_sec = std::chrono::duration<double>(
        std::chrono::steady_clock::now() - scan_start).count();
    std::fprintf(stderr, "\nScan done: %d accepted, %d dropped (%.1fs)\n\n",
                 accepted, dropped, scan_sec);

    // ── Post-scan training ──
    std::fprintf(stderr, "Post-scan training (up to 120s, min 50 steps)...\n");
    coordinator.wait_for_training(50, 120.0);

    auto prog = coordinator.training_progress();
    std::fprintf(stderr, "  %zu steps, %zu gaussians, loss=%.4f\n\n",
                 prog.step, prog.num_gaussians, prog.loss);

    // ── Export PLY ──
    std::fprintf(stderr, "Exporting PLY → %s\n", vd.output_ply.c_str());
    auto status = coordinator.export_ply(vd.output_ply.c_str());
    if (status != aether::core::Status::kOk) {
        std::fprintf(stderr, "ERROR: export failed: %d\n",
                     static_cast<int>(status));
        return 1;
    }

    auto post = coordinator.training_progress();
    std::size_t final_count = std::max(prog.num_gaussians, post.num_gaussians);

    std::fprintf(stderr,
        "\n╔══════════════════════════════════════════════════════════╗\n"
        "║  COMPLETE                                               ║\n"
        "╠══════════════════════════════════════════════════════════╣\n"
        "║  Frames accepted : %d / %d                              \n"
        "║  Gaussians       : %zu                                  \n"
        "║  PLY             : %s\n"
        "╚══════════════════════════════════════════════════════════╝\n",
        accepted, (int)vd.frames.size(),
        final_count,
        vd.output_ply.c_str());

    return 0;
}
