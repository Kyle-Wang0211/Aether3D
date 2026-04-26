// Phase 6.3a smoke test — Brush map_gaussian_to_intersects.wgsl on Dawn.
//
// Third kernel in the viewer pipeline. Each visible Gaussian was projected
// to a 2D ellipse in screen space (project_visible output); this kernel
// expands each ellipse into per-tile intersections, writing
//   tile_id_from_isect[i]    — which tile this intersection belongs to
//   compact_gid_from_isect[i] — which splat
//   num_intersections[0]     — total count (written only by thread 0)
//
// For per-kernel isolation, we pre-populate the 2 inputs that depend on
// upstream kernels:
//   projected[] — ProjectedSplat[N] from project_visible (we hand-build
//                 4 splats at image center with our z²-scaled conics)
//   splat_cum_hit_counts[] — exclusive prefix sum of per-splat tile-hit
//                             counts. For smoke, give each splat a budget
//                             of 4 tiles → cum = [0, 4, 8, 12, 16].
//
// What this verifies:
//   1. map_gaussian_to_intersects.wgsl compiles via Tint
//   2. 6-buffer @group(0) bind layout valid
//   3. Storage-read uniforms (vs project_forward's read_write) bind path
//   4. Kernel writes tile_id_from_isect + compact_gid_from_isect without
//      crash, no negative or oversized tile IDs
//   5. num_intersections[0] = splat_cum_hit_counts[num_visible] = 16

#include "aether_dawn_splat_test_data.h"
#include "dawn_kernel_harness.h"

#include <cstdint>
#include <cstring>
#include <fstream>
#include <iostream>
#include <sstream>
#include <string>
#include <vector>

namespace {

using aether::tools::splat_test_data::RenderArgsStorage;
using aether::tools::splat_test_data::ProjectedSplat;
using aether::tools::splat_test_data::make_identity_camera_args;

constexpr uint32_t kNumSplats = 4;
constexpr uint32_t kMaxIntersects = 64;  // smoke max; well under uniform's 1024 budget
// Per-splat hit budget: 4 tiles → cum_hit_counts = [0, 4, 8, 12, 16].
constexpr uint32_t kPerSplatTileBudget = 4;

std::string read_wgsl_file(const std::string& path) {
    std::ifstream in(path);
    if (!in) {
        std::cerr << "Failed to open WGSL: " << path << '\n';
        return {};
    }
    std::ostringstream ss;
    ss << in.rdbuf();
    return ss.str();
}

}  // namespace

