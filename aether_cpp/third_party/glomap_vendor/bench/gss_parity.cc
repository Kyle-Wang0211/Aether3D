// gss_parity.cc — GPU vs CPU(VLFeat) Gaussian Scale Space parity gate (M0).
//
// Builds the GPU DSP-SIFT GSS pyramid (tools/sift_pyramid_dawn) and the CPU
// reference (VLFeat vl_scalespace with the identical covdet-DOG geometry,
// first_octave = 0), then compares every (octave, sublevel) level by max
// relative error and RMS. M0 GSS go/no-go: max-rel <= 1e-3, RMS <= 2e-4
// (GPU_DSP_SIFT_PLAN.md:67).
//
// Both sides consume the SAME grayscale u8 image divided by 255 — the GPU does
// the divide in S0, the CPU divide is done here — so the RGB→gray choice is
// irrelevant to parity (identical bytes feed both). A real capture JPEG is the
// default fixture; a synthetic textured image is the fallback.
//
// Build target: gss_parity_exe.  Run: ./gss_parity_exe [image.jpg]

#include <algorithm>
#include <cmath>
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <string>
#include <vector>

#define STB_IMAGE_IMPLEMENTATION
#include "stb_image.h"

#include "sift_pyramid_dawn.h"

extern "C" {
#include "scalespace.h"
}

namespace {

using aether::tools::DawnKernelHarness;
using aether::tools::SiftPyramidDawn;

// Synthetic fallback fixture (same recipe as extract_selfcheck.cc).
std::vector<uint8_t> make_synthetic(int W, int H) {
    std::vector<uint8_t> img(static_cast<size_t>(W) * H);
    uint64_t s = 0x9e3779b97f4a7c15ull;
    for (int y = 0; y < H; ++y) {
        for (int x = 0; x < W; ++x) {
            s ^= s << 13;
            s ^= s >> 7;
            s ^= s << 17;
            const double noise = static_cast<double>(s >> 57) - 32.0;
            double v = 128.0 + 60.0 * std::sin(x * 0.06) * std::sin(y * 0.045) +
                       45.0 * std::sin((x + y) * 0.19) +
                       40.0 * std::sin(x * 0.31) * std::cos(y * 0.29) +
                       30.0 * std::cos(x * 0.013 - y * 0.011) + noise;
            v = std::min(255.0, std::max(0.0, v));
            img[static_cast<size_t>(y) * W + x] = static_cast<uint8_t>(v);
        }
    }
    return img;
}

struct LevelError {
    double max_rel;
    double rms;
};

// max-rel uses the denominator max(|cpu|, eps) so near-zero reference pixels
// don't blow up the ratio; RMS is the plain root-mean-square of |gpu - cpu|.
LevelError compare(const std::vector<float>& gpu, const float* cpu, size_t n) {
    double max_rel = 0.0;
    double sse = 0.0;
    constexpr double kEps = 1e-6;
    for (size_t i = 0; i < n; ++i) {
        const double a = static_cast<double>(gpu[i]);
        const double b = static_cast<double>(cpu[i]);
        const double diff = std::abs(a - b);
        const double rel = diff / std::max(std::abs(b), kEps);
        if (rel > max_rel) max_rel = rel;
        sse += diff * diff;
    }
    return {max_rel, std::sqrt(sse / static_cast<double>(n))};
}

}  // namespace

