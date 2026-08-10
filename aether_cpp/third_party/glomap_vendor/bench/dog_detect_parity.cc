// dog_detect_parity.cc — GPU vs CPU octave-0 keypoint parity gate (M1 Stage B).
//
// GPU side: tools/sift_pyramid_dawn builds the fo=0 GSS (RESIDENT), then the
// sift_dog_detect.wgsl pass does S2 DoG + S3 extrema/Newton-refine/cull and
// atomic-collects octave-0 keypoints (GPU_DSP_SIFT_PLAN_AFFINE_OFF.md §2-S2/S3).
//
// CPU reference: VLFeat vl_covdet (VL_COVDET_METHOD_DOG) with first_octave = 0
// and the SAME peak/edge thresholds, run to vl_covdet_detect ONLY — i.e. the
// PRE-AFFINE keypoints (before vl_covdet_extract_affine_shape, which would nudge
// positions). We filter the CPU feature set to o == 0 so it's apples-to-apples
// with the GPU octave-0 detector. This is exactly the comparison stage B
// specifies (CPU "affine前" octave-0 keypoints).
//
// Matching: greedy nearest-neighbour by (x,y) within kPosTol px. A GPU kp and a
// CPU kp also must share the rounded sublevel s (same DoG plane). recall =
// matched / n_cpu, precision = matched / n_gpu, plus median |Δpos|.
//
// Gate B (GPU_DSP_SIFT_PLAN_AFFINE_OFF.md §2-S3): recall>=0.97, precision>=0.97,
// median pos-err <= 0.05px.
//
// Build target: dog_detect_parity_exe. Run: ./dog_detect_parity_exe [image.jpg]

#include <algorithm>
#include <cmath>
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <string>
#include <vector>

#define STB_IMAGE_IMPLEMENTATION
#include "stb_image.h"

#include "sift_pyramid_dawn.h"

extern "C" {
#include "covdet.h"
#include "scalespace.h"
}

