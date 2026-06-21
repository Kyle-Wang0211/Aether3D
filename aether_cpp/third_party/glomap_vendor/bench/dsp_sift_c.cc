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

#include <cstdint>
#include <cstring>
#include <memory>

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

    colmap::Bitmap bitmap;
    bitmap.Allocate(width, height, /*as_rgb=*/false);
    FIBITMAP* fib = bitmap.Data();
    if (fib == nullptr) return 2;
    fib->data.assign(gray, gray + static_cast<size_t>(width) * height);

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
    if (out_desc != nullptr && desc.cols() == 128) {
      const int dn = static_cast<int>(desc.rows());
      const int m = n < dn ? n : dn;
      for (int i = 0; i < m; ++i) {
        for (int d = 0; d < 128; ++d) {
          out_desc[i * 128 + d] = desc(i, d);
        }
      }
    }
    if (out_count) *out_count = n;
    return 0;
  } catch (...) {
    return 5;
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

    auto d1 = std::make_shared<colmap::FeatureDescriptors>(n1, 128);
    std::memcpy(d1->data(), desc1, static_cast<size_t>(n1) * 128);
    auto d2 = std::make_shared<colmap::FeatureDescriptors>(n2, 128);
    std::memcpy(d2->data(), desc2, static_cast<size_t>(n2) * 128);

    colmap::FeatureMatchingOptions opts(colmap::FeatureMatcherType::SIFT);
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