int main(int argc, char** argv) {
    // ── Load fixture ──
    int W = 0, H = 0;
    std::vector<uint8_t> gray;
    std::string source;
    if (argc > 1) {
        int channels = 0;
        uint8_t* data =
            stbi_load(argv[1], &W, &H, &channels, /*desired_channels=*/1);
        if (!data) {
            std::fprintf(stderr, "[gss_parity] stbi_load failed for %s: %s\n",
                         argv[1], stbi_failure_reason());
            return 2;
        }
        gray.assign(data, data + static_cast<size_t>(W) * H);
        stbi_image_free(data);
        source = argv[1];
    } else {
        W = 2400;
        H = 1800;
        gray = make_synthetic(W, H);
        source = "synthetic 2400x1800";
    }
    std::printf("[gss_parity] fixture: %s  (%dx%d)\n", source.c_str(), W, H);

    // ── GPU pyramid ──
    DawnKernelHarness harness;
    if (!harness.init()) {
        std::fprintf(stderr, "[gss_parity] Dawn harness init failed\n");
        return 2;
    }
    SiftPyramidDawn gpu;
    if (!gpu.build(harness, gray.data(), W, H)) {
        std::fprintf(stderr, "[gss_parity] GPU pyramid build failed\n");
        return 2;
    }

    // ── CPU reference (VLFeat), identical geometry to covdet DOG, fo=0 ──
    std::vector<float> gray_f(static_cast<size_t>(W) * H);
    for (size_t i = 0; i < gray_f.size(); ++i) {
        gray_f[i] = static_cast<float>(gray[i]) / 255.0f;
    }
    VlScaleSpaceGeometry geom = vl_scalespace_get_default_geometry(W, H);
    geom.width = W;
    geom.height = H;
    geom.firstOctave = 0;
    geom.lastOctave = gpu.last_octave();
    geom.octaveResolution = SiftPyramidDawn::kOctaveResolution;
    geom.octaveFirstSubdivision = SiftPyramidDawn::kOctaveFirstSub;
    geom.octaveLastSubdivision = SiftPyramidDawn::kOctaveLastSub;
    VlScaleSpace* ss = vl_scalespace_new_with_geometry(geom);
    if (!ss) {
        std::fprintf(stderr, "[gss_parity] vl_scalespace_new failed\n");
        return 2;
    }
    vl_scalespace_put_image(ss, gray_f.data());

    // ── Compare every level ──
    std::printf("[gss_parity] geometry: octaves [%d..%d], sublevels [%d..%d], "
                "baseScale=%.6f\n",
                gpu.first_octave(), gpu.last_octave(),
                SiftPyramidDawn::kOctaveFirstSub,
                SiftPyramidDawn::kOctaveLastSub, SiftPyramidDawn::base_scale());

    constexpr double kMaxRelGate = 1e-3;
    constexpr double kRmsGate = 2e-4;
    double worst_max_rel = 0.0, worst_rms = 0.0;
    bool pass = true;
    std::printf("%-4s %-4s %-11s %-11s %-12s %-12s\n", "oct", "sub", "size",
                "sigma", "max_rel", "rms");
    for (int o = gpu.first_octave(); o <= gpu.last_octave(); ++o) {
        for (int s = SiftPyramidDawn::kOctaveFirstSub;
             s <= SiftPyramidDawn::kOctaveLastSub; ++s) {
            const auto lg = gpu.level_geom(o, s);
            const size_t n = static_cast<size_t>(lg.width) * lg.height;
            std::vector<float> gpu_level = gpu.read_level(harness, o, s);
            const float* cpu_level = vl_scalespace_get_level(ss, o, s);
            const LevelError e = compare(gpu_level, cpu_level, n);
            worst_max_rel = std::max(worst_max_rel, e.max_rel);
            worst_rms = std::max(worst_rms, e.rms);
            const bool level_pass = e.max_rel <= kMaxRelGate && e.rms <= kRmsGate;
            pass = pass && level_pass;
            char size_str[32];
            std::snprintf(size_str, sizeof(size_str), "%dx%d", lg.width,
                          lg.height);
            std::printf("%-4d %-4d %-11s %-11.5f %-12.3e %-12.3e %s\n", o, s,
                        size_str, lg.sigma, e.max_rel, e.rms,
                        level_pass ? "" : "<-- FAIL");
        }
    }

    vl_scalespace_delete(ss);

    std::printf("\n[gss_parity] worst max_rel=%.3e (gate %.0e)  worst rms=%.3e "
                "(gate %.0e)\n",
                worst_max_rel, kMaxRelGate, worst_rms, kRmsGate);
    std::printf("%s\n", pass ? "PASS M0 gss parity" : "FAIL M0 gss parity");
    return pass ? 0 : 1;
}
