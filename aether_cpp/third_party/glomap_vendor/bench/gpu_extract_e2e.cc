// gpu_extract_e2e.cc — end-to-end GPU vs CPU extractor parity (M2-3 smoke).
//
// First time the WHOLE GPU chain runs connected (detect→suppress→affine→orient
// →descriptor, each on the PREVIOUS stage's GPU output, not a shared CPU input).
// Cross-stage integration bugs surface here. Compares the GPU extractor against
// the CPU _threaded baseline on ONE image: keypoint counts + descriptor
// match-recall (mutual Lowe-ratio cross-check between the two descriptor sets).
//
// This is the integration smoke gate before the multi-frame reproj fixture.
// Build: gpu_extract_e2e_exe. Run: [img].

#include <algorithm>
#include <climits>
#include <cmath>
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <string>
#include <vector>

#define STB_IMAGE_IMPLEMENTATION
#include "stb_image.h"

extern "C" {
int aether_dsp_sift_extract_gpu(const uint8_t*, int, int, int, int, float*,
                                uint8_t*, int, int*);
int aether_dsp_sift_extract_threaded(const uint8_t*, int, int, int, int, float*,
                                     uint8_t*, int, int*);
// first_octave-parameterized CPU reference (fo=0 to match the GPU pipeline).
int aether_dsp_sift_extract_threaded_fo(const uint8_t*, int, int, int, int, int,
                                        float*, uint8_t*, int, int*);
}

namespace {
std::vector<uint8_t> make_synthetic(int W, int H) {
    std::vector<uint8_t> img((size_t)W * H);
    uint64_t s = 0x9e3779b97f4a7c15ull;
    for (int y = 0; y < H; ++y)
        for (int x = 0; x < W; ++x) {
            s ^= s << 13; s ^= s >> 7; s ^= s << 17;
            double n = (double)(s >> 57) - 32.0;
            double v = 128 + 60 * std::sin(x * 0.06) * std::sin(y * 0.045) +
                       45 * std::sin((x + y) * 0.19) +
                       40 * std::sin(x * 0.31) * std::cos(y * 0.29) +
                       30 * std::cos(x * 0.013 - y * 0.011) + n;
            img[(size_t)y * W + x] = (uint8_t)std::min(255.0, std::max(0.0, v));
        }
    return img;
}
long dist2(const uint8_t* a, const uint8_t* b) {
    long s = 0; for (int i = 0; i < 128; ++i) { long d = (long)a[i] - b[i]; s += d * d; } return s;
}
// mutual Lowe-ratio match count between two descriptor sets.
int mutual_match(const uint8_t* d1, int n1, const uint8_t* d2, int n2, double ratio) {
    std::vector<int> b12(n1, -1);
    for (int i = 0; i < n1; ++i) {
        long a = LONG_MAX, b = LONG_MAX; int bj = -1;
        for (int j = 0; j < n2; ++j) { long d = dist2(d1 + (size_t)i * 128, d2 + (size_t)j * 128);
            if (d < a) { b = a; a = d; bj = j; } else if (d < b) b = d; }
        if (bj >= 0 && (double)a < ratio * ratio * (double)b) b12[i] = bj;
    }
    std::vector<int> b21(n2, -1);
    for (int j = 0; j < n2; ++j) {
        long a = LONG_MAX, b = LONG_MAX; int bi = -1;
        for (int i = 0; i < n1; ++i) { long d = dist2(d2 + (size_t)j * 128, d1 + (size_t)i * 128);
            if (d < a) { b = a; a = d; bi = i; } else if (d < b) b = d; }
        if (bi >= 0 && (double)a < ratio * ratio * (double)b) b21[j] = bi;
    }
    int m = 0; for (int i = 0; i < n1; ++i) { int j = b12[i]; if (j >= 0 && b21[j] == i) ++m; }
    return m;
}
}  // namespace

