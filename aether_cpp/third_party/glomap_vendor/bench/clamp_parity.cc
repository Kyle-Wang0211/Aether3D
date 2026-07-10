// clamp_parity.cc — verify ① (clamp-before-descriptor) is bit-faithful.
//
// The optimization moves the COLMAP (octave,scale) clamp BEFORE the descriptor
// stage so the descriptor kernel runs over ~max_features instead of the full
// 1→K-expanded set. This MUST not change the emitted descriptors: the same
// surviving keypoints must get byte-identical descriptors.
//
// Test: run SiftExtractDawn twice on the same image —
//   (A) max_features = HUGE  → descriptor on ALL oriented kp (the pre-① behavior)
//   (B) max_features = 8192  → descriptor on the clamped subset (the ① behavior)
// Then for every (B) keypoint, find its (A) twin by exact (x,y,octave,scale) and
// assert the raw 128-d descriptor is byte-identical (after the same finishing).
// Any mismatch = ① broke bit-faithfulness → FAIL.
//
// Build: clamp_parity_exe. Run: [img].

#include <algorithm>
#include <array>
#include <cmath>
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <string>
#include <unordered_map>
#include <vector>

#define STB_IMAGE_IMPLEMENTATION
#include "stb_image.h"

#include "dawn_kernel_harness.h"
#include "sift_extract_dawn.h"

namespace {
std::vector<uint8_t> make_synth(int W, int H) {
    std::vector<uint8_t> img((size_t)W * H);
    uint64_t s = 0x9e3779b97f4a7c15ull;
    for (int y = 0; y < H; ++y) for (int x = 0; x < W; ++x) {
        s ^= s << 13; s ^= s >> 7; s ^= s << 17; double n = (double)(s >> 57) - 32.0;
        double v = 128 + 60 * std::sin(x * 0.06) * std::sin(y * 0.045) +
                   45 * std::sin((x + y) * 0.19) + 40 * std::sin(x * 0.31) * std::cos(y * 0.29) +
                   30 * std::cos(x * 0.013 - y * 0.011) + n;
        img[(size_t)y * W + x] = (uint8_t)std::min(255.0, std::max(0.0, v));
    }
    return img;
}
}  // namespace

