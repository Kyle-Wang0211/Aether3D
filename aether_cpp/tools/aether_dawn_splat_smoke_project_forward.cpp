// Phase 6.3a smoke test — Brush project_forward.wgsl on Dawn.
//
// Validates the 5-layer chain in isolation:
//   Brush WGSL → naga_oil ETL (Path G) → Tint translation → Dawn Metal
//   backend → Apple Silicon Metal runtime
//
// Per-step de-risk: this binary excludes the DawnGPUDevice (6.2.G-K)
// wrapper layer, so any failure here is in the 5 layers above. When this
// passes, 6.2.G-K becomes mechanical translation of harness API calls.
//
// What this verifies (not "is the math correct" — that's Phase 6.5
// MetalSplatter cross-validation):
//   1. project_forward.wgsl compiles via Tint (no compilation errors)
//   2. Compute pipeline creates without error
//   3. Bind group with 7 storage buffers is valid
//   4. Dispatch completes without GPU error (no signal 11, no validation fail)
//   5. Output buffers (depths[], global_from_compact_gid[]) read back
//      without NaN/inf
//
// Test scene: 4 deterministic Gaussians at depth z = 2, 4, 6, 8 in front
// of an identity-view camera at origin. Camera at (0,0,5) looking down
// -z. Expected: all 4 splats project successfully (mean_c.z > 0.01),
// depths populated, num_visible = 4.

#include "aether_dawn_splat_test_data.h"
#include "dawn_kernel_harness.h"

#include <cmath>
#include <cstdint>
#include <cstdio>
#include <cstring>
#include <fstream>
#include <iostream>
#include <sstream>
#include <string>
#include <vector>

namespace {

using aether::tools::splat_test_data::RenderArgsStorage;
using aether::tools::splat_test_data::PackedVec3;
using aether::tools::splat_test_data::make_identity_camera_args;
using aether::tools::splat_test_data::make_axis_packed_splats;
using aether::tools::splat_test_data::verify_axis_depths;

constexpr uint32_t kNumSplats = 4;

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

bool any_nan(const std::vector<uint8_t>& bytes) {
    const auto* fp = reinterpret_cast<const float*>(bytes.data());
    const size_t count = bytes.size() / sizeof(float);
    for (size_t i = 0; i < count; ++i) {
        if (std::isnan(fp[i]) || std::isinf(fp[i])) {
            return true;
        }
    }
    return false;
}

}  // namespace