int main(int /*argc*/, char* argv[]) {
    using namespace aether::tools;

    std::string wgsl_path =
        "aether_cpp/shaders/wgsl/map_gaussian_to_intersects.wgsl";
    if (argv && argv[1]) wgsl_path = argv[1];
    std::string wgsl = read_wgsl_file(wgsl_path);
    if (wgsl.empty()) return EXIT_FAILURE;

    DawnKernelHarness h;
    if (!h.init()) {
        std::cerr << "DawnKernelHarness::init failed\n";
        return EXIT_FAILURE;
    }

    // ─── Inputs ────────────────────────────────────────────────────────
    RenderArgsStorage u = make_identity_camera_args(kNumSplats,
                                                     /*num_visible=*/kNumSplats);

    // 4 ProjectedSplat values matching project_visible's smoke output:
    // xy=(128, 128) on optical axis, conic z² scale, mid-gray rgba.
    ProjectedSplat projected[kNumSplats] = {
        {128.0f, 128.0f, 0.006061f, 0.0f, 0.006061f,  0.641f, 0.641f, 0.641f, 0.731059f},
        {128.0f, 128.0f, 0.024113f, 0.0f, 0.024113f,  0.641f, 0.641f, 0.641f, 0.731059f},
        {128.0f, 128.0f, 0.053767f, 0.0f, 0.053767f,  0.641f, 0.641f, 0.641f, 0.731059f},
        {128.0f, 128.0f, 0.094401f, 0.0f, 0.094401f,  0.641f, 0.641f, 0.641f, 0.731059f},
    };

    // splat_cum_hit_counts[N+1] — exclusive prefix sum + total at end.
    // Kernel reads splat_cum_hit_counts[num_visible] for total intersection
    // count, and splat_cum_hit_counts[compact_gid] for per-splat base offset.
    uint32_t cum_hit_counts[kNumSplats + 1] = {0, 4, 8, 12, 16};

    // ─── Upload + alloc ────────────────────────────────────────────────
    auto buf_uniforms = h.upload(&u, sizeof(u),
        wgpu::BufferUsage::Storage);
    auto buf_projected = h.upload(projected, sizeof(projected),
        wgpu::BufferUsage::Storage);
    auto buf_cum = h.upload(cum_hit_counts, sizeof(cum_hit_counts),
        wgpu::BufferUsage::Storage);

    constexpr size_t kIsectBytes = kMaxIntersects * sizeof(uint32_t);
    auto buf_tile_id_from_isect = h.alloc(kIsectBytes,
        wgpu::BufferUsage::Storage | wgpu::BufferUsage::CopySrc);
    auto buf_compact_gid_from_isect = h.alloc(kIsectBytes,
        wgpu::BufferUsage::Storage | wgpu::BufferUsage::CopySrc);
    // num_intersections is array<u32> bound length 1 (kernel writes
    // index 0 only); allocate u32 sized.
    auto buf_num_intersects = h.alloc(sizeof(uint32_t),
        wgpu::BufferUsage::Storage | wgpu::BufferUsage::CopySrc);

    // ─── Compile + dispatch ───────────────────────────────────────────
    auto pipeline = h.load_compute(wgsl, "main");
    if (pipeline == nullptr) {
        std::cerr << "load_compute returned null\n";
        return EXIT_FAILURE;
    }
    const uint32_t wg_x = (kNumSplats + 255) / 256;
    h.dispatch(pipeline,
               { buf_uniforms, buf_projected, buf_cum,
                 buf_tile_id_from_isect, buf_compact_gid_from_isect,
                 buf_num_intersects },
               wg_x, 1, 1);

    // ─── Readback ─────────────────────────────────────────────────────
    auto staging_num = h.alloc_staging_for_readback(sizeof(uint32_t));
    auto staging_tile = h.alloc_staging_for_readback(kIsectBytes);
    auto staging_gid = h.alloc_staging_for_readback(kIsectBytes);
    h.copy_to_staging(buf_num_intersects, staging_num, sizeof(uint32_t));
    h.copy_to_staging(buf_tile_id_from_isect, staging_tile, kIsectBytes);
    h.copy_to_staging(buf_compact_gid_from_isect, staging_gid, kIsectBytes);
    auto bytes_num = h.readback(staging_num, sizeof(uint32_t));
    auto bytes_tile = h.readback(staging_tile, kIsectBytes);
    auto bytes_gid = h.readback(staging_gid, kIsectBytes);

    if (bytes_num.size() != sizeof(uint32_t)) {
        std::cerr << "Readback num_intersections size mismatch\n";
        return EXIT_FAILURE;
    }
    uint32_t num_intersections = 0;
    std::memcpy(&num_intersections, bytes_num.data(), sizeof(uint32_t));

    std::cout << "=== aether_dawn_splat_smoke_map_gaussian_to_intersects ===\n";
    std::cout << "WGSL: " << wgsl_path << '\n';
    std::cout << "WGSL bytes: " << wgsl.size() << '\n';
    std::cout << "input num_visible: " << u.num_visible << '\n';
    std::cout << "input cum_hit_counts: [0, 4, 8, 12, 16]\n";
    std::cout << "output num_intersections[0]: " << num_intersections << '\n';

    // The kernel's `if gid.x == 0u` block writes:
    //   num_intersections[0] = splat_cum_hit_counts[num_visible] = cum[4] = 16
    // Anything else → kernel didn't dispatch correctly.
    if (num_intersections != 16) {
        std::cerr << "FAIL: num_intersections expected 16, got " << num_intersections << '\n';
        return EXIT_FAILURE;
    }

    // Spot-check tile_ids written are in [0, tile_bounds.x * tile_bounds.y) = [0, 256).
    const auto* tile_arr = reinterpret_cast<const uint32_t*>(bytes_tile.data());
    const auto* gid_arr = reinterpret_cast<const uint32_t*>(bytes_gid.data());
    uint32_t max_tile_id = u.tile_bounds[0] * u.tile_bounds[1];
    uint32_t isects_with_data = 0;
    for (uint32_t i = 0; i < kMaxIntersects; ++i) {
        if (tile_arr[i] != 0 || gid_arr[i] != 0) {
            ++isects_with_data;
            if (tile_arr[i] >= max_tile_id) {
                std::cerr << "FAIL: isect " << i << " has tile_id " << tile_arr[i]
                          << " >= max " << max_tile_id << '\n';
                return EXIT_FAILURE;
            }
            if (gid_arr[i] >= u.num_visible) {
                std::cerr << "FAIL: isect " << i << " has compact_gid " << gid_arr[i]
                          << " >= num_visible " << u.num_visible << '\n';
                return EXIT_FAILURE;
            }
        }
    }
    std::cout << "isects with non-zero data (sanity: tile_id + gid in valid range): "
              << isects_with_data << '\n';
    // A small splat at (128,128) with conic ~0.006-0.094 covers a few tiles
    // around the center → some intersections expected. Don't assert exact
    // count (tile coverage = math we don't validate here, deferred to 6.5).

    std::cout << "PASS\n";
    return EXIT_SUCCESS;
}
