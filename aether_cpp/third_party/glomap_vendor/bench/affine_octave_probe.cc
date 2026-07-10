// affine_octave_probe.cc — M1 Stage C scope probe.
//
// QUESTION: can octave-0 affine-shape estimation be done with ONLY the octave-0
// GSS resident (the M1 constraint), or does VLFeat's affine patch-warp
// (vl_covdet_extract_patch_helper, covdet.c:2166) sample from OTHER octaves?
//
// The patch helper picks the gss level (o,s) whose sigma best matches the
// derivative sigma (sigmaD=1) scaled by factor=1/min(d1,d2). It scans
// o = firstOctave+1 .. lastOctave. For octave-0 keypoints (fo=0) this can land
// on octave 1+ depending on the keypoint scale.
//
// This probe runs the real CPU covdet (first_octave=0), takes the octave-0
// PRE-affine features, and for EACH replicates the patch helper's iter-1 level
// selection EXACTLY (d1=d2=sigma_kp at the isotropic initial frame), tallying
// which octave each keypoint's first affine patch is drawn from. If a material
// fraction need o>0, octave-0-only affine is INFEASIBLE in M1 and the
// cross-octave dependency must be surfaced to the user (P0 scope decision), not
// silently worked around.
//
// Build target: affine_octave_probe_exe. Run: ./affine_octave_probe_exe [img]

#include <algorithm>
#include <cmath>
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <string>
#include <vector>

#define STB_IMAGE_IMPLEMENTATION
#include "stb_image.h"

extern "C" {
#include "covdet.h"
#include "scalespace.h"
}

namespace {
std::vector<uint8_t> make_synthetic(int W, int H) {
  std::vector<uint8_t> img(static_cast<size_t>(W) * H);
  uint64_t s = 0x9e3779b97f4a7c15ull;
  for (int y = 0; y < H; ++y)
    for (int x = 0; x < W; ++x) {
      s ^= s << 13; s ^= s >> 7; s ^= s << 17;
      const double noise = static_cast<double>(s >> 57) - 32.0;
      double v = 128.0 + 60.0 * std::sin(x * 0.06) * std::sin(y * 0.045) +
                 45.0 * std::sin((x + y) * 0.19) +
                 40.0 * std::sin(x * 0.31) * std::cos(y * 0.29) +
                 30.0 * std::cos(x * 0.013 - y * 0.011) + noise;
      v = std::min(255.0, std::max(0.0, v));
      img[static_cast<size_t>(y) * W + x] = static_cast<uint8_t>(v);
    }
  return img;
}
}  // namespace

int main(int argc, char** argv) {
  int W = 0, H = 0;
  std::vector<uint8_t> gray;
  std::string source;
  if (argc > 1) {
    int ch = 0; uint8_t* d = stbi_load(argv[1], &W, &H, &ch, 1);
    if (!d) { std::fprintf(stderr, "stbi_load failed\n"); return 2; }
    gray.assign(d, d + static_cast<size_t>(W) * H); stbi_image_free(d); source = argv[1];
  } else { W = 2400; H = 1800; gray = make_synthetic(W, H); source = "synthetic"; }

  std::vector<float> gray_f(static_cast<size_t>(W) * H);
  for (size_t i = 0; i < gray_f.size(); ++i) gray_f[i] = gray[i] / 255.0f;

  const int octRes = 3;
  const double kPeak = 0.02 / octRes, kEdge = 10.0;
  const double baseScale = 1.6 * std::pow(2.0, 1.0 / octRes);
  const double sigmaD = 1.0;  // VL_COVDET_AA_RELATIVE_DERIVATIVE_SIGMA

  VlCovDet* cov = vl_covdet_new(VL_COVDET_METHOD_DOG);
  vl_covdet_set_first_octave(cov, 0);
  vl_covdet_set_octave_resolution(cov, octRes);
  vl_covdet_set_peak_threshold(cov, kPeak);
  vl_covdet_set_edge_threshold(cov, kEdge);
  vl_covdet_set_non_extrema_suppression_threshold(cov, 0.0);
  vl_covdet_put_image(cov, gray_f.data(), W, H);
  vl_covdet_detect(cov, 1u << 28);

  VlScaleSpace* gss = vl_covdet_get_gss(cov);
  VlScaleSpaceGeometry geom = vl_scalespace_get_geometry(gss);

  const int nf = (int)vl_covdet_get_num_features(cov);
  VlCovDetFeature* feats = vl_covdet_get_features(cov);

  // Replicate patch-helper iter-1 level selection (covdet.c:2222-2239).
  auto select_octave = [&](double sigma_kp) -> int {
    double factor = 1.0 / sigma_kp;  // d1=d2=sigma_kp, min=sigma_kp
    int o = (int)geom.firstOctave + 1;
    const int lastO = (int)geom.lastOctave;
    const int ofs = (int)geom.octaveFirstSubdivision;
    const int ols = (int)geom.octaveLastSubdivision;
    for (; o <= lastO; ++o) {
      int s = (int)std::floor(std::log2(sigmaD / (factor * baseScale)) - o);
      s = std::max(s, ofs);
      s = std::min(s, ols);
      double sigma_ = baseScale * std::pow(2.0, o + (double)s / octRes);
      if (factor * sigma_ > sigmaD) { o--; break; }
    }
    o = std::min(o, lastO);
    return o;
  };

  int by_octave[16] = {0};
  int n_oct0 = 0;
  for (int i = 0; i < nf; ++i) {
    if (feats[i].o != 0) continue;
    ++n_oct0;
    double sigma_kp = feats[i].frame.a11;  // isotropic init: a11 = sigma
    int o = select_octave(sigma_kp);
    if (o >= 0 && o < 16) ++by_octave[o];
  }

  std::printf("[affine_octave_probe] fixture=%s (%dx%d)  octave-0 kp=%d  lastOctave=%d\n",
              source.c_str(), W, H, n_oct0, geom.lastOctave);
  std::printf("[affine_octave_probe] iter-1 affine patch drawn from octave:\n");
  int need_higher = 0;
  for (int o = 0; o < 16; ++o) {
    if (by_octave[o] == 0) continue;
    double pct = n_oct0 ? 100.0 * by_octave[o] / n_oct0 : 0.0;
    std::printf("    octave %d: %d kp (%.1f%%)%s\n", o, by_octave[o], pct,
                o > 0 ? "  <-- NOT resident in M1 (octave-0 only)" : "");
    if (o > 0) need_higher += by_octave[o];
  }
  std::printf("[affine_octave_probe] => %d / %d octave-0 keypoints (%.1f%%) need gss "
              "from octave>0 for their FIRST affine patch warp\n",
              need_higher, n_oct0, n_oct0 ? 100.0 * need_higher / n_oct0 : 0.0);

  vl_covdet_delete(cov);
  return 0;
}
