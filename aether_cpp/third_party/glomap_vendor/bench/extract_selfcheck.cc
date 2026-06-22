// extract_selfcheck.cc — desktop correctness gate for the threaded extractor.
//
// Generates a deterministic multi-frequency textured grayscale image (so the
// DoG detector finds a few thousand keypoints, incl. border ones that exercise
// the per-worker patch scratch), then runs serial vs threaded extraction and
// asserts they are BIT-IDENTICAL (same keypoint count + max|desc delta| == 0).
//
// Build target: extract_selfcheck_exe.  Run: ./extract_selfcheck_exe [nthreads]

#include <cmath>
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <vector>

extern "C" int aether_dsp_sift_selfcheck(const uint8_t* gray,
                                         int width,
                                         int height,
                                         int max_features,
                                         int num_threads,
                                         int* out_n_serial,
                                         int* out_n_threaded,
                                         int* out_max_abs_desc_diff);

int main(int argc, char** argv) {
  // Large, high-frequency texture so keypoint count exceeds max_num_features
  // (8192) and the clamp loop engages — the regime where the device FAILED.
  const int W = 2400, H = 1800;
  std::vector<uint8_t> img(static_cast<size_t>(W) * H);
  uint64_t s = 0x9e3779b97f4a7c15ull;
  for (int y = 0; y < H; ++y) {
    for (int x = 0; x < W; ++x) {
      s ^= s << 13;
      s ^= s >> 7;
      s ^= s << 17;
      const double noise = static_cast<double>(s >> 57) - 32.0;  // [-32,32)
      double v = 128.0 + 60.0 * std::sin(x * 0.06) * std::sin(y * 0.045) +
                 45.0 * std::sin((x + y) * 0.19) +
                 40.0 * std::sin(x * 0.31) * std::cos(y * 0.29) +
                 30.0 * std::cos(x * 0.013 - y * 0.011) + noise;
      if (v < 0) v = 0;
      if (v > 255) v = 255;
      img[static_cast<size_t>(y) * W + x] = static_cast<uint8_t>(v);
    }
  }

  const int nthreads = argc > 1 ? std::atoi(argv[1]) : 4;
  int ns = 0, nt = 0, maxd = -1;
  const int rc =
      aether_dsp_sift_selfcheck(img.data(), W, H, 8192, nthreads, &ns, &nt, &maxd);

  std::printf(
      "SELFCHECK rc=%d n_serial=%d n_threaded=%d max_abs_desc_diff=%d "
      "nthreads=%d\n",
      rc, ns, nt, maxd, nthreads);
  const bool pass = (rc == 0 && ns == nt && ns > 0 && maxd == 0);
  std::printf("%s\n", pass ? "PASS bit-identical" : "FAIL");
  return pass ? 0 : 1;
}