int main(int argc, char** argv) {
    int W = 0, H = 0; std::vector<uint8_t> gray; std::string src;
    if (argc > 1) {
        int ch = 0; uint8_t* d = stbi_load(argv[1], &W, &H, &ch, 1);
        if (!d) { std::fprintf(stderr, "stbi_load failed\n"); return 2; }
        gray.assign(d, d + (size_t)W * H); stbi_image_free(d); src = argv[1];
    } else { W = 2400; H = 1800; gray = make_synthetic(W, H); src = "synthetic"; }
    std::printf("[gpu_extract_e2e] fixture=%s (%dx%d)\n", src.c_str(), W, H);

    // Use a large feature budget so the 8192 clamp does NOT pick divergent
    // subsets (which would confound the descriptor-quality measurement). The
    // production clamp is exercised separately by the C ABI's max_features.
    const int max_feat = std::getenv("E2E_CLAMP") ? 8192 : (1 << 20);
    const int cap = 40000;
    std::vector<float> gxy(2 * cap), cxy(2 * cap);
    std::vector<uint8_t> gd((size_t)128 * cap), cd((size_t)128 * cap);
    int gn = 0, cn = 0;

    int rg = aether_dsp_sift_extract_gpu(gray.data(), W, H, max_feat, 0, gxy.data(), gd.data(), cap, &gn);
    // CPU baseline at first_octave=0 (matches the GPU pipeline). Production
    // default is -1; that scope choice is tracked separately.
    int rc = aether_dsp_sift_extract_threaded_fo(gray.data(), W, H, max_feat, 0, /*first_octave=*/0, cxy.data(), cd.data(), cap, &cn);
    std::printf("[gpu_extract_e2e] GPU rc=%d count=%d   CPU rc=%d count=%d\n", rg, gn, rc, cn);
    if (rg != 0 || rc != 0) { std::printf("FAIL extractor returned error\n"); return 1; }

    // DEBUG: how many GPU kps share a position with a CPU kp, and for those, is
    // the descriptor identical? Isolates keypoint-set divergence vs descriptor bug.
    if (std::getenv("E2E_DEBUG")) {
        // For each GPU kp, among ALL CPU kps within 0.1px (same position; there
        // may be multiple orientation twins), pick the BEST descriptor cosine —
        // this disambiguates orientation twins, isolating real descriptor error
        // from orientation-order ambiguity.
        int pos_matched = 0; std::vector<double> cos_best;
        for (int i = 0; i < gn; ++i) {
            float gx = gxy[2*i], gy = gxy[2*i+1];
            double best = -2.0; bool any=false;
            for (int j = 0; j < cn; ++j) {
                float dx = cxy[2*j]-gx, dy = cxy[2*j+1]-gy;
                if (dx*dx+dy*dy >= 0.01f) continue;  // not same position
                any=true;
                double dot=0,na=0,nb=0;
                for (int b=0;b<128;++b){ dot+=(double)gd[(size_t)i*128+b]*cd[(size_t)j*128+b];
                    na+=(double)gd[(size_t)i*128+b]*gd[(size_t)i*128+b]; nb+=(double)cd[(size_t)j*128+b]*cd[(size_t)j*128+b]; }
                double c = (na>0&&nb>0)? dot/(std::sqrt(na)*std::sqrt(nb)) : 0;
                if (c > best) best = c;
            }
            if (any) { ++pos_matched; cos_best.push_back(best); }
        }
        std::sort(cos_best.begin(), cos_best.end());
        std::printf("[e2e_debug] GPU kps with CPU kp at same pos (<0.1px): %d/%d\n", pos_matched, gn);
        if (!cos_best.empty())
            std::printf("[e2e_debug] BEST-twin desc cosine: median=%.5f min=%.5f p05=%.5f p01=%.5f\n",
                        cos_best[cos_best.size()/2], cos_best.front(),
                        cos_best[cos_best.size()/20], cos_best[cos_best.size()/100]);
    }

    // descriptor interchangeability: mutual matches GPU↔CPU vs CPU↔CPU self.
    int m_gc = mutual_match(gd.data(), gn, cd.data(), cn, 0.8);
    int m_cc = mutual_match(cd.data(), cn, cd.data(), cn, 0.8);
    double recall = m_cc > 0 ? (double)m_gc / m_cc : 0.0;
    std::printf("[gpu_extract_e2e] mutual matches GPU↔CPU=%d  CPU↔CPU(self)=%d  recall=%.4f\n",
                m_gc, m_cc, recall);

    // count agreement (within a tolerance — GPU/CPU keypoint sets are near but
    // not bit-identical due to the f32 detection/affine/orient tails).
    double count_ratio = cn > 0 ? (double)gn / cn : 0.0;
    std::printf("[gpu_extract_e2e] count ratio GPU/CPU=%.4f\n", count_ratio);

    // Integration smoke gate: the GPU keypoint set must closely track the CPU
    // fo=0 baseline (count ratio ~1) and the descriptors must be interchangeable
    // for matching (mutual recall). The descriptor KERNEL is bit-faithful (E gate
    // = 0.99998); the e2e tail is the cumulative f32 divergence of detect/affine/
    // orient producing slightly different oriented frames — expected, not a bug.
    // The authoritative M2 gate is end-to-end reproj (separate fixture).
    const bool pass = recall >= 0.90 && count_ratio >= 0.95 && count_ratio <= 1.05;
    std::printf("%s M2 e2e extractor integration (recall=%.3f, count_ratio=%.3f)\n",
                pass ? "PASS" : "FAIL", recall, count_ratio);
    return pass ? 0 : 1;
}
