// gpu_extract_timing.cc — per-frame GPU DSP-SIFT cost across repeated calls.
//
// Proves the persistent-harness + pipeline-cache win (dawn_kernel_harness +
// dsp_sift_gpu_c). aether_dsp_sift_extract_gpu used to build a fresh
// DawnKernelHarness per call, paying Dawn init + ~10 WGSL pipeline compiles
// EVERY frame. Now one harness (with a pipeline cache) is kept alive, so:
//   frame 0  = cold: Dawn init + all pipeline compiles + extract
//   frame 1+ = warm: cached pipelines, init skipped, just the extract
// The cold→warm delta is exactly the per-frame recompile+init tax removed.
//
// Usage: gpu_extract_timing_exe [image.jpg] [n_frames=8]

#include <chrono>
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <string>
#include <vector>

#define STB_IMAGE_IMPLEMENTATION
#include "stb_image.h"

extern "C" int aether_dsp_sift_extract_gpu(const uint8_t*, int, int, int, int,
                                           float*, uint8_t*, int, int*);

// Textured synthetic fallback when no image is given (keypoint-rich so the
// warm per-frame extract time is representative, not trivial).
static std::vector<uint8_t> make_synthetic(int W, int H) {
    std::vector<uint8_t> g(static_cast<size_t>(W) * H);
    for (int y = 0; y < H; ++y)
        for (int x = 0; x < W; ++x)
            g[static_cast<size_t>(y) * W + x] =
                static_cast<uint8_t>(((x * 7) ^ (y * 13)) + (x / 3) * (y / 5));
    return g;
}

int main(int argc, char** argv) {
    int W = 0, H = 0;
    std::vector<uint8_t> gray;
    std::string src;
    if (argc > 1) {
        int ch = 0;
        uint8_t* d = stbi_load(argv[1], &W, &H, &ch, 1);
        if (!d) { std::fprintf(stderr, "stbi_load failed\n"); return 2; }
        gray.assign(d, d + static_cast<size_t>(W) * H);
        stbi_image_free(d);
        src = argv[1];
    } else {
        W = 2400; H = 1800; gray = make_synthetic(W, H); src = "synthetic";
    }
    const int N = (argc > 2) ? std::atoi(argv[2]) : 8;

    const int cap = 40000;
    std::vector<float> xy(2 * cap);
    std::vector<uint8_t> desc(static_cast<size_t>(128) * cap);

    std::printf("[timing] fixture=%s (%dx%d)  frames=%d  persistent-harness build\n",
                src.c_str(), W, H, N);

    double cold_ms = 0.0, warm_sum = 0.0;
    int warm_n = 0, first_count = -1;
    for (int f = 0; f < N; ++f) {
        int cnt = 0;
        auto t0 = std::chrono::steady_clock::now();
        int rc = aether_dsp_sift_extract_gpu(gray.data(), W, H, 8192, 0,
                                             xy.data(), desc.data(), cap, &cnt);
        auto t1 = std::chrono::steady_clock::now();
        double ms = std::chrono::duration<double, std::milli>(t1 - t0).count();
        const char* tag = (f == 0) ? "cold: Dawn init + compile all pipelines"
                                    : "warm: cached pipelines";
        std::printf("[timing] frame %d: rc=%d count=%d  %8.1f ms   (%s)\n",
                    f, rc, cnt, ms, tag);
        if (f == 0) { cold_ms = ms; first_count = cnt; }
        else { warm_sum += ms; ++warm_n; }
        // Count must stay identical across frames — proves the reused harness is
        // deterministic (not accumulating state / drifting output).
        if (f > 0 && cnt != first_count)
            std::printf("  [WARN] count changed across frames: %d vs %d\n",
                        cnt, first_count);
    }
    if (warm_n > 0) {
        double warm_avg = warm_sum / warm_n;
        std::printf("[timing] cold=%.1f ms  warm_avg=%.1f ms  "
                    "per-frame tax removed=%.1f ms (%.1fx)\n",
                    cold_ms, warm_avg, cold_ms - warm_avg,
                    warm_avg > 0 ? cold_ms / warm_avg : 0.0);
    }
    return 0;
}
