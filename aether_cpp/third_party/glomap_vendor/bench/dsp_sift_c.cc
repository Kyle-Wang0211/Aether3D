// dsp_sift_c.cc — C ABI for on-device DSP-SIFT feature extraction.
// Drives colmap's CovariantSiftCPUFeatureExtractor (VLFeat covdet, affine-shape
// + domain-size-pooling + RootSIFT) UNMODIFIED. The platform side decodes +
// resizes the JPEG to a grayscale buffer (CGImage on iOS) and passes it here.

#include "colmap/feature/extractor.h"
#include "colmap/feature/matcher.h"
#include "colmap/feature/sift.h"
#include "colmap/feature/types.h"
#include "colmap/sensor/bitmap.h"

#include "aether_bitmap_shim.h"
#include "aether_threaded_extract.h"

#include <cstdint>
#include <cstdio>
#include <cstring>
#include <memory>
#include <vector>

extern "C" {

// gray: GRAYSCALE, row-major, top-down (CGImage convention), width*height bytes.
// Writes up to out_cap keypoints into out_xy (2*N floats x,y) + out_desc
// (128*N uint8 RootSIFT). *out_count = #keypoints. Returns 0 on success.
int aether_dsp_sift_extract(const uint8_t* gray,
                            int width,
                            int height,
                            int max_features,
                            float* out_xy,
                            uint8_t* out_desc,
                            int out_cap,
                            int* out_count) {
  if (out_count) *out_count = 0;
  try {
    if (gray == nullptr || width <= 0 || height <= 0 || out_cap <= 0) return 1;

    // [MIGRATION 4.0.4 / STEP 5] colmap::Bitmap dropped the FreeImage backing
    // (Allocate / Data() / FIBITMAP). Construct a grayscale bitmap and fill its
    // row-major buffer directly via RowMajorData().
    colmap::Bitmap bitmap(width, height, /*as_rgb=*/false);
    bitmap.RowMajorData().assign(gray,
                                 gray + static_cast<size_t>(width) * height);

    colmap::FeatureExtractionOptions opts(colmap::FeatureExtractorType::SIFT);
    opts.sift = std::make_shared<colmap::SiftExtractionOptions>();
    opts.sift->max_num_features = max_features > 0 ? max_features : 8192;
    opts.sift->estimate_affine_shape = true;   // DSP-SIFT (covariant) path
    opts.sift->domain_size_pooling = true;
    // normalization defaults to L1_ROOT (RootSIFT) — matches the desktop recipe.

    std::unique_ptr<colmap::FeatureExtractor> extractor =
        colmap::CreateSiftFeatureExtractor(opts);
    if (!extractor) return 3;

    colmap::FeatureKeypoints kps;
    colmap::FeatureDescriptors desc;
    if (!extractor->Extract(bitmap, &kps, &desc)) return 4;

    int n = static_cast<int>(kps.size());
    if (n > out_cap) n = out_cap;
    if (out_xy != nullptr) {
      for (int i = 0; i < n; ++i) {
        out_xy[2 * i] = kps[i].x;
        out_xy[2 * i + 1] = kps[i].y;
      }
    }
    if (out_desc != nullptr && desc.data.cols() == 128) {
      const int dn = static_cast<int>(desc.data.rows());
      const int m = n < dn ? n : dn;
      for (int i = 0; i < m; ++i) {
        for (int d = 0; d < 128; ++d) {
          out_desc[i * 128 + d] = desc.data(i, d);
        }
      }
    }
    if (out_count) *out_count = n;
    return 0;
  } catch (...) {
    return 5;
  }
}

// Same as aether_dsp_sift_extract, but the per-keypoint domain-size-pooling
// descriptor loop runs across `num_threads` worker threads (<=0 -> hardware
// concurrency). Output is BIT-IDENTICAL to aether_dsp_sift_extract.
int aether_dsp_sift_extract_threaded(const uint8_t* gray,
                                     int width,
                                     int height,
                                     int max_features,
                                     int num_threads,
                                     float* out_xy,
                                     uint8_t* out_desc,
                                     int out_cap,
                                     int* out_count) {
  if (out_count) *out_count = 0;
  try {
    if (gray == nullptr || width <= 0 || height <= 0 || out_cap <= 0) return 1;

    // [MIGRATION 4.0.4 / STEP 5] See above: 4.0.4 Bitmap has no FreeImage backing.
    colmap::Bitmap bitmap(width, height, /*as_rgb=*/false);
    bitmap.RowMajorData().assign(gray,
                                 gray + static_cast<size_t>(width) * height);

    // Default-constructed options match aether_dsp_sift_extract's defaults
    // (first_octave/octave_resolution/peak/edge/dsp_num_scales=10/L1_ROOT).
    colmap::SiftExtractionOptions sift;
    sift.max_num_features = max_features > 0 ? max_features : 8192;
    sift.estimate_affine_shape = true;   // DSP-SIFT (covariant) path
    sift.domain_size_pooling = true;

    colmap::FeatureKeypoints kps;
    colmap::FeatureDescriptors desc;
    if (!aether::ExtractCovariantSiftThreaded(
            sift, bitmap, &kps, &desc, num_threads)) {
      return 4;
    }

    int n = static_cast<int>(kps.size());
    if (n > out_cap) n = out_cap;
    if (out_xy != nullptr) {
      for (int i = 0; i < n; ++i) {
        out_xy[2 * i] = kps[i].x;
        out_xy[2 * i + 1] = kps[i].y;
      }
    }
    if (out_desc != nullptr && desc.data.cols() == 128) {
      const int dn = static_cast<int>(desc.data.rows());
      const int m = n < dn ? n : dn;
      for (int i = 0; i < m; ++i) {
        for (int d = 0; d < 128; ++d) {
          out_desc[i * 128 + d] = desc.data(i, d);
        }
      }
    }
    if (out_count) *out_count = n;
    return 0;
  } catch (...) {
    return 5;
  }
}

// Same as aether_dsp_sift_extract_threaded but with an explicit first_octave.
// Used by the GPU e2e parity gate: the GPU pipeline runs first_octave=0 (the
// validated M0/M1 baseline), so the apples-to-apples CPU reference must also use
// first_octave=0 (production default is -1, which adds a 2x-upsampled octave and
// ~2x the keypoints — a separate scope decision, not a descriptor difference).
int aether_dsp_sift_extract_threaded_fo(const uint8_t* gray, int width,
                                        int height, int max_features,
                                        int num_threads, int first_octave,
                                        float* out_xy, uint8_t* out_desc,
                                        int out_cap, int* out_count) {
  if (out_count) *out_count = 0;
  try {
    if (gray == nullptr || width <= 0 || height <= 0 || out_cap <= 0) return 1;
    colmap::Bitmap bitmap(width, height, /*as_rgb=*/false);
    bitmap.RowMajorData().assign(gray,
                                 gray + static_cast<size_t>(width) * height);
    colmap::SiftExtractionOptions sift;
    sift.max_num_features = max_features > 0 ? max_features : 8192;
    sift.first_octave = first_octave;
    sift.estimate_affine_shape = true;
    sift.domain_size_pooling = true;
    colmap::FeatureKeypoints kps;
    colmap::FeatureDescriptors desc;
    if (!aether::ExtractCovariantSiftThreaded(sift, bitmap, &kps, &desc,
                                              num_threads)) {
      return 4;
    }
    int n = static_cast<int>(kps.size());
    if (n > out_cap) n = out_cap;
    if (out_xy != nullptr)
      for (int i = 0; i < n; ++i) {
        out_xy[2 * i] = kps[i].x;
        out_xy[2 * i + 1] = kps[i].y;
      }
    if (out_desc != nullptr && desc.data.cols() == 128) {
      const int dn = static_cast<int>(desc.data.rows());
      const int m = n < dn ? n : dn;
      for (int i = 0; i < m; ++i)
        for (int d = 0; d < 128; ++d) out_desc[i * 128 + d] = desc.data(i, d);
    }
    if (out_count) *out_count = n;
    return 0;
  } catch (...) {
    return 5;
  }
}

// Validation harness: runs serial + threaded extraction on the SAME image and
// reports both keypoint counts + the max abs byte difference between the two
// descriptor sets. 0 == bit-identical (the correctness gate). Returns 0 on
// success, else the first non-zero extractor return code.
int aether_dsp_sift_selfcheck(const uint8_t* gray,
                              int width,
                              int height,
                              int max_features,
                              int num_threads,
                              int* out_n_serial,
                              int* out_n_threaded,
                              int* out_max_abs_desc_diff) {
  if (out_n_serial) *out_n_serial = 0;
  if (out_n_threaded) *out_n_threaded = 0;
  if (out_max_abs_desc_diff) *out_max_abs_desc_diff = -1;
  try {
    const int cap = (max_features > 0 ? max_features : 8192) + 8192;
    // 4-way diagnostic: serial x2 (base determinism) + threaded T=1 (clone
    // serial+descriptor logic, no threading) + threaded T=N (threading).
    auto extract = [&](int threads, std::vector<uint8_t>& d) -> int {
      std::vector<float> xy(static_cast<size_t>(2) * cap);
      int n = 0;
      const int r =
          (threads < 0)
              ? aether_dsp_sift_extract(
                    gray, width, height, max_features, xy.data(), d.data(), cap, &n)
              : aether_dsp_sift_extract_threaded(gray, width, height, max_features,
                                                 threads, xy.data(), d.data(), cap, &n);
      return r == 0 ? n : -r;
    };
    auto maxdiff = [](const std::vector<uint8_t>& a, int na,
                      const std::vector<uint8_t>& b, int nb) -> int {
      int md = 0;
      const int m = na < nb ? na : nb;
      for (size_t i = 0; i < static_cast<size_t>(m) * 128; ++i) {
        int diff = static_cast<int>(a[i]) - static_cast<int>(b[i]);
        if (diff < 0) diff = -diff;
        if (diff > md) md = diff;
      }
      return md;
    };
    std::vector<uint8_t> d_s1(static_cast<size_t>(128) * cap);
    std::vector<uint8_t> d_s2(static_cast<size_t>(128) * cap);
    std::vector<uint8_t> d_t1(static_cast<size_t>(128) * cap);
    std::vector<uint8_t> d_tn(static_cast<size_t>(128) * cap);
    const int n_s1 = extract(-1, d_s1);
    const int n_s2 = extract(-1, d_s2);
    const int n_t1 = extract(1, d_t1);
    const int n_tn = extract(num_threads > 0 ? num_threads : 4, d_tn);
    if (n_s1 < 0) return -n_s1;
    if (n_s2 < 0) return -n_s2;
    if (n_t1 < 0) return -n_t1;
    if (n_tn < 0) return -n_tn;
    const int md_ss = maxdiff(d_s1, n_s1, d_s2, n_s2);
    const int md_st1 = maxdiff(d_s1, n_s1, d_t1, n_t1);
    const int md_stn = maxdiff(d_s1, n_s1, d_tn, n_tn);
    std::printf(
        "SELFCHECK_DIAG n_s1=%d n_s2=%d n_t1=%d n_tn=%d | "
        "maxd(s,s)=%d maxd(s,t1)=%d maxd(s,tn)=%d\n",
        n_s1, n_s2, n_t1, n_tn, md_ss, md_st1, md_stn);
    std::fflush(stdout);
    if (out_n_serial) *out_n_serial = n_s1;
    if (out_n_threaded) *out_n_threaded = n_tn;
    if (out_max_abs_desc_diff) *out_max_abs_desc_diff = md_stn;
    return 0;
  } catch (...) {
    return 9;
  }
}

// Match two frames' RootSIFT descriptors with colmap's CPU brute-force matcher
// (SiftCPUFeatureMatcher, Eigen, no GPU) — UNMODIFIED. desc1/desc2 are 128*N
// uint8 (as produced by aether_dsp_sift_extract). *out_num_matches = #matches.
int aether_sift_match(const uint8_t* desc1,
                      int n1,
                      const uint8_t* desc2,
                      int n2,
                      double max_ratio,
                      int* out_num_matches) {
  if (out_num_matches) *out_num_matches = 0;
  try {
    if (desc1 == nullptr || desc2 == nullptr || n1 <= 0 || n2 <= 0) return 1;

    // [MIGRATION 4.0.4 / STEP 5] FeatureDescriptors is a struct now; the raw
    // matrix is `.data` and the matcher checks `.type == SIFT` (sift.cc:102).
    auto d1 = std::make_shared<colmap::FeatureDescriptors>();
    d1->type = colmap::FeatureExtractorType::SIFT;
    d1->data.resize(n1, 128);
    std::memcpy(d1->data.data(), desc1, static_cast<size_t>(n1) * 128);
    auto d2 = std::make_shared<colmap::FeatureDescriptors>();
    d2->type = colmap::FeatureExtractorType::SIFT;
    d2->data.resize(n2, 128);
    std::memcpy(d2->data.data(), desc2, static_cast<size_t>(n2) * 128);

    // [MIGRATION 4.0.4] FeatureMatcherType::SIFT was renamed to SIFT_BRUTEFORCE
    // (CreateSiftFeatureMatcher dispatches on it; cpu_brute_force_matcher=true +
    // use_gpu=false still selects the Eigen CPU brute-force path).
    colmap::FeatureMatchingOptions opts(
        colmap::FeatureMatcherType::SIFT_BRUTEFORCE);
    opts.sift = std::make_shared<colmap::SiftMatchingOptions>();
    opts.sift->max_ratio = max_ratio > 0 ? max_ratio : 0.7;
    opts.sift->cpu_brute_force_matcher = true;  // streaming: match-per-pair, no index
    opts.use_gpu = false;

    std::unique_ptr<colmap::FeatureMatcher> matcher =
        colmap::CreateSiftFeatureMatcher(opts);
    if (!matcher) return 3;

    colmap::FeatureMatcher::Image img1;
    img1.image_id = 1;
    img1.descriptors = d1;
    colmap::FeatureMatcher::Image img2;
    img2.image_id = 2;
    img2.descriptors = d2;

    colmap::FeatureMatches matches;
    matcher->Match(img1, img2, &matches);
    if (out_num_matches) *out_num_matches = static_cast<int>(matches.size());
    return 0;
  } catch (...) {
    return 2;
  }
}

}  // extern "C"