namespace {

using aether::tools::DawnKernelHarness;
using aether::tools::SiftPyramidDawn;

std::string load_wgsl(const char* filename) {
  const std::string path = std::string(AETHER_WGSL_DIR) + "/" + filename;
  FILE* f = std::fopen(path.c_str(), "rb");
  if (!f) { std::fprintf(stderr, "cannot open WGSL: %s\n", path.c_str()); std::abort(); }
  std::fseek(f, 0, SEEK_END); long sz = std::ftell(f); std::fseek(f, 0, SEEK_SET);
  std::string out(static_cast<size_t>(sz), '\0');
  size_t rd = std::fread(out.data(), 1, static_cast<size_t>(sz), f);
  std::fclose(f); out.resize(rd); return out;
}

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

struct Kp { float x, y, sigma, peak, edge; int o, s; };

// KpRecord stride in u32 words, must match sift_dog_detect.wgsl KP_STRIDE.
constexpr uint32_t kKpStride = 8u;
// Full fo=0 pyramid (all octaves) can exceed the per-image budget; the densest
// synthetic fixture detects ~28k pre-suppression. Size the GPU collection buffer
// well above that so the cap guard never trips during parity.
constexpr uint32_t kCap = 48000u;

// ─── Host f32 reference detector (diagnostic) ───
// Re-implements VLFeat's DOG extrema/refine/cull in float<T> on the GPU's own
// GSS levels, so we can A/B "is the GPU-vs-CPU gap a f32-vs-f64 precision
// effect?". Templated on the compute type: run with double → must match VLFeat
// near-exactly; run with float → models the GPU. Levels[k] is gss s=k-1, k=0..5,
// each W*H. Returns kp count (counts only, position list optional).
// Non-extrema suppression (covdet.c:2104, default tol=0.5). Mutates `kps`:
// zeros the peakScore of any feature dominated by a stronger nearby same-scale
// one, then compacts. O(N^2); fine for diagnostics. Operates in image coords.
void nonextrema_suppress(std::vector<Kp>& kps, double tol) {
  const int n = static_cast<int>(kps.size());
  std::vector<double> score(n);
  for (int i = 0; i < n; ++i) score[i] = kps[i].peak;
  for (int i = 0; i < n; ++i) {
    if (score[i] == 0.0) continue;
    const double x = kps[i].x, y = kps[i].y, sigma = kps[i].sigma, sc = score[i];
    for (int j = 0; j < n; ++j) {
      if (score[j] == 0.0) continue;
      const double dx = kps[j].x - x, dy = kps[j].y - y, sigma_ = kps[j].sigma, sc_ = score[j];
      if (sigma < (1 + tol) * sigma_ && sigma_ < (1 + tol) * sigma &&
          std::abs(dx) < tol * sigma && std::abs(dy) < tol * sigma &&
          std::abs(sc) > std::abs(sc_)) {
        score[j] = 0.0;
      }
    }
  }
  std::vector<Kp> out;
  for (int i = 0; i < n; ++i) if (score[i] != 0.0) out.push_back(kps[i]);
  kps.swap(out);
}

// PARALLEL ("simultaneous") suppression — the semantics the GPU pass uses. Each
// j checks all i using ORIGINAL scores (no sequential zeroing of suppressors).
// Mirrors sift_nonextrema_suppress.wgsl exactly so the host can A/B GPU output.
void nonextrema_suppress_parallel(std::vector<Kp>& kps, double tol) {
  const int n = static_cast<int>(kps.size());
  std::vector<char> keep(n, 1);
  for (int j = 0; j < n; ++j) {
    const double xj = kps[j].x, yj = kps[j].y, sj = kps[j].sigma, scj = std::abs((double)kps[j].peak);
    for (int i = 0; i < n; ++i) {
      if (i == j) continue;
      const double si = kps[i].sigma, sci = std::abs((double)kps[i].peak);
      if (sj < (1 + tol) * si && si < (1 + tol) * sj &&
          std::abs(kps[i].x - xj) < tol * si && std::abs(kps[i].y - yj) < tol * si &&
          sci > scj) { keep[j] = 0; break; }
    }
  }
  std::vector<Kp> out;
  for (int i = 0; i < n; ++i) if (keep[i]) out.push_back(kps[i]);
  kps.swap(out);
}

template <typename T>
int cpu_ref_detect(const std::vector<std::vector<float>>& levels, int W, int H,
                   double peakThreshold, double edgeThreshold, double baseScale,
                   int octRes, int* by_s_out, std::vector<Kp>* kp_out = nullptr) {
  auto gss_at = [&](int lvl, int x, int y) -> T {
    int cx = std::max(0, std::min(x, W - 1));
    int cy = std::max(0, std::min(y, H - 1));
    return static_cast<T>(levels[static_cast<size_t>(lvl)][static_cast<size_t>(cy) * W + cx]);
  };
  auto dog_at = [&](int z, int x, int y) -> T { return gss_at(z, x, y) - gss_at(z + 1, x, y); };
  const int depth = 5;
  const T t08 = static_cast<T>(0.8 * peakThreshold);
  int count = 0;
  if (by_s_out) for (int i = 0; i < 8; ++i) by_s_out[i] = 0;

  for (int z = 1; z <= depth - 2; ++z) {
    for (int y0 = 1; y0 < H - 1; ++y0) {
      for (int x0 = 1; x0 < W - 1; ++x0) {
        T v = dog_at(z, x0, y0);
        bool is_max = (v >= t08), is_min = (v <= -t08);
        if (!(is_max || is_min)) continue;
        for (int dz = -1; dz <= 1 && (is_max || is_min); ++dz)
          for (int dy = -1; dy <= 1; ++dy)
            for (int dx = -1; dx <= 1; ++dx) {
              if (!dx && !dy && !dz) continue;
              T nv = dog_at(z + dz, x0 + dx, y0 + dy);
              if (!(v > nv)) is_max = false;
              if (!(v < nv)) is_min = false;
            }
        if (!(is_max || is_min)) continue;

        // Newton refine (T precision).
        int x = x0, y = y0, dxc = 0, dyc = 0;
        T b[3] = {0, 0, 0}, Dx = 0, Dy = 0, Dz = 0;
        bool ok_solve = true;
        for (int it = 0; it < 5; ++it) {
          x += dxc; y += dyc;
          T c = dog_at(z, x, y);
          T xp = dog_at(z, x + 1, y), xm = dog_at(z, x - 1, y);
          T yp = dog_at(z, x, y + 1), ym = dog_at(z, x, y - 1);
          T zp = dog_at(z + 1, x, y), zm = dog_at(z - 1, x, y);
          Dx = static_cast<T>(0.5) * (xp - xm);
          Dy = static_cast<T>(0.5) * (yp - ym);
          Dz = static_cast<T>(0.5) * (zp - zm);
          T Dxx = xp + xm - static_cast<T>(2) * c;
          T Dyy = yp + ym - static_cast<T>(2) * c;
          T Dzz = zp + zm - static_cast<T>(2) * c;
          T Dxy = static_cast<T>(0.25) * (dog_at(z, x + 1, y + 1) + dog_at(z, x - 1, y - 1)
                  - dog_at(z, x - 1, y + 1) - dog_at(z, x + 1, y - 1));
          T Dxz = static_cast<T>(0.25) * (dog_at(z + 1, x + 1, y) + dog_at(z - 1, x - 1, y)
                  - dog_at(z + 1, x - 1, y) - dog_at(z - 1, x + 1, y));
          T Dyz = static_cast<T>(0.25) * (dog_at(z + 1, x, y + 1) + dog_at(z - 1, x, y - 1)
                  - dog_at(z + 1, x, y - 1) - dog_at(z - 1, x, y + 1));
          // 3x3 solve (Gaussian elim, partial pivot), VLFeat Aat(i,j)=A[i+j*3].
          T M[12];
          M[0] = Dxx; M[1] = Dxy; M[2] = Dxz;
          M[3] = Dxy; M[4] = Dyy; M[5] = Dyz;
          M[6] = Dxz; M[7] = Dyz; M[8] = Dzz;
          M[9] = -Dx; M[10] = -Dy; M[11] = -Dz;
          ok_solve = true;
          for (int j = 0; j < 3; ++j) {
            T maxa = 0, maxabsa = 0; int maxi = -1;
            for (int i = j; i < 3; ++i) { T a = M[i + j * 3], aa = std::abs(a);
              if (aa > maxabsa) { maxa = a; maxabsa = aa; maxi = i; } }
            if (maxabsa < static_cast<T>(1e-10)) { ok_solve = false; break; }
            int ip = maxi;
            for (int jj = j; jj < 4; ++jj) { T tmp = M[ip + jj * 3];
              M[ip + jj * 3] = M[j + jj * 3]; M[j + jj * 3] = tmp; M[j + jj * 3] /= maxa; }
            for (int ii = j + 1; ii < 3; ++ii) { T xx = M[ii + j * 3];
              for (int jj = j; jj < 4; ++jj) M[ii + jj * 3] -= xx * M[j + jj * 3]; }
          }
          if (!ok_solve) { b[0] = b[1] = b[2] = 0; break; }
          for (int i = 2; i > 0; --i)
            for (int ii = i - 1; ii >= 0; --ii) { T xx = M[ii + i * 3];
              for (int jc = 3; jc < 4; ++jc) M[ii + jc * 3] -= xx * M[i + jc * 3]; }
          b[0] = M[9]; b[1] = M[10]; b[2] = M[11];
          dxc = 0; dyc = 0;
          if (b[0] > static_cast<T>(0.6) && x < W - 2) dxc = 1;
          if (b[0] < static_cast<T>(-0.6) && x > 1) dxc = -1;
          if (b[1] > static_cast<T>(0.6) && y < H - 2) dyc += 1;
          if (b[1] < static_cast<T>(-0.6) && y > 1) dyc -= 1;
          if (!dxc && !dyc) break;
        }
        T c2 = dog_at(z, x, y);
        T xp2 = dog_at(z, x + 1, y), xm2 = dog_at(z, x - 1, y);
        T yp2 = dog_at(z, x, y + 1), ym2 = dog_at(z, x, y - 1);
        T Dxx2 = xp2 + xm2 - static_cast<T>(2) * c2;
        T Dyy2 = yp2 + ym2 - static_cast<T>(2) * c2;
        T Dxy2 = static_cast<T>(0.25) * (dog_at(z, x + 1, y + 1) + dog_at(z, x - 1, y - 1)
                 - dog_at(z, x - 1, y + 1) - dog_at(z, x + 1, y - 1));
        T peakScore = c2 + static_cast<T>(0.5) * (Dx * b[0] + Dy * b[1] + Dz * b[2]);
        T denom = Dxx2 * Dyy2 - Dxy2 * Dxy2;
        T alpha = (Dxx2 + Dyy2) * (Dxx2 + Dyy2) / denom;
        T edgeScore = (alpha < 0) ? static_cast<T>(1e30)
            : (static_cast<T>(0.5) * alpha - static_cast<T>(1))
              + std::sqrt(std::max(static_cast<T>(0.25) * alpha - static_cast<T>(1), static_cast<T>(0)) * alpha);
        T rx = static_cast<T>(x) + b[0], ry = static_cast<T>(y) + b[1], rz = static_cast<T>(z) + b[2];
        bool stable = ok_solve && std::abs(b[0]) < 1.5 && std::abs(b[1]) < 1.5 && std::abs(b[2]) < 1.5
            && rx >= 0 && rx <= W - 1 && ry >= 0 && ry <= H - 1 && rz >= 0 && rz <= depth - 1;
        bool keep = stable && std::abs(peakScore) > static_cast<T>(peakThreshold)
            && edgeScore < static_cast<T>(edgeThreshold);
        if (keep) {
          ++count;
          int s_round = static_cast<int>(std::lround(static_cast<double>(rz)));
          if (by_s_out && s_round + 1 >= 0 && s_round + 1 < 8) ++by_s_out[s_round + 1];
          if (kp_out) {
            Kp k;
            const double step = 1.0;  // octave 0
            k.x = static_cast<float>(static_cast<double>(rx) * step);
            k.y = static_cast<float>(static_cast<double>(ry) * step);
            // VLFeat sigma uses CONTINUOUS refined.z: baseScale*2^((z-1)/octRes).
            k.sigma = static_cast<float>(baseScale *
                std::pow(2.0, (static_cast<double>(rz) + (-1.0)) / octRes));
            k.peak = static_cast<float>(peakScore);
            k.edge = static_cast<float>(edgeScore);
            k.o = 0; k.s = s_round;
            kp_out->push_back(k);
          }
        }
      }
    }
  }
  return count;
}

}  // namespace