int main(int /*argc*/, char* argv[]) {
    using namespace aether::tools;

    // ─── 1. Load WGSL source ──────────────────────────────────────────
    // Default to the standard repo location; allow override via argv[1].
    std::string wgsl_path =
        "aether_cpp/shaders/wgsl/project_forward.wgsl";
    if (argv && argv[1]) wgsl_path = argv[1];
    std::string wgsl = read_wgsl_file(wgsl_path);
    if (wgsl.empty()) {
        return EXIT_FAILURE;
    }

    // ─── 2. Init Dawn harness ─────────────────────────────────────────
    DawnKernelHarness h;
    if (!h.init()) {
        std::cerr << "DawnKernelHarness::init failed\n";
        return EXIT_FAILURE;
    }

    // ─── 3. Build test inputs ─────────────────────────────────────────

    // Identity-view camera, 256×256 image, num_visible starts at 0
    // (project_forward atomically increments it as splats project).
    RenderArgsStorage u = make_identity_camera_args(kNumSplats, /*num_visible=*/0);

    // 4 splats at z = 2, 4, 6, 8 in front of camera. Phase 6.4f replaced
    // the five unpacked per-Gaussian buffers with a single packed one —
    // see make_axis_packed_splats() in aether_dawn_splat_test_data.h.
    ::aether::splat::PackedSplat packed[kNumSplats];
    make_axis_packed_splats(packed);

    // ─── 4. Upload + alloc buffers (binding order matches WGSL @binding) ─
    //   0 uniforms                 (read_write storage)
    //   1 packed_splats            (read-only storage, 16 B/splat)
    //   2 global_from_compact_gid  (output)
    //   3 depths                   (output)
    auto buf_uniforms = h.upload(&u, sizeof(u),
        wgpu::BufferUsage::Storage | wgpu::BufferUsage::CopySrc);
    auto buf_packed = h.upload(packed, sizeof(packed),
        wgpu::BufferUsage::Storage);
    // Output buffers (zero-initialized by Dawn).
    constexpr size_t kOutGidBytes = kNumSplats * sizeof(uint32_t);
    constexpr size_t kOutDepthBytes = kNumSplats * sizeof(float);
    auto buf_gid = h.alloc(kOutGidBytes,
        wgpu::BufferUsage::Storage | wgpu::BufferUsage::CopySrc);
    auto buf_depths = h.alloc(kOutDepthBytes,
        wgpu::BufferUsage::Storage | wgpu::BufferUsage::CopySrc);

    // ─── 5. Compile + dispatch ────────────────────────────────────────
    auto pipeline = h.load_compute(wgsl, "main");
    if (pipeline == nullptr) {
        std::cerr << "load_compute returned null pipeline\n";
        return EXIT_FAILURE;
    }
    // Workgroup size in WGSL = 256, dispatch ceil(4 / 256) = 1.
    const uint32_t wg_x = (kNumSplats + 255) / 256;
    h.dispatch(pipeline,
               { buf_uniforms, buf_packed, buf_gid, buf_depths },
               wg_x, 1, 1);

    // A recorded device error means every readback below is Dawn's
    // zero-fill, not the kernel's output. Check BEFORE asserting.
    if (aether::tools::dawn_smoke_check_device_error(
            "aether_dawn_splat_smoke_project_forward")) {
        return EXIT_FAILURE;
    }

    // ─── 6. Readback + verify ─────────────────────────────────────────
    auto staging_uniforms = h.alloc_staging_for_readback(sizeof(u));
    auto staging_depths = h.alloc_staging_for_readback(kOutDepthBytes);
    h.copy_to_staging(buf_uniforms, staging_uniforms, sizeof(u));
    h.copy_to_staging(buf_depths, staging_depths, kOutDepthBytes);

    auto bytes_uniforms = h.readback(staging_uniforms, sizeof(u));
    auto bytes_depths = h.readback(staging_depths, kOutDepthBytes);

    if (bytes_uniforms.size() != sizeof(u) ||
        bytes_depths.size() != kOutDepthBytes) {
        std::cerr << "Readback size mismatch (uniforms=" << bytes_uniforms.size()
                  << " depths=" << bytes_depths.size() << ")\n";
        return EXIT_FAILURE;
    }

    RenderArgsStorage out_u{};
    std::memcpy(&out_u, bytes_uniforms.data(), sizeof(out_u));

    std::cout << "=== aether_dawn_splat_smoke_project_forward ===\n";
    std::cout << "WGSL: " << wgsl_path << '\n';
    std::cout << "WGSL bytes: " << wgsl.size() << '\n';
    std::cout << "input total_splats: " << u.total_splats << '\n';
    std::cout << "output num_visible: " << out_u.num_visible << '\n';
    std::cout << "depths: ";
    const auto* depth_arr = reinterpret_cast<const float*>(bytes_depths.data());
    for (size_t i = 0; i < kNumSplats; ++i) {
        std::cout << depth_arr[i] << (i + 1 < kNumSplats ? ", " : "\n");
    }

    if (any_nan(bytes_depths)) {
        std::cerr << "FAIL: NaN/inf in depths buffer\n";
        return EXIT_FAILURE;
    }
    // All 4 fixture splats are in front of the camera and inside the
    // frustum, so the kernel must compact all 4.
    //
    // This used to be a WARN that still returned PASS ("Phase 6.3a goal is
    // compiles + runs without NaN"). That made the tool unable to fail on
    // an all-zero readback, which is precisely what it did for the ~4
    // months the bind group was being rejected: num_visible=0, depths
    // 0,0,0,0, exit code 0. It is a hard judge now.
    if (out_u.num_visible != kNumSplats) {
        std::cerr << "FAIL: num_visible=" << out_u.num_visible
                  << " (expected " << kNumSplats
                  << ") — all four fixture splats are in-frustum at "
                     "positive view-space z, so this is a frustum / cull / "
                     "binding bug, or nothing ran at all\n";
        return EXIT_FAILURE;
    }
    if (!verify_axis_depths(depth_arr,
                            "aether_dawn_splat_smoke_project_forward")) {
        return EXIT_FAILURE;
    }

    std::cout << "PASS\n";
    return EXIT_SUCCESS;
}
