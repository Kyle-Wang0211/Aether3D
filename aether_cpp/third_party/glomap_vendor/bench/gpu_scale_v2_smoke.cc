// gpu_scale_v2_smoke.cc — [SCALE-PERSIST 2026-08-06] host smoke for the _v2
// GPU exit: runs the REAL Dawn GPU DSP-SIFT chain (same fixture generator as
// gpu_extract_count_contract.cc) through aether_dsp_sift_extract_gpu_v2 and
// checks the new out_scales/out_orientations outputs are populated and sane
// (finite, positive scales; orientations within [-pi, pi]). Also runs the CPU
// _v2 (first_octave=0 via the GPU-matched _fo path is NOT exposed in _v2 —
// CPU here is production first_octave=-1, so counts are expected to differ;
// this is a value-sanity smoke, not a parity gate).
#include <algorithm>
#include <cmath>
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <vector>

extern "C" {
int aether_dsp_sift_extract_gpu_v2(const uint8_t*, int, int, int, int, float*,
                                   uint8_t*, float*, float*, int, int*);
int aether_dsp_sift_extract_v2(const uint8_t*, int, int, int, float*, uint8_t*,
                               float*, float*, int, int*);
}

namespace {
std::vector<uint8_t> MakeSynthetic(int width, int height) {
  std::vector<uint8_t> image(static_cast<size_t>(width) * height);
  uint64_t state = 0x9e3779b97f4a7c15ull;
  for (int y = 0; y < height; ++y) {
    for (int x = 0; x < width; ++x) {
      state ^= state << 13;
      state ^= state >> 7;
      state ^= state << 17;
      const double noise = static_cast<double>(state >> 57) - 32.0;
      const double value =
          128 + 60 * std::sin(x * 0.06) * std::sin(y * 0.045) +
          45 * std::sin((x + y) * 0.19) +
          40 * std::sin(x * 0.31) * std::cos(y * 0.29) +
          30 * std::cos(x * 0.013 - y * 0.011) + noise;
      image[static_cast<size_t>(y) * width + x] =
          static_cast<uint8_t>(std::min(255.0, std::max(0.0, value)));
    }
  }
  return image;
}

int CheckAndReport(const char* tag, int rc, int n, const std::vector<float>& sc,
                   const std::vector<float>& ori) {
  if (rc != 0 || n <= 0) {
    std::printf("%s rc=%d n=%d — FAIL\n", tag, rc, n);
    return 1;
  }
  std::vector<float> s(sc.begin(), sc.begin() + n);
  int bad = 0;
  for (int i = 0; i < n; ++i) {
    if (!std::isfinite(s[i]) || s[i] <= 0.0f) ++bad;
    if (!std::isfinite(ori[i]) || ori[i] < -3.1415927f || ori[i] > 3.1415927f)
      ++bad;
  }
  std::sort(s.begin(), s.end());
  std::printf("%s rc=0 n=%d bad=%d scale[min=%.4f p10=%.4f p50=%.4f p90=%.4f "
              "max=%.4f]\n",
              tag, n, bad, s.front(), s[n / 10], s[n / 2], s[(n * 9) / 10],
              s.back());
  return bad == 0 ? 0 : 1;
}
}  // namespace

int main() {
  const int w = 1024, h = 768, cap = 8192;
  const std::vector<uint8_t> img = MakeSynthetic(w, h);
  std::vector<float> xy(static_cast<size_t>(cap) * 2);
  std::vector<uint8_t> desc(static_cast<size_t>(cap) * 128);
  std::vector<float> sc(cap, -777.0f), ori(cap, -777.0f);
  int n = 0;
  int rc = aether_dsp_sift_extract_gpu_v2(img.data(), w, h, cap, 0, xy.data(),
                                          desc.data(), sc.data(), ori.data(),
                                          cap, &n);
  int fail = CheckAndReport("GPU_V2", rc, n, sc, ori);

  std::fill(sc.begin(), sc.end(), -777.0f);
  std::fill(ori.begin(), ori.end(), -777.0f);
  n = 0;
  rc = aether_dsp_sift_extract_v2(img.data(), w, h, cap, xy.data(), desc.data(),
                                  sc.data(), ori.data(), cap, &n);
  fail += CheckAndReport("CPU_V2", rc, n, sc, ori);

  std::printf(fail == 0 ? "GPU_SCALE_V2_SMOKE PASS\n"
                        : "GPU_SCALE_V2_SMOKE FAIL\n");
  return fail;
}