int main(int argc, char** argv) {
  int W = 0, H = 0;
  std::vector<uint8_t> gray;
  std::string source;
  if (argc > 1) {
    int ch = 0;
    uint8_t* d = stbi_load(argv[1], &W, &H, &ch, 1);
    if (!d) { std::fprintf(stderr, "stbi_load failed: %s\n", stbi_failure_reason()); return 2; }
    gray.assign(d, d + static_cast<size_t>(W) * H);
    stbi_image_free(d);
    source = argv[1];
  } else {
    W = 2400; H = 1800; gray = make_synthetic(W, H); source = "synthetic 2400x1800";
  }
  std::printf("[dog_detect_parity] fixture: %s (%dx%d)\n", source.c_str(), W, H);

  // ── default detector thresholds (colmap/feature/sift.h) ──
  const int kOctaveResolution = SiftPyramidDawn::kOctaveResolution;  // 3
  const double kPeakThreshold = 0.02 / kOctaveResolution;
  const double kEdgeThreshold = 10.0;

  // ── GPU: pyramid + detect ──
  DawnKernelHarness harness;
  if (!harness.init()) { std::fprintf(stderr, "Dawn init failed\n"); return 2; }
  SiftPyramidDawn gpu;
  if (!gpu.build(harness, gray.data(), W, H)) { std::fprintf(stderr, "pyramid build failed\n"); return 2; }

  // ── shared keypoint collection (atomic append accumulates across octaves) ──
  uint32_t zero = 0u;
  wgpu::Buffer kp_counter = harness.upload(&zero, sizeof(zero),
      wgpu::BufferUsage::Storage | wgpu::BufferUsage::CopySrc);
  std::vector<uint32_t> kp_init(static_cast<size_t>(kCap) * kKpStride, 0u);
  wgpu::Buffer kp_buffer = harness.upload(kp_init.data(), kp_init.size() * sizeof(uint32_t),
      wgpu::BufferUsage::Storage | wgpu::BufferUsage::CopySrc);

  struct Params {
    uint32_t width, height, cap, octave;
    float peak_threshold, edge_threshold, base_scale, oct_resolution;
    // [PACK-ZERO 2026-08-10] packed 大缓冲内本 octave 6 层偏移(生产同款)。
  uint32_t off[6];
  uint32_t _pad0, _pad1;
};
  wgpu::ComputePipeline pipe = harness.load_compute(load_wgsl("sift_dog_detect.wgsl"));

  // ── Stage B+: run the (octave-agnostic) detect kernel over EVERY octave of
  //    the fo=0 pyramid. Each octave binds its own 6 GSS levels; the kernel
  //    already converts octave-local coords → image frame via step=2^octave and
  //    sigma=baseScale*2^(octave + (s-1)/octRes). All octaves append into the
  //    single shared kp_buffer (atomicAdd on kp_counter spans dispatches). ──
  for (int o = gpu.first_octave(); o <= gpu.last_octave(); ++o) {
    const int ow = gpu.octave_width(o);
    const int oh = gpu.octave_height(o);
    if (ow < 3 || oh < 3) continue;  // too small for a 3x3x3 extremum interior

    Params P{ static_cast<uint32_t>(ow), static_cast<uint32_t>(oh), kCap,
              static_cast<uint32_t>(o),
              static_cast<float>(kPeakThreshold), static_cast<float>(kEdgeThreshold),
              static_cast<float>(SiftPyramidDawn::base_scale()),
              static_cast<float>(kOctaveResolution),
              {0,0,0,0,0,0}, 0, 0 };
    for (int s = SiftPyramidDawn::kOctaveFirstSub; s <= SiftPyramidDawn::kOctaveLastSub; ++s)
      P.off[s - SiftPyramidDawn::kOctaveFirstSub] = gpu.level_offset(o, s);
    wgpu::Buffer p_buf = harness.upload(&P, sizeof(P), wgpu::BufferUsage::Uniform);

    std::vector<wgpu::Buffer> bind;
    bind.push_back(gpu.packed_buffer());
    bind.push_back(kp_counter);
    bind.push_back(kp_buffer);
    bind.push_back(p_buf);

    const uint32_t wgx = static_cast<uint32_t>((ow + 7) / 8);
    const uint32_t wgy = static_cast<uint32_t>((oh + 7) / 8);
    harness.dispatch(pipe, bind, wgx, wgy, 3u);
  }
  // octave-0 dims for the diagnostics/border checks below.
  const int ow = gpu.octave_width(0);
  const int oh = gpu.octave_height(0);

  // read back counter + records
  auto read_u32 = [&](const wgpu::Buffer& b, size_t n) {
    const size_t bytes = n * sizeof(uint32_t);
    wgpu::Buffer st = harness.alloc_staging_for_readback(bytes);
    harness.copy_to_staging(b, st, bytes);
    std::vector<uint8_t> raw = harness.readback(st, bytes);
    std::vector<uint32_t> out(n);
    std::memcpy(out.data(), raw.data(), bytes);
    return out;
  };
  uint32_t gpu_count = read_u32(kp_counter, 1)[0];
  const uint32_t n_gpu_stored = std::min(gpu_count, kCap);
  std::vector<uint32_t> recs = read_u32(kp_buffer, static_cast<size_t>(n_gpu_stored) * kKpStride);

  std::vector<Kp> gpu_kp;
  gpu_kp.reserve(n_gpu_stored);
  for (uint32_t i = 0; i < n_gpu_stored; ++i) {
    const uint32_t* r = recs.data() + static_cast<size_t>(i) * kKpStride;
    Kp k;
    std::memcpy(&k.x, &r[0], 4); std::memcpy(&k.y, &r[1], 4);
    std::memcpy(&k.sigma, &r[2], 4); std::memcpy(&k.peak, &r[3], 4);
    std::memcpy(&k.edge, &r[4], 4);
    std::memcpy(&k.o, &r[5], 4); std::memcpy(&k.s, &r[6], 4);
    gpu_kp.push_back(k);
  }

  // ── Stage B++: GPU global non-extrema suppression (env-gated) ──
  // When DOG_PARITY_SUPPRESS is set, run sift_nonextrema_suppress.wgsl on the
  // unified keypoint buffer, read back the keep flags, and drop suppressed GPU
  // keypoints. The CPU reference below then re-enables VLFeat's suppression so
  // both sides are post-suppression.
  const bool kSuppress = std::getenv("DOG_PARITY_SUPPRESS") != nullptr;
  if (kSuppress && n_gpu_stored > 0) {
    std::vector<uint32_t> keep_init(n_gpu_stored, 1u);
    wgpu::Buffer keep_buf = harness.upload(keep_init.data(), keep_init.size() * sizeof(uint32_t),
        wgpu::BufferUsage::Storage | wgpu::BufferUsage::CopySrc);
    struct SupParams { uint32_t count; float tol; } sp{ n_gpu_stored, 0.5f };
    wgpu::Buffer sp_buf = harness.upload(&sp, sizeof(sp), wgpu::BufferUsage::Uniform);
    wgpu::ComputePipeline pipe_sup =
        harness.load_compute(load_wgsl("sift_nonextrema_suppress.wgsl"));
    const uint32_t sup_groups = (n_gpu_stored + 63u) / 64u;
    harness.dispatch(pipe_sup, {kp_buffer, keep_buf, sp_buf}, sup_groups);
    std::vector<uint32_t> keep = read_u32(keep_buf, n_gpu_stored);
    std::vector<Kp> kept;
    for (uint32_t i = 0; i < n_gpu_stored; ++i) if (keep[i]) kept.push_back(gpu_kp[i]);
    std::printf("[dog_detect_parity] B++ GPU suppression: %u -> %zu kept\n",
                n_gpu_stored, kept.size());
    gpu_kp.swap(kept);
  }

  // ── CPU reference: VLFeat covdet, first_octave=0, PRE-affine, ALL octaves ──
  std::vector<float> gray_f(static_cast<size_t>(W) * H);
  for (size_t i = 0; i < gray_f.size(); ++i) gray_f[i] = static_cast<float>(gray[i]) / 255.0f;

  VlCovDet* cov = vl_covdet_new(VL_COVDET_METHOD_DOG);
  vl_covdet_set_first_octave(cov, 0);
  vl_covdet_set_octave_resolution(cov, kOctaveResolution);
  vl_covdet_set_peak_threshold(cov, kPeakThreshold);
  vl_covdet_set_edge_threshold(cov, kEdgeThreshold);
  // Stage B+ (default) validates the full-pyramid DETECTION math in isolation:
  // suppression DISABLED on both sides. Stage B++ (DOG_PARITY_SUPPRESS) runs the
  // GPU suppression pass above and re-enables VLFeat's suppression here so both
  // sides are post-suppression.
  vl_covdet_set_non_extrema_suppression_threshold(cov, kSuppress ? 0.5 : 0.0);
  vl_covdet_put_image(cov, gray_f.data(), W, H);
  // Large budget so the CPU detect does NOT early-break (covdet.c:2086 stops once
  // numFeatures >= max_num_features). The GPU detector runs every octave with a
  // large CAP, so the apples-to-apples CPU reference must detect the full set.
  vl_covdet_detect(cov, 1u << 28);
  const int nf = static_cast<int>(vl_covdet_get_num_features(cov));
  VlCovDetFeature* feats = vl_covdet_get_features(cov);

  std::vector<Kp> cpu_kp;
  for (int i = 0; i < nf; ++i) {
    Kp k;
    k.x = static_cast<float>(feats[i].frame.x);
    k.y = static_cast<float>(feats[i].frame.y);
    k.sigma = static_cast<float>(feats[i].frame.a11);
    k.peak = feats[i].peakScore;
    k.edge = feats[i].edgeScore;
    k.o = feats[i].o; k.s = feats[i].s;
    cpu_kp.push_back(k);
  }

  std::printf("[dog_detect_parity] GPU all-octave kp=%u (counter=%u)  CPU all-octave kp=%zu\n",
              n_gpu_stored, gpu_count, cpu_kp.size());

  // Histogram both sides by OCTAVE to expose any per-octave count mismatch.
  {
    int go[16] = {0}, co[16] = {0};
    for (const Kp& k : gpu_kp) { if (k.o >= 0 && k.o < 16) ++go[k.o]; }
    for (const Kp& k : cpu_kp) { if (k.o >= 0 && k.o < 16) ++co[k.o]; }
    std::printf("[dog_detect_parity] by-octave GPU:");
    for (int o = 0; o < 10; ++o) if (go[o] || co[o]) std::printf(" o%d=%d", o, go[o]);
    std::printf("\n[dog_detect_parity] by-octave CPU:");
    for (int o = 0; o < 10; ++o) if (go[o] || co[o]) std::printf(" o%d=%d", o, co[o]);
    std::printf("\n");
    int gs[8] = {0}, cs[8] = {0};
    for (const Kp& k : gpu_kp) { int i = k.s + 1; if (i >= 0 && i < 8) ++gs[i]; }
    for (const Kp& k : cpu_kp) { int i = k.s + 1; if (i >= 0 && i < 8) ++cs[i]; }
    std::printf("[dog_detect_parity] by-s GPU [s-1..4]: [%d %d %d %d %d %d]\n",
                gs[0], gs[1], gs[2], gs[3], gs[4], gs[5]);
    std::printf("[dog_detect_parity] by-s CPU [s-1..4]: [%d %d %d %d %d %d]\n",
                cs[0], cs[1], cs[2], cs[3], cs[4], cs[5]);
  }

  // ── greedy NN match by image-frame position, same (octave, rounded sublevel).
  //    Position tol is scaled by the octave step (2^o): a true match at a coarse
  //    octave is still sub-pixel in THAT octave's grid, which is 2^o image px. ──
  const double kPosTolBase = 0.75;  // px in octave-local grid
  std::vector<char> gpu_used(gpu_kp.size(), 0);
  std::vector<double> match_err;
  int matched = 0;
  for (const Kp& c : cpu_kp) {
    const double tol = kPosTolBase * std::pow(2.0, c.o);
    int best = -1; double best_d2 = tol * tol;
    for (size_t j = 0; j < gpu_kp.size(); ++j) {
      if (gpu_used[j]) continue;
      if (gpu_kp[j].s != c.s || gpu_kp[j].o != c.o) continue;
      const double dx = gpu_kp[j].x - c.x, dy = gpu_kp[j].y - c.y;
      const double d2 = dx * dx + dy * dy;
      if (d2 <= best_d2) { best_d2 = d2; best = static_cast<int>(j); }
    }
    if (best >= 0) {
      gpu_used[best] = 1; ++matched;
      // report error in octave-local px (divide by step) so median is comparable
      match_err.push_back(std::sqrt(best_d2) / std::pow(2.0, c.o));
    }
  }

  double median_err = 0.0;
  if (!match_err.empty()) {
    std::sort(match_err.begin(), match_err.end());
    median_err = match_err[match_err.size() / 2];
  }
  const double recall = cpu_kp.empty() ? 0.0 : static_cast<double>(matched) / cpu_kp.size();
  const double precision = gpu_kp.empty() ? 0.0 : static_cast<double>(matched) / gpu_kp.size();

  std::printf("[dog_detect_parity] matched=%d  recall=%.4f  precision=%.4f  median_pos_err=%.4f px\n",
              matched, recall, precision, median_err);

  // Diagnostic: characterize the UNMATCHED GPU keypoints (false positives). If
  // they cluster near the peak/edge cull boundary, the precision gap is f32-vs-
  // f64 round-off at the threshold (a numeric margin, not a logic bug).
  {
    const double pt = kPeakThreshold;
    int near_peak = 0, near_edge = 0, far = 0, total_unmatched = 0;
    double max_abs_margin = 0.0;
    for (size_t j = 0; j < gpu_kp.size(); ++j) {
      if (gpu_used[j]) continue;
      ++total_unmatched;
      const double peak_margin = std::abs(std::abs(static_cast<double>(gpu_kp[j].peak)) - pt);
      const double edge_margin = std::abs(static_cast<double>(gpu_kp[j].edge) - kEdgeThreshold);
      const double rel_peak = peak_margin / pt;
      if (rel_peak < 0.01) ++near_peak;
      else if (edge_margin < 0.05) ++near_edge;
      else { ++far; if (rel_peak > max_abs_margin) max_abs_margin = rel_peak; }
    }
    std::printf("[dog_detect_parity] FP diag: unmatched=%d  near_peak_thresh(<1%%)=%d "
                "near_edge_thresh=%d  far=%d (worst far rel_peak_margin=%.4f)\n",
                total_unmatched, near_peak, near_edge, far, max_abs_margin);

    // Re-match the unmatched GPU kps against ALL cpu kps IGNORING the sublevel
    // s, to see if the FPs are actually s-mismatches (same xy, rounded s differs
    // by 1 from f32 round-off) vs genuinely-positionless GPU extras.
    int xy_only_match = 0;
    for (size_t j = 0; j < gpu_kp.size(); ++j) {
      if (gpu_used[j]) continue;
      const double tol = kPosTolBase * std::pow(2.0, gpu_kp[j].o);
      double best_d2 = tol * tol; int best = -1;
      for (size_t c = 0; c < cpu_kp.size(); ++c) {
        if (cpu_kp[c].o != gpu_kp[j].o) continue;  // same octave grid
        const double dx = gpu_kp[j].x - cpu_kp[c].x, dy = gpu_kp[j].y - cpu_kp[c].y;
        const double d2 = dx * dx + dy * dy;
        if (d2 <= best_d2) { best_d2 = d2; best = static_cast<int>(c); }
      }
      if (best >= 0) ++xy_only_match;
    }
    std::printf("[dog_detect_parity] FP diag: of %d unmatched GPU kps, %d have a "
                "same-octave CPU kp within tol ignoring s (s-mismatch dup)\n",
                total_unmatched, xy_only_match);

    // Where do the genuine extras live? Histogram by sublevel s and by distance
    // to the nearest image border (octave-0 coords).
    int by_s[8] = {0};
    int border = 0;  // within 8px of any edge
    for (size_t j = 0; j < gpu_kp.size(); ++j) {
      if (gpu_used[j]) continue;
      int si = gpu_kp[j].s + 1;  // s in [-1,3] → idx [0,4]
      if (si >= 0 && si < 8) ++by_s[si];
      const double bx = std::min<double>(gpu_kp[j].x, ow - 1 - gpu_kp[j].x);
      const double by = std::min<double>(gpu_kp[j].y, oh - 1 - gpu_kp[j].y);
      if (std::min(bx, by) < 8.0) ++border;
    }
    std::printf("[dog_detect_parity] FP diag: extras by s (s=-1..4 → idx0..5): "
                "[%d %d %d %d %d %d]  within-8px-border=%d\n",
                by_s[0], by_s[1], by_s[2], by_s[3], by_s[4], by_s[5], border);

    // Also: print the first 5 unmatched GPU kps with full record + the nearest
    // CPU kp (any s) so we can eyeball what's going on.
    int shown = 0;
    for (size_t j = 0; j < gpu_kp.size() && shown < 5; ++j) {
      if (gpu_used[j]) continue;
      double best_d2 = 1e30; int best = -1;
      for (size_t c = 0; c < cpu_kp.size(); ++c) {
        const double dx = gpu_kp[j].x - cpu_kp[c].x, dy = gpu_kp[j].y - cpu_kp[c].y;
        const double d2 = dx * dx + dy * dy;
        if (d2 < best_d2) { best_d2 = d2; best = static_cast<int>(c); }
      }
      std::printf("  GPU extra: x=%.3f y=%.3f s=%d peak=%.6f edge=%.4f | nearest CPU "
                  "d=%.3fpx", gpu_kp[j].x, gpu_kp[j].y, gpu_kp[j].s,
                  gpu_kp[j].peak, gpu_kp[j].edge, std::sqrt(best_d2));
      if (best >= 0)
        std::printf(" (x=%.3f y=%.3f s=%d peak=%.6f edge=%.4f)",
                    cpu_kp[best].x, cpu_kp[best].y, cpu_kp[best].s,
                    cpu_kp[best].peak, cpu_kp[best].edge);
      std::printf("\n");
      ++shown;
    }
  }

  // ─── Optional precision A/B: run the SAME detector logic on the GPU's GSS
  //     levels in float vs double, to attribute any GPU/CPU count gap to f32. ──
  if (std::getenv("DOG_PARITY_PRECISION_AB")) {
    std::vector<std::vector<float>> levels(6);
    for (int s = SiftPyramidDawn::kOctaveFirstSub; s <= SiftPyramidDawn::kOctaveLastSub; ++s)
      levels[static_cast<size_t>(s + 1)] = gpu.read_level(harness, 0, s);
    int bs_f[8], bs_d[8];
    int n_f = cpu_ref_detect<float>(levels, ow, oh, kPeakThreshold, kEdgeThreshold,
                                    SiftPyramidDawn::base_scale(), kOctaveResolution, bs_f);
    int n_d = cpu_ref_detect<double>(levels, ow, oh, kPeakThreshold, kEdgeThreshold,
                                     SiftPyramidDawn::base_scale(), kOctaveResolution, bs_d);
    std::printf("[precision_ab] host-detector on GPU's GSS: f32 count=%d  f64 count=%d\n", n_f, n_d);
    std::printf("[precision_ab] f32 by-s [s-1..4]: [%d %d %d %d %d %d]\n",
                bs_f[0], bs_f[1], bs_f[2], bs_f[3], bs_f[4], bs_f[5]);
    std::printf("[precision_ab] f64 by-s [s-1..4]: [%d %d %d %d %d %d]\n",
                bs_d[0], bs_d[1], bs_d[2], bs_d[3], bs_d[4], bs_d[5]);
    std::printf("[precision_ab] → GPU(f32)=%u, host-f32=%d, host-f64=%d, VLFeat-f64=%zu\n",
                n_gpu_stored, n_f, n_d, cpu_kp.size());

    // Run the SAME host f64 detector on VLFeat's OWN gss levels. If this lands
    // near VLFeat's 14215 (not the GPU-GSS 14925), the gap is the (tiny) GSS
    // difference amplified at high-s DoG, not a detector-logic bug.
    {
      VlScaleSpace* vss = vl_covdet_get_gss(cov);
      std::vector<std::vector<float>> vlevels(6);
      for (int s = SiftPyramidDawn::kOctaveFirstSub; s <= SiftPyramidDawn::kOctaveLastSub; ++s) {
        const float* lv = vl_scalespace_get_level(vss, 0, s);
        vlevels[static_cast<size_t>(s + 1)].assign(lv, lv + static_cast<size_t>(ow) * oh);
      }
      int bs_vd[8];
      std::vector<Kp> vd_kps;
      int n_vd = cpu_ref_detect<double>(vlevels, ow, oh, kPeakThreshold, kEdgeThreshold,
                                        SiftPyramidDawn::base_scale(), kOctaveResolution, bs_vd, &vd_kps);
      std::printf("[precision_ab] host-f64 on VLFeat's OWN gss = %d (vs VLFeat detect=%zu)\n",
                  n_vd, cpu_kp.size());
      // Apply VLFeat's default non-extrema suppression (tol=0.5) to the host set.
      nonextrema_suppress(vd_kps, 0.5);
      std::printf("[precision_ab] host-f64 + nonextrema_suppress(0.5) = %zu (VLFeat detect=%zu)\n",
                  vd_kps.size(), cpu_kp.size());
    }
  }

  vl_covdet_delete(cov);

  // ── Stage B++ attribution: sequential (VLFeat) vs parallel (GPU) suppression.
  //    Re-detect WITHOUT suppression, then apply both host variants and report
  //    how much the parallel semantics diverge from VLFeat's sequential. ──
  if (kSuppress && std::getenv("DOG_PARITY_PRECISION_AB")) {
    VlCovDet* c2 = vl_covdet_new(VL_COVDET_METHOD_DOG);
    vl_covdet_set_first_octave(c2, 0);
    vl_covdet_set_octave_resolution(c2, kOctaveResolution);
    vl_covdet_set_peak_threshold(c2, kPeakThreshold);
    vl_covdet_set_edge_threshold(c2, kEdgeThreshold);
    vl_covdet_set_non_extrema_suppression_threshold(c2, 0.0);
    vl_covdet_put_image(c2, gray_f.data(), W, H);
    vl_covdet_detect(c2, 1u << 28);
    const int n2 = (int)vl_covdet_get_num_features(c2);
    VlCovDetFeature* f2 = vl_covdet_get_features(c2);
    std::vector<Kp> raw;
    for (int i = 0; i < n2; ++i) {
      Kp k; k.x = (float)f2[i].frame.x; k.y = (float)f2[i].frame.y;
      k.sigma = (float)f2[i].frame.a11; k.peak = f2[i].peakScore; k.edge = f2[i].edgeScore;
      k.o = f2[i].o; k.s = f2[i].s; raw.push_back(k);
    }
    std::vector<Kp> seq = raw, par = raw;
    nonextrema_suppress(seq, 0.5);
    nonextrema_suppress_parallel(par, 0.5);
    std::printf("[suppress_ab] raw=%zu  sequential(VLFeat)=%zu  parallel(GPU)=%zu  "
                "VLFeat-detect-with-supp=%zu\n",
                raw.size(), seq.size(), par.size(), cpu_kp.size());
    vl_covdet_delete(c2);
  }

  const bool pass = recall >= 0.97 && precision >= 0.97 && median_err <= 0.05;
  const char* tag = kSuppress ? "M1-B++ suppression parity" : "M1-B+ full-pyramid detect parity";
  std::printf("%s %s\n", pass ? "PASS" : "FAIL", tag);
  return pass ? 0 : 1;
}
