// aether_threaded_extract.h — multi-threaded DSP-SIFT extraction.
//
// Threaded equivalent of colmap::CovariantSiftCPUFeatureExtractor::Extract:
// the serial detect / affine-shape / orientation / sort / keypoint-copy stages
// are identical to upstream, and only the per-keypoint domain-size-pooling
// DESCRIPTOR loop is parallelized across a thread pool. Each worker borrows the
// master's READ-ONLY Gaussian scale space (vl_covdet_set_gss) and owns private
// patch / sift scratch, so the output is BIT-IDENTICAL to the serial path
// (each descriptor row is computed independently; no cross-row reduction).
//
// Upstream colmap/feature/sift.cc is NOT modified. The only VLFeat addition is
// the non-computational vl_covdet_set_gss accessor.
#pragma once

#include "colmap/feature/sift.h"
#include "colmap/feature/types.h"
#include "colmap/sensor/bitmap.h"

namespace aether {

// num_threads <= 0  -> std::thread::hardware_concurrency().
// Returns false only on allocation failure (mirrors the upstream extractor).
bool ExtractCovariantSiftThreaded(const colmap::SiftExtractionOptions& sift_opts,
                                  const colmap::Bitmap& bitmap,
                                  colmap::FeatureKeypoints* keypoints,
                                  colmap::FeatureDescriptors* descriptors,
                                  int num_threads);

}  // namespace aether
