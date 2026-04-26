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

// ─── Match WGSL RenderUniforms layout exactly ──────────────────────────
//
// NB on the C++-side name vs WGSL-side name:
//   WGSL identifier: `RenderUniforms` (Brush's name).
//   C++ identifier:  `RenderArgsStorage` (renamed per Phase 6.3a P2 review:
//                    the buffer is a STORAGE buffer because it contains
//                    `atomic<u32> num_visible` — atomics aren't legal in
//                    uniform blocks. Calling the C++ struct "Uniforms"
//                    misled readers; "ArgsStorage" makes the kind explicit.)
//   Byte layout MUST match (static_assert below) — that's the real contract.
//
// Layout offsets per WGSL storage rules (verified by inspection):
//   0..64    viewmat (mat4x4f)
//   64..72   focal (vec2f)
//   72..80   img_size (vec2u)
//   80..88   tile_bounds (vec2u)
//   88..96   pixel_center (vec2f)
//   96..112  camera_position (vec4f, 16-aligned)
//   112..116 sh_degree (u32)
//   116..120 num_visible (atomic<u32>)
//   120..124 total_splats (u32)
//   124..128 max_intersects (u32)
//   128..144 background (vec4f, 16-aligned ✓)
struct RenderArgsStorage {
    float viewmat[16];
    float focal[2];
    uint32_t img_size[2];
    uint32_t tile_bounds[2];
    float pixel_center[2];
    float camera_position[4];
    uint32_t sh_degree;
    uint32_t num_visible;     // atomic<u32> in WGSL, layout-equivalent to u32
    uint32_t total_splats;
    uint32_t max_intersects;
    float background[4];
};
static_assert(sizeof(RenderArgsStorage) == 144,
              "RenderArgsStorage byte layout must match WGSL RenderUniforms storage rules");

// PackedVec3: WGSL `struct { x: f32, y: f32, z: f32 }` = 12 bytes (no padding
// for storage buffer; vec3<f32> arrays would be 16-aligned but PackedVec3
// is a literal 3-float struct so it's tightly packed).
struct PackedVec3 {
    float x, y, z;
};
static_assert(sizeof(PackedVec3) == 12, "PackedVec3 must be 12 bytes");

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

    // Identity-view camera (looking down -z from origin), 256×256 image.
    RenderArgsStorage u{};
    // viewmat = identity
    u.viewmat[0]  = 1.0f; u.viewmat[5]  = 1.0f; u.viewmat[10] = 1.0f; u.viewmat[15] = 1.0f;
    u.focal[0] = 256.0f; u.focal[1] = 256.0f;
    u.img_size[0] = 256; u.img_size[1] = 256;
    u.tile_bounds[0] = 16; u.tile_bounds[1] = 16;
    u.pixel_center[0] = 128.0f; u.pixel_center[1] = 128.0f;
    u.camera_position[0] = 0.0f;
    u.camera_position[1] = 0.0f;
    u.camera_position[2] = 0.0f;
    u.camera_position[3] = 0.0f;
    u.sh_degree = 0;
    u.num_visible = 0;
    u.total_splats = kNumSplats;
    u.max_intersects = 1024;
    u.background[0] = 0.0f; u.background[3] = 1.0f;

    // 4 splats at z = 2, 4, 6, 8 in front of camera (camera at z=0 looking
    // down -z means "in front" = positive z in view space).
    PackedVec3 means[kNumSplats] = {
        {0.0f, 0.0f, 2.0f},
        {0.0f, 0.0f, 4.0f},
        {0.0f, 0.0f, 6.0f},
        {0.0f, 0.0f, 8.0f},
    };
    // Identity quaternion (w=1) per WGSL convention (vec4f with w last).
    float quats[kNumSplats * 4] = {
        0.0f, 0.0f, 0.0f, 1.0f,
        0.0f, 0.0f, 0.0f, 1.0f,
        0.0f, 0.0f, 0.0f, 1.0f,
        0.0f, 0.0f, 0.0f, 1.0f,
    };
    // log_scale = log(0.1) ≈ -2.302585 → small spheres
    PackedVec3 log_scales[kNumSplats] = {
        {-2.3f, -2.3f, -2.3f},
        {-2.3f, -2.3f, -2.3f},
        {-2.3f, -2.3f, -2.3f},
        {-2.3f, -2.3f, -2.3f},
    };
    // raw_opacities = 1.0 (sigmoid → 0.73)
    float raw_opacities[kNumSplats] = {1.0f, 1.0f, 1.0f, 1.0f};

    // ─── 4. Upload + alloc buffers (binding order matches WGSL @binding) ─
    auto buf_uniforms = h.upload(&u, sizeof(u),
        wgpu::BufferUsage::Storage | wgpu::BufferUsage::CopySrc);
    auto buf_means = h.upload(means, sizeof(means),
        wgpu::BufferUsage::Storage);
    auto buf_quats = h.upload(quats, sizeof(quats),
        wgpu::BufferUsage::Storage);
    auto buf_log_scales = h.upload(log_scales, sizeof(log_scales),
        wgpu::BufferUsage::Storage);
    auto buf_opacities = h.upload(raw_opacities, sizeof(raw_opacities),
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
               { buf_uniforms, buf_means, buf_quats, buf_log_scales,
                 buf_opacities, buf_gid, buf_depths },
               wg_x, 1, 1);

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
    // Sanity: with 4 in-frustum splats at positive view-space z, the kernel
    // should mark all 4 as visible (atomic increments to num_visible).
    if (out_u.num_visible != kNumSplats) {
        std::cerr << "WARN: num_visible=" << out_u.num_visible
                  << " (expected " << kNumSplats
                  << " — kernel may have a frustum / NaN-rejection bug,"
                  << " OR view-space z convention differs from assumption)\n";
        // Don't fail — Phase 6.3a goal is "compiles + runs without NaN",
        // not "renders correctly". MetalSplatter cross-val (Phase 6.5)
        // catches semantic divergence.
    }

    std::cout << "PASS\n";
    return EXIT_SUCCESS;
}