int main(int argc, char** argv) {
    int W = 0, H = 0; std::vector<uint8_t> gray;
    if (argc > 1) { int ch = 0; uint8_t* d = stbi_load(argv[1], &W, &H, &ch, 1);
        if (!d) { std::fprintf(stderr, "stbi_load failed\n"); return 2; }
        gray.assign(d, d + (size_t)W * H); stbi_image_free(d);
    } else { W = 2400; H = 1800; gray = make_synth(W, H); }
    std::printf("[clamp_parity] %dx%d\n", W, H);

    aether::tools::DawnKernelHarness harness;
    if (!harness.init()) { std::fprintf(stderr, "Dawn init failed\n"); return 2; }
    aether::tools::SiftExtractDawn extractor;

    // Force the f32 descriptor for this byte-exact test (production may default
    // to f16 when ShaderF16 is available, but ③/clamp bit-faithfulness is a
    // PROPERTY OF THE f32 SERIAL PATH; the f16 variant has its own cosine gate).
    setenv("SED_FORCE_F32", "1", 1);

    // ── ③ vs serial descriptor: run the SAME (clamped) extraction with the
    //    scale-parallel descriptor (default) and the serial reference, and
    //    require BYTE-IDENTICAL descriptors (the mean must be summed in the same
    //    order). This is the ③ bit-faithfulness gate. ──
    // Use NO clamp (max_features=0) so par and ser have the SAME full keypoint
    // SET (the 8192-clamp boundary keypoint can differ between runs due to the
    // orientation atomicAdd append order — that's a clamp-boundary set effect,
    // not a ③ descriptor error). With the full set, ③ correctness is isolated.
    aether::tools::SiftExtractDawn::Result par, ser;
    setenv("SED_PARALLEL_DESC", "1", 1);   // ③ scale-parallel path
    if (!extractor.extract(harness, gray.data(), W, H, 0, &par)) {
        std::printf("FAIL parallel extract\n"); return 1;
    }
    unsetenv("SED_PARALLEL_DESC");          // serial (default) path
    if (!extractor.extract(harness, gray.data(), W, H, 0, &ser)) {
        std::printf("FAIL serial extract\n"); return 1;
    }
    {
        // The orientation kernel's atomicAdd append makes the keypoint ORDER
        // non-deterministic across runs, so index-aligned par[i] vs ser[i] would
        // compare DIFFERENT keypoints. Compare as SETS: every parallel descriptor
        // must have an exact byte-twin in the serial set (and vice-versa via
        // count). This proves ③ changes no descriptor's bytes.
        std::unordered_map<std::string, int> ser_set;
        ser_set.reserve(ser.count * 2);
        for (int i = 0; i < ser.count; ++i)
            ser_set[std::string(reinterpret_cast<const char*>(&ser.raw_desc[(size_t)i * 128]),
                                128 * sizeof(float))]++;
        int exact = 0, notwin = 0;
        for (int i = 0; i < par.count; ++i) {
            auto it = ser_set.find(std::string(
                reinterpret_cast<const char*>(&par.raw_desc[(size_t)i * 128]),
                128 * sizeof(float)));
            if (it != ser_set.end() && it->second > 0) { ++exact; --(it->second); }
            else ++notwin;
        }
        std::printf("[clamp_parity] ③-vs-serial(set): par=%d ser=%d  byte-exact-twin=%d  no-twin=%d\n",
                    par.count, ser.count, exact, notwin);
        if (par.count != ser.count || notwin != 0) {
            std::printf("FAIL ③ scale-parallel NOT bit-identical to serial\n");
            return 1;
        }
        std::printf("PASS ③ scale-parallel bit-identical to serial\n");
    }

    aether::tools::SiftExtractDawn::Result full, clamped;
    if (!extractor.extract(harness, gray.data(), W, H, /*max_features=*/0, &full)) {
        std::printf("FAIL full extract\n"); return 1;
    }
    if (!extractor.extract(harness, gray.data(), W, H, /*max_features=*/8192, &clamped)) {
        std::printf("FAIL clamped extract\n"); return 1;
    }
    std::printf("[clamp_parity] full=%d  clamped=%d\n", full.count, clamped.count);

    // Hash every FULL descriptor's exact 128-float bytes → its row. Then for each
    // CLAMPED descriptor, require an EXACT byte-twin exists in full. This sidesteps
    // the orientation-twin key collision (twins share (x,y,o,s) but differ in
    // descriptor): byte-identity of the descriptor itself is the faithful test —
    // the clamp must not have changed ANY surviving keypoint's descriptor bytes.
    auto desc_key = [&](const float* d) {
        std::string k(reinterpret_cast<const char*>(d), 128 * sizeof(float));
        return k;
    };
    std::unordered_map<std::string, int> full_desc;
    full_desc.reserve(full.count * 2);
    for (int i = 0; i < full.count; ++i)
        full_desc[desc_key(&full.raw_desc[(size_t)i * 128])]++;

    int exact = 0, missing = 0;
    for (int i = 0; i < clamped.count; ++i) {
        auto it = full_desc.find(desc_key(&clamped.raw_desc[(size_t)i * 128]));
        if (it != full_desc.end() && it->second > 0) { ++exact; --(it->second); }
        else ++missing;
    }
    std::printf("[clamp_parity] full=%d clamped=%d  byte-exact-twin=%d  no-twin=%d\n",
                full.count, clamped.count, exact, missing);

    // Bit-faithful: every clamped descriptor has an EXACT byte-twin in the full
    // set (the clamp only selects a subset; it changes no descriptor's bytes).
    const bool pass = (missing == 0) && (exact == clamped.count);
    std::printf("%s clamp-before-descriptor bit-faithful\n", pass ? "PASS" : "FAIL");
    return pass ? 0 : 1;
}
