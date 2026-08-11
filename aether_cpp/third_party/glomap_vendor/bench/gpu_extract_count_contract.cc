#include <algorithm>
#include <cmath>
#include <cstdint>
#include <cstdlib>
#include <cstring>
#include <cstdio>
#include <vector>

#include "sift_extract_dawn.h"

extern "C" {
int aether_dsp_sift_extract_gpu(const uint8_t*, int, int, int, int, float*,
                                uint8_t*, int, int*);
int aether_dsp_sift_extract_threaded_fo(const uint8_t*, int, int, int, int, int,
                                        float*, uint8_t*, int, int*);
void aether_sed_last_stages(double*, int);
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

uint64_t Fnv1a64(const void* data, size_t size, uint64_t digest) {
  const auto* bytes = static_cast<const uint8_t*>(data);
  for (size_t i = 0; i < size; ++i) {
    digest ^= bytes[i];
    digest *= 1099511628211ull;
  }
  return digest;
}

uint64_t OutputDigest(int count, const std::vector<float>& xy,
                      const std::vector<uint8_t>& desc) {
  uint64_t digest = 14695981039346656037ull;
  digest = Fnv1a64(&count, sizeof(count), digest);
  digest = Fnv1a64(xy.data(), static_cast<size_t>(count) * 2 * sizeof(float),
                   digest);
  return Fnv1a64(desc.data(), static_cast<size_t>(count) * 128, digest);
}

bool HasGpuStageEvidence() {
  double stages[9] = {0.0};
  aether_sed_last_stages(stages, 9);
  for (double stage : stages) {
    if (stage > 0.0) return true;
  }
  return false;
}

bool ResultResetContract() {
  aether::tools::DawnKernelHarness harness;
  aether::tools::SiftExtractDawn extractor;
  aether::tools::SiftExtractDawn::Result result;
  result.xy = {1.0f, 2.0f};
  result.octave = {3};
  result.scale = {4};
  result.raw_desc = {5.0f};
  result.stable_ids = {6u};
  result.count = 1;
  const bool success =
      extractor.extract(harness, nullptr, 0, 0, 8192, &result);
  return !success && result.xy.empty() && result.octave.empty() &&
         result.scale.empty() && result.raw_desc.empty() &&
         result.stable_ids.empty() && result.count == 0;
}

}  // namespace

int main() {
  constexpr int kWidth = 2400;
  constexpr int kHeight = 1800;
  constexpr int kMaxFeatures = 8192;
  constexpr int kOutputCapacity = 40000;

  if (!ResultResetContract()) {
    std::fprintf(stderr, "FAIL: extractor Result reset contract\n");
    return 1;
  }

  const std::vector<uint8_t> gray = MakeSynthetic(kWidth, kHeight);
  std::vector<float> gpu_xy(2 * kOutputCapacity);
  std::vector<float> cpu_xy(2 * kOutputCapacity);
  std::vector<uint8_t> gpu_desc(static_cast<size_t>(128) * kOutputCapacity);
  std::vector<uint8_t> cpu_desc(static_cast<size_t>(128) * kOutputCapacity);
  int gpu_count = 0;
  int cpu_count = 0;

  // The stage stash is the existing route witness: the GPU wrapper clears it
  // before delegating to CPU fallback. Enabling host stage observation in this
  // diagnostic fixture therefore prevents a fallback result from being
  // mislabeled as a successful GPU canonical/legacy measurement.
  setenv("SED_TIMING", "1", 1);

  const int gpu_rc = aether_dsp_sift_extract_gpu(
      gray.data(), kWidth, kHeight, kMaxFeatures, 0, gpu_xy.data(),
      gpu_desc.data(), kOutputCapacity, &gpu_count);
  const int cpu_rc = aether_dsp_sift_extract_threaded_fo(
      gray.data(), kWidth, kHeight, kMaxFeatures, 0, 0, cpu_xy.data(),
      cpu_desc.data(), kOutputCapacity, &cpu_count);

  const char* policy = std::getenv("AETHER_FEATURE_SELECTION_POLICY");
  if (policy == nullptr) policy = "<absent>";
  const bool used_gpu = HasGpuStageEvidence();
  const uint64_t gpu_digest = OutputDigest(gpu_count, gpu_xy, gpu_desc);
  const uint64_t cpu_digest = OutputDigest(cpu_count, cpu_xy, cpu_desc);

  std::printf(
      "[gpu_extract_count_contract] policy=%s route=%s GPU rc=%d count=%d "
      "digest=%016llx CPU rc=%d count=%d digest=%016llx\n",
      policy, used_gpu ? "gpu" : "cpu_fallback", gpu_rc, gpu_count,
      static_cast<unsigned long long>(gpu_digest), cpu_rc, cpu_count,
      static_cast<unsigned long long>(cpu_digest));
  if (!used_gpu) return 77;
  if (gpu_rc != 0 || cpu_rc != 0) return 1;

  const bool canonical =
      std::strcmp(policy, "canonical_exact_8192_v1") == 0;
  const int expected_gpu_count = canonical ? 8192 : 16570;
  if (gpu_count != expected_gpu_count) {
    std::fprintf(stderr,
                 "FAIL: GPU route count=%d expected=%d for policy=%s\n",
                 gpu_count, expected_gpu_count, policy);
    return 1;
  }
  return 0;
}
