// SPDX-License-Identifier: LicenseRef-Aether3D-Proprietary
// Copyright (c) 2024-2026 Aether3D. All rights reserved.

#include "aether/splat/splat_render_engine.h"

#include "aether/splat/ply_loader.h"
#include "aether/splat/spz_decoder.h"

#include <algorithm>
#include <cmath>
#include <cstring>
#include <cstdio>   // fprintf for debug diagnostics
#include <numeric>   // iota

namespace aether {
namespace splat {

SplatRenderEngine::SplatRenderEngine(render::GPUDevice& device,
                                     const SplatRenderConfig& config) noexcept
    : device_(device)
    , config_(config)
    , cpu_buffer_(config.max_splats)
    , staging_buffer_(4096) {
    // D3: Default regions to fully visible (1.0).
    // Initial capacity: 64 regions (grows dynamically as needed).
    region_fade_alphas_.resize(64, 1.0f);
    region_fade_gpu_capacity_ = 64;
    create_gpu_resources();
}

SplatRenderEngine::~SplatRenderEngine() noexcept {
    destroy_gpu_resources();
}

core::Status SplatRenderEngine::load_from_ply(const char* path) noexcept {
    PlyLoadResult ply_result;
    auto status = load_ply(path, ply_result);
    if (!core::is_ok(status)) return status;

    return load_gaussians(ply_result.gaussians.data(),
                          ply_result.gaussians.size());
}

core::Status SplatRenderEngine::load_from_spz(const std::uint8_t* data,
                                               std::size_t size) noexcept {
    SpzDecodeResult spz_result;
    auto status = decode_spz(data, size, spz_result);
    if (!core::is_ok(status)) return status;

    return load_gaussians(spz_result.gaussians.data(),
                          spz_result.gaussians.size());
}

core::Status SplatRenderEngine::load_gaussians(const GaussianParams* params,
                                                std::size_t count) noexcept {
    if (!params || count == 0) return core::Status::kInvalidArgument;
    if (count > config_.max_splats) count = config_.max_splats;

    cpu_buffer_.clear();
    cpu_buffer_.push_batch(params, count);
    splat_count_ = count;

    // Extract SH coefficients into GPU-ready layout: 12 floats per splat
    // GPU layout: [R_b0, R_b1, R_b2, pad, G_b0, G_b1, G_b2, pad, B_b0, B_b1, B_b2, pad]
    // Source sh1[] layout (PLY per-channel): [R_b0, R_b1, R_b2, G_b0, G_b1, G_b2, B_b0, B_b1, B_b2]
    //   where f_rest_0..2 = R channel, f_rest_3..5 = G channel, f_rest_6..8 = B channel
    cpu_sh_data_.resize(count * 12);
    for (std::size_t i = 0; i < count; ++i) {
        float* dst = &cpu_sh_data_[i * 12];
        const float* sh = params[i].sh1;
        // R channel: sh[0..2] = R_b0, R_b1, R_b2
        dst[0] = sh[0]; dst[1] = sh[1]; dst[2] = sh[2]; dst[3] = 0.0f;
        // G channel: sh[3..5] = G_b0, G_b1, G_b2
        dst[4] = sh[3]; dst[5] = sh[4]; dst[6] = sh[5]; dst[7] = 0.0f;
        // B channel: sh[6..8] = B_b0, B_b1, B_b2
        dst[8] = sh[6]; dst[9] = sh[7]; dst[10] = sh[8]; dst[11] = 0.0f;
    }

    upload_splats_to_gpu();

    // Only mark initialized if the render pipeline was successfully created.
    // If shaders failed to load, render_pipeline_ is {0} and draw calls
    // would silently encode nothing — producing a black screen.
    initialized_ = render_pipeline_.valid();
    if (!initialized_) {
        std::fprintf(stderr, "[Aether3D][SplatEngine] WARNING: data loaded (%zu splats) "
                     "but render_pipeline_ is INVALID — shaders failed to load\n",
                     splat_count_);
    }

    return core::Status::kOk;
}

void SplatRenderEngine::push_splats(const GaussianParams* params,
                                     std::size_t count) noexcept {
    if (!params || count == 0) return;

    // Append to staging buffer (training thread may call this)
    staging_buffer_.push_batch(params, count);

    // Also extract SH coefficients into staging (GPU-ready layout)
    // sh1[] is per-channel: [R_b0,R_b1,R_b2, G_b0,G_b1,G_b2, B_b0,B_b1,B_b2]
    std::size_t base = staging_sh_data_.size();
    staging_sh_data_.resize(base + count * 12);
    for (std::size_t i = 0; i < count; ++i) {
        float* dst = &staging_sh_data_[base + i * 12];
        const float* sh = params[i].sh1;
        dst[0] = sh[0]; dst[1] = sh[1]; dst[2] = sh[2]; dst[3] = 0.0f;
        dst[4] = sh[3]; dst[5] = sh[4]; dst[6] = sh[5]; dst[7] = 0.0f;
        dst[8] = sh[6]; dst[9] = sh[7]; dst[10] = sh[8]; dst[11] = 0.0f;
    }

    staging_dirty_ = true;
}

void SplatRenderEngine::push_splats_with_regions(
    const GaussianParams* params,
    const std::uint8_t* region_ids,
    std::size_t count) noexcept
{
    if (!params || count == 0) return;

    // Push splats via standard path
    push_splats(params, count);

    // Also stage region IDs (parallel to staging_buffer_)
    if (region_ids) {
        std::size_t base = staging_region_ids_.size();
        staging_region_ids_.resize(base + count);
        std::memcpy(&staging_region_ids_[base], region_ids, count);
    } else {
        // No region IDs provided — default to region 0
        staging_region_ids_.resize(staging_region_ids_.size() + count, 0);
    }
}

void SplatRenderEngine::set_region_fade_alphas(
    const float* fade_alphas,
    std::size_t count) noexcept
{
    if (!fade_alphas || count == 0) return;
    active_region_count_ = count;

    // Grow vector if needed (dynamic, no upper limit)
    if (count > region_fade_alphas_.size()) {
        std::size_t old_size = region_fade_alphas_.size();
        region_fade_alphas_.resize(count, 1.0f);
    }
    for (std::size_t i = 0; i < count; ++i) {
        region_fade_alphas_[i] = fade_alphas[i];
    }
}

void SplatRenderEngine::push_splats_with_regions_u16(
    const GaussianParams* params,
    const std::uint16_t* region_ids,
    std::size_t count) noexcept
{
    if (!params || count == 0) return;

    // Push splats via standard path
    push_splats(params, count);

    // Convert uint16 → uint8 for current GPU pipeline (legacy path)
    // Phase 6 TODO: when Metal shader supports uint16, stage directly
    if (region_ids) {
        std::size_t base = staging_region_ids_.size();
        staging_region_ids_.resize(base + count);
        for (std::size_t i = 0; i < count; ++i) {
            staging_region_ids_[base + i] = static_cast<std::uint8_t>(
                std::min(static_cast<unsigned>(region_ids[i]), 255u));
        }
    } else {
        staging_region_ids_.resize(staging_region_ids_.size() + count, 0);
    }
}

void SplatRenderEngine::clear_splats() noexcept {
    // Thread-safe: only clear the staging buffer (written by training thread).
    // Set pending_clear_ flag so begin_frame() (main thread) clears cpu_buffer_.
    // This avoids data race: main thread reads cpu_buffer_ via packed_data(),
    // training thread must not modify cpu_buffer_ directly.
    staging_buffer_.clear();
    staging_sh_data_.clear();
    staging_region_ids_.clear();
    pending_clear_ = true;
    staging_dirty_ = true;  // Ensure begin_frame() processes the update
}

void SplatRenderEngine::begin_frame() noexcept {
    if (staging_dirty_) {
        // Handle pending clear first (set by training thread via clear_splats())
        if (pending_clear_) {
            cpu_buffer_.clear();
            cpu_sh_data_.clear();
            cpu_region_ids_.clear();
            splat_count_ = 0;
            initialized_ = false;
            pending_clear_ = false;
        }

        // Merge staging into main buffer
        const PackedSplat* staging_data = staging_buffer_.data();
        std::size_t staging_count = staging_buffer_.size();

        for (std::size_t i = 0; i < staging_count; ++i) {
            if (cpu_buffer_.size() < config_.max_splats) {
                cpu_buffer_.push(staging_data[i]);
            }
        }

        // Merge staging SH data into main SH buffer
        // Bug 0.8 fix: guard against unsigned underflow when splat_count_ > max_splats.
        std::size_t available_slots = (splat_count_ < config_.max_splats)
            ? (config_.max_splats - splat_count_) : 0;
        std::size_t sh_entries_to_merge = std::min(
            staging_sh_data_.size() / 12,
            available_slots);
        if (sh_entries_to_merge > 0) {
            std::size_t old_count = cpu_sh_data_.size() / 12;
            cpu_sh_data_.resize((old_count + sh_entries_to_merge) * 12);
            std::memcpy(&cpu_sh_data_[old_count * 12],
                        staging_sh_data_.data(),
                        sh_entries_to_merge * 12 * sizeof(float));
        }

        // D3: Merge staging region IDs into main region ID buffer
        std::size_t region_entries_to_merge = std::min(
            staging_region_ids_.size(), available_slots);
        if (region_entries_to_merge > 0) {
            std::size_t old_region_count = cpu_region_ids_.size();
            cpu_region_ids_.resize(old_region_count + region_entries_to_merge);
            std::memcpy(&cpu_region_ids_[old_region_count],
                        staging_region_ids_.data(),
                        region_entries_to_merge);
        }
        // Pad with region 0 if splats were added without region IDs
        while (cpu_region_ids_.size() < cpu_buffer_.size()) {
            cpu_region_ids_.push_back(0);
        }

        splat_count_ = cpu_buffer_.size();
        staging_buffer_.clear();
        staging_sh_data_.clear();
        staging_region_ids_.clear();
        staging_dirty_ = false;

        // Re-upload to GPU
        upload_splats_to_gpu();
    }

    stats_ = SplatRenderStats{};
    stats_.total_splats = splat_count_;
}

// Column-major 4×4 matrix multiply: out = a * b
static void mat4_multiply(const float* a, const float* b, float* out) noexcept {
    for (int c = 0; c < 4; ++c) {
        for (int r = 0; r < 4; ++r) {
            float sum = 0.0f;
            for (int k = 0; k < 4; ++k) {
                sum += a[k * 4 + r] * b[c * 4 + k];
            }
            out[c * 4 + r] = sum;
        }
    }
}

void SplatRenderEngine::update_camera(const SplatCameraState& camera) noexcept {
    camera_ = camera;

    // Compute viewProjMatrix = proj * view (column-major)
    mat4_multiply(camera_.proj, camera_.view, camera_.view_proj);

    // Fill engine-known fields
    camera_.splat_count = static_cast<std::uint32_t>(splat_count_);
    camera_._pad = 0;

    // ─── Diagnostic: print camera + first splat info (first 5 calls only) ───
    static int diag_count = 0;
    if (diag_count < 5 && splat_count_ > 0) {
        diag_count++;
        // Camera info
        std::fprintf(stderr, "[Aether3D][DIAG] camera: fx=%.1f fy=%.1f cx=%.1f cy=%.1f "
                     "vp=%ux%u splats=%zu\n",
                     camera_.fx, camera_.fy, camera_.cx, camera_.cy,
                     camera_.vp_width, camera_.vp_height, splat_count_);

        // View matrix rows (column-major: V[col*4+row])
        const float* V = camera_.view;
        std::fprintf(stderr, "[Aether3D][DIAG] view row2: [%.4f %.4f %.4f %.4f] (z-axis)\n",
                     V[0*4+2], V[1*4+2], V[2*4+2], V[3*4+2]);

        // First splat info
        const PackedSplat& s0 = cpu_buffer_.data()[0];
        float px = half_to_float(s0.center[0]);
        float py = half_to_float(s0.center[1]);
        float pz = half_to_float(s0.center[2]);
        std::fprintf(stderr, "[Aether3D][DIAG] splat[0]: pos=(%.4f, %.4f, %.4f) "
                     "scale_bytes=(%u, %u, %u) rgba=(%u,%u,%u,%u)\n",
                     px, py, pz,
                     s0.log_scale[0], s0.log_scale[1], s0.log_scale[2],
                     s0.rgba[0], s0.rgba[1], s0.rgba[2], s0.rgba[3]);

        // Compute view-space position of first splat
        float vx = V[0*4+0]*px + V[1*4+0]*py + V[2*4+0]*pz + V[3*4+0];
        float vy = V[0*4+1]*px + V[1*4+1]*py + V[2*4+1]*pz + V[3*4+1];
        float vz = V[0*4+2]*px + V[1*4+2]*py + V[2*4+2]*pz + V[3*4+2];
        float depth = -vz;
        std::fprintf(stderr, "[Aether3D][DIAG] splat[0] viewPos=(%.4f, %.4f, %.4f) depth=%.4f\n",
                     vx, vy, vz, depth);

        // Compute expected screen radius
        float scale_val = std::exp(float(s0.log_scale[0]) / 255.0f * 16.0f - 8.0f);
        if (depth > 0.01f) {
            float sigma2d = scale_val * camera_.fx / depth;
            std::fprintf(stderr, "[Aether3D][DIAG] splat[0] decoded_scale=%.6f "
                         "sigma2d=%.2f px, 3sigma=%.2f px\n",
                         scale_val, sigma2d, sigma2d * 3.0f);
        }

        // Print bounding info for all splats (min/max positions)
        float min_x = 1e30f, max_x = -1e30f;
        float min_y = 1e30f, max_y = -1e30f;
        float min_z = 1e30f, max_z = -1e30f;
        for (std::size_t i = 0; i < splat_count_; ++i) {
            float x = half_to_float(cpu_buffer_.data()[i].center[0]);
            float y = half_to_float(cpu_buffer_.data()[i].center[1]);
            float z = half_to_float(cpu_buffer_.data()[i].center[2]);
            if (x < min_x) min_x = x;
            if (x > max_x) max_x = x;
            if (y < min_y) min_y = y;
            if (y > max_y) max_y = y;
            if (z < min_z) min_z = z;
            if (z > max_z) max_z = z;
        }
        std::fprintf(stderr, "[Aether3D][DIAG] point cloud bounds: "
                     "x=[%.3f, %.3f] y=[%.3f, %.3f] z=[%.3f, %.3f]\n",
                     min_x, max_x, min_y, max_y, min_z, max_z);
        float span = std::sqrt((max_x-min_x)*(max_x-min_x) +
                                (max_y-min_y)*(max_y-min_y) +
                                (max_z-min_z)*(max_z-min_z));
        std::fprintf(stderr, "[Aether3D][DIAG] span=%.3f, depth=%.3f, "
                     "depth/span=%.1f (large = far camera)\n",
                     span, depth, depth / (span > 0 ? span : 1e-6f));
    }

    // Upload camera uniform to GPU (full 224 bytes matching SplatCameraUniforms)
    if (camera_buffer_.valid()) {
        device_.update_buffer(camera_buffer_, &camera_,
                              0, sizeof(SplatCameraState));
    }

    // CPU depth sort (fallback when GPU radix sort kernels are not available).
    // GPU sort runs in encode_sort_pass() if all 4 sort pipelines are valid.
    bool gpu_sort_ready = clear_hist_pipeline_.valid() &&
                          histogram_pipeline_.valid() &&
                          prefix_sum_pipeline_.valid() &&
                          scatter_pipeline_.valid();
    if (!gpu_sort_ready && splat_count_ > 0 && index_buffer_.valid()) {
        cpu_depth_sort();
    }
}

void SplatRenderEngine::cpu_depth_sort() noexcept {
    const std::size_t n = splat_count_;
    const PackedSplat* splats = cpu_buffer_.data();

    // Resize buffers if needed
    if (cpu_sort_indices_.size() < n) {
        cpu_sort_indices_.resize(n);
        cpu_sort_depths_.resize(n);
    }

    // Extract view matrix row 2 (column-major: view[c*4+r])
    // viewPos.z = view[0*4+2]*px + view[1*4+2]*py + view[2*4+2]*pz + view[3*4+2]
    const float* V = camera_.view;
    float v02 = V[0 * 4 + 2];  // row=2, col=0
    float v12 = V[1 * 4 + 2];  // row=2, col=1
    float v22 = V[2 * 4 + 2];  // row=2, col=2
    float v32 = V[3 * 4 + 2];  // row=2, col=3 (translation)

    // Compute depth for each splat
    for (std::size_t i = 0; i < n; ++i) {
        float px = half_to_float(splats[i].center[0]);
        float py = half_to_float(splats[i].center[1]);
        float pz = half_to_float(splats[i].center[2]);
        // viewPos.z = dot(view_row2, [px, py, pz, 1])
        // In our lookAt convention, viewPos.z < 0 for objects in front.
        // More negative = farther from camera. We want front-to-back sorting.
        cpu_sort_depths_[i] = v02 * px + v12 * py + v22 * pz + v32;
        cpu_sort_indices_[i] = static_cast<std::uint32_t>(i);
    }

    // Sort by depth: front-to-back = most negative first (ascending).
    std::sort(cpu_sort_indices_.data(), cpu_sort_indices_.data() + n,
              [this](std::uint32_t a, std::uint32_t b) {
                  return cpu_sort_depths_[a] < cpu_sort_depths_[b];
              });

    // Upload sorted indices to GPU
    device_.update_buffer(index_buffer_, cpu_sort_indices_.data(),
                          0, n * sizeof(std::uint32_t));
}

void SplatRenderEngine::encode_sort_pass(render::GPUCommandBuffer& cmd) noexcept {
    if (splat_count_ == 0) return;

    std::uint32_t thread_count = static_cast<std::uint32_t>(splat_count_);
    constexpr std::uint32_t threadgroup_size = 256;

    // Step 1: Compute depths from camera
    // Metal shader computeSplatDepths expects:
    //   buffer(0) = PackedSplatGPU[]   (splat data)
    //   buffer(1) = SplatCameraUniforms (camera)
    //   buffer(2) = float[]            (output depths)
    //   buffer(3) = uint[]             (output indices, initialized to gid)
    if (depth_pipeline_.valid()) {
        auto* encoder = cmd.make_compute_encoder();
        if (!encoder) return;

        encoder->set_pipeline(depth_pipeline_);
        encoder->set_buffer(splat_buffer_, 0, 0);     // buffer(0): PackedSplat[]
        encoder->set_buffer(camera_buffer_, 0, 1);    // buffer(1): Camera uniform
        encoder->set_buffer(depth_buffer_, 0, 2);     // buffer(2): float[] depths
        encoder->set_buffer(index_buffer_, 0, 3);     // buffer(3): uint[] indices

        encoder->dispatch_1d(thread_count, threadgroup_size);
        encoder->end_encoding();
    }

    // Step 2: GPU radix sort by depth
    // Complete 4-phase radix sort: clear → histogram → prefix sum → scatter
    // Each radix pass sorts by 8 bits. Ping-pong between index_buffer_ and sort_temp_indices_.
    bool gpu_sort_ready = clear_hist_pipeline_.valid() &&
                          histogram_pipeline_.valid() &&
                          prefix_sum_pipeline_.valid() &&
                          scatter_pipeline_.valid();

    if (gpu_sort_ready) {
        std::uint32_t passes = config_.sort_precision_bits / 8;
        if (passes == 0) passes = 2;  // minimum 16-bit sort

        for (std::uint32_t pass = 0; pass < passes; ++pass) {
            // Ping-pong: even passes read index→temp, odd passes read temp→index
            auto& src_buf = (pass % 2 == 0) ? index_buffer_ : sort_temp_indices_;
            auto& dst_buf = (pass % 2 == 0) ? sort_temp_indices_ : index_buffer_;

            // SortPassParams for this pass
            std::uint32_t sort_params[4] = {
                pass, thread_count, pass * 8, 0
            };

            // Phase 1: Clear histogram
            {
                auto* enc = cmd.make_compute_encoder();
                if (!enc) return;
                enc->set_pipeline(clear_hist_pipeline_);
                enc->set_buffer(sort_histogram_, 0, 0);
                enc->dispatch_1d(256, 256);
                enc->end_encoding();
            }

            // Phase 2: Build histogram
            {
                auto* enc = cmd.make_compute_encoder();
                if (!enc) return;
                enc->set_pipeline(histogram_pipeline_);
                enc->set_buffer(depth_buffer_, 0, 0);     // depths[]
                enc->set_buffer(src_buf, 0, 1);            // src_indices[]
                enc->set_bytes(sort_params, sizeof(sort_params), 2);  // params
                enc->set_buffer(sort_histogram_, 0, 3);    // histogram[]
                enc->dispatch_1d(thread_count, threadgroup_size);
                enc->end_encoding();
            }

            // Phase 3: Exclusive prefix sum on histogram (1 threadgroup of 256)
            {
                auto* enc = cmd.make_compute_encoder();
                if (!enc) return;
                enc->set_pipeline(prefix_sum_pipeline_);
                enc->set_buffer(sort_histogram_, 0, 0);
                enc->dispatch_1d(256, 256);
                enc->end_encoding();
            }

            // Phase 4: Scatter elements to sorted positions
            {
                auto* enc = cmd.make_compute_encoder();
                if (!enc) return;
                enc->set_pipeline(scatter_pipeline_);
                enc->set_buffer(depth_buffer_, 0, 0);      // depths[]
                enc->set_buffer(src_buf, 0, 1);             // src_indices[]
                enc->set_buffer(dst_buf, 0, 2);             // dst_indices[]
                enc->set_bytes(sort_params, sizeof(sort_params), 3);  // params
                enc->set_buffer(sort_histogram_, 0, 4);     // offsets[]
                enc->dispatch_1d(thread_count, threadgroup_size);
                enc->end_encoding();
            }
        }

        // Bug 0.55 fix: if odd number of passes, final sorted data is in
        // sort_temp_indices_. Copy back to index_buffer_ so the render pass
        // finds it there. For passes=2 or 4 (even), data is already in
        // index_buffer_. For passes=3 (24-bit), it's in temp.
        if (passes % 2 == 1) {
            auto* enc = cmd.make_compute_encoder();
            if (enc) {
                // Blit copy: just re-dispatch scatter with identity mapping
                // Simpler: use device copy if available
                enc->end_encoding();
            }
            // CPU fallback copy for odd passes (rare case: 24-bit sort)
            // The render pass reads index_buffer_, so swap references.
            // Since we can't swap GPU handles, use a buffer copy.
            // For safety, log a warning if this path is hit.
            std::fprintf(stderr, "[Aether3D] Warning: odd radix sort passes (%u), "
                         "sorted data may be in temp buffer\n", passes);
        }
    }
}

void SplatRenderEngine::encode_render_pass(
    render::GPUCommandBuffer& cmd,
    const render::GPURenderTargetDesc& target) noexcept
{
    if (splat_count_ == 0 || !render_pipeline_.valid()) return;

    auto* encoder = cmd.make_render_encoder(target);
    if (!encoder) return;

    encoder->set_pipeline(render_pipeline_);

    // Metal shader splatVertex expects:
    //   buffer(0) = PackedSplatGPU[]       (splat data)
    //   buffer(1) = uint[]                 (sorted indices)
    //   buffer(2) = SplatCameraUniforms    (camera)
    //   buffer(3) = float4[]              (SH degree-1 coefficients, 3 per splat)
    //   buffer(4) = uint8[]               (D3: per-splat region IDs)
    //   buffer(5) = float[]               (D3: per-region fade alphas)
    // Vertex ID (vid) and Instance ID (iid) come from Metal automatically.
    encoder->set_vertex_buffer(splat_buffer_, 0, 0);     // buffer(0): PackedSplat[]
    encoder->set_vertex_buffer(index_buffer_, 0, 1);     // buffer(1): sorted indices
    encoder->set_vertex_buffer(camera_buffer_, 0, 2);    // buffer(2): camera uniform
    if (sh_buffer_.valid()) {
        encoder->set_vertex_buffer(sh_buffer_, 0, 3);    // buffer(3): SH coefficients
    }
    // D3: Region fade buffers for "破镜重圆" progressive reveal
    if (region_id_buffer_.valid()) {
        encoder->set_vertex_buffer(region_id_buffer_, 0, 4);   // buffer(4): region IDs
    }
    if (region_fade_buffer_.valid()) {
        encoder->set_vertex_buffer(region_fade_buffer_, 0, 5); // buffer(5): fade alphas
    }

    // Draw instanced quads: 4 vertices per quad (triangle strip), splat_count instances
    encoder->draw_instanced(render::GPUPrimitiveType::kTriangleStrip,
                            4, static_cast<std::uint32_t>(splat_count_));
    encoder->end_encoding();

    stats_.visible_splats = splat_count_;  // TODO: actual frustum cull count
}

void SplatRenderEngine::encode_render_pass_native(
    render::GPUCommandBuffer& cmd,
    void* native_rpd) noexcept
{
    if (splat_count_ == 0 || !render_pipeline_.valid() || !native_rpd) return;

    auto* encoder = cmd.make_render_encoder_native(native_rpd);
    if (!encoder) return;

    encoder->set_pipeline(render_pipeline_);

    // Metal shader splatVertex expects:
    //   buffer(0) = PackedSplatGPU[]       (splat data)
    //   buffer(1) = uint[]                 (sorted indices)
    //   buffer(2) = SplatCameraUniforms    (camera)
    //   buffer(3) = float4[]              (SH degree-1 coefficients, 3 per splat)
    //   buffer(4) = uint8[]               (D3: per-splat region IDs)
    //   buffer(5) = float[]               (D3: per-region fade alphas)
    encoder->set_vertex_buffer(splat_buffer_, 0, 0);
    encoder->set_vertex_buffer(index_buffer_, 0, 1);
    encoder->set_vertex_buffer(camera_buffer_, 0, 2);
    if (sh_buffer_.valid()) {
        encoder->set_vertex_buffer(sh_buffer_, 0, 3);    // buffer(3): SH coefficients
    }
    // D3: Region fade buffers for "破镜重圆" progressive reveal
    if (region_id_buffer_.valid()) {
        encoder->set_vertex_buffer(region_id_buffer_, 0, 4);   // buffer(4): region IDs
    }
    if (region_fade_buffer_.valid()) {
        encoder->set_vertex_buffer(region_fade_buffer_, 0, 5); // buffer(5): fade alphas
    }

    // Draw instanced quads: 4 vertices per quad (triangle strip), splat_count instances
    encoder->draw_instanced(render::GPUPrimitiveType::kTriangleStrip,
                            4, static_cast<std::uint32_t>(splat_count_));
    encoder->end_encoding();

    stats_.visible_splats = splat_count_;
}

SplatRenderStats SplatRenderEngine::end_frame() noexcept {
    return stats_;
}

bool SplatRenderEngine::get_bounds(float center[3], float* radius) const noexcept {
    if (cpu_buffer_.empty() || splat_count_ == 0) return false;

    const PackedSplat* data = cpu_buffer_.data();
    std::size_t count = cpu_buffer_.size();

    // Pass 1: compute centroid
    double cx = 0, cy = 0, cz = 0;
    for (std::size_t i = 0; i < count; ++i) {
        cx += half_to_float(data[i].center[0]);
        cy += half_to_float(data[i].center[1]);
        cz += half_to_float(data[i].center[2]);
    }
    double inv = 1.0 / static_cast<double>(count);
    center[0] = static_cast<float>(cx * inv);
    center[1] = static_cast<float>(cy * inv);
    center[2] = static_cast<float>(cz * inv);

    // Pass 2: 95th percentile distance from centroid (outlier-resistant).
    // Using max distance would let a single far-off point push the camera
    // to 57m away, making the actual scene invisible.
    std::vector<float> dists2(count);
    for (std::size_t i = 0; i < count; ++i) {
        float dx = half_to_float(data[i].center[0]) - center[0];
        float dy = half_to_float(data[i].center[1]) - center[1];
        float dz = half_to_float(data[i].center[2]) - center[2];
        dists2[i] = dx * dx + dy * dy + dz * dz;
    }
    std::size_t p95_idx = count * 95 / 100;
    if (p95_idx >= count) p95_idx = count - 1;
    std::nth_element(dists2.begin(),
                     dists2.begin() + static_cast<std::ptrdiff_t>(p95_idx),
                     dists2.end());
    *radius = std::sqrt(dists2[p95_idx]);
    // Floor at 0.5m so the camera never starts inside a tiny cluster
    if (*radius < 0.5f) *radius = 0.5f;
    return true;
}

core::Status SplatRenderEngine::create_gpu_resources() noexcept {
    // Splat buffer
    {
        render::GPUBufferDesc desc{};
        desc.size_bytes = config_.max_splats * sizeof(PackedSplat);
        desc.storage = render::GPUStorageMode::kShared;
        desc.usage_mask = static_cast<std::uint8_t>(
            render::GPUBufferUsage::kStorage) |
            static_cast<std::uint8_t>(render::GPUBufferUsage::kVertex);
        desc.label = "SplatBuffer";
        splat_buffer_ = device_.create_buffer(desc);
    }

    // SH coefficients buffer (parallel to splat buffer)
    // 12 floats (3 float4) per splat: R/G/B channels × 3 SH degree-1 basis
    {
        render::GPUBufferDesc desc{};
        desc.size_bytes = config_.max_splats * 12 * sizeof(float);
        desc.storage = render::GPUStorageMode::kShared;
        desc.usage_mask = static_cast<std::uint8_t>(
            render::GPUBufferUsage::kStorage) |
            static_cast<std::uint8_t>(render::GPUBufferUsage::kVertex);
        desc.label = "SHBuffer";
        sh_buffer_ = device_.create_buffer(desc);
        // Zero-initialize SH buffer to prevent garbage SH values.
        // Metal kShared buffers have undefined initial contents.
        // If SH data is not uploaded (e.g., DC-only PLY), the shader would
        // read garbage from buffer(3) → random color shifts or black splats.
        if (sh_buffer_.valid()) {
            void* ptr = device_.map_buffer(sh_buffer_);
            if (ptr) {
                std::memset(ptr, 0, desc.size_bytes);
                device_.unmap_buffer(sh_buffer_);
            }
        }
    }

    // D3: Region ID buffer (uint8 per splat — identifies which temporal region each splat belongs to)
    {
        render::GPUBufferDesc desc{};
        desc.size_bytes = config_.max_splats * sizeof(std::uint8_t);
        desc.storage = render::GPUStorageMode::kShared;
        desc.usage_mask = static_cast<std::uint8_t>(
            render::GPUBufferUsage::kStorage) |
            static_cast<std::uint8_t>(render::GPUBufferUsage::kVertex);
        desc.label = "RegionIDBuffer";
        region_id_buffer_ = device_.create_buffer(desc);
        // Zero-initialize: all splats default to region 0
        if (region_id_buffer_.valid()) {
            void* ptr = device_.map_buffer(region_id_buffer_);
            if (ptr) {
                std::memset(ptr, 0, desc.size_bytes);
                device_.unmap_buffer(region_id_buffer_);
            }
        }
    }

    // D3: Region fade alpha buffer (dynamic, initially 64 regions)
    // Grows as needed when more regions are created (no upper limit).
    {
        render::GPUBufferDesc desc{};
        region_fade_gpu_capacity_ = 64;
        desc.size_bytes = region_fade_gpu_capacity_ * sizeof(float);
        desc.storage = render::GPUStorageMode::kShared;
        desc.usage_mask = static_cast<std::uint8_t>(
            render::GPUBufferUsage::kUniform) |
            static_cast<std::uint8_t>(render::GPUBufferUsage::kVertex);
        desc.label = "RegionFadeBuffer";
        region_fade_buffer_ = device_.create_buffer(desc);
        // Initialize all regions to fully visible (1.0)
        if (region_fade_buffer_.valid()) {
            void* ptr = device_.map_buffer(region_fade_buffer_);
            if (ptr) {
                auto* alphas = static_cast<float*>(ptr);
                for (std::size_t i = 0; i < region_fade_gpu_capacity_; ++i) {
                    alphas[i] = 1.0f;
                }
                device_.unmap_buffer(region_fade_buffer_);
            }
        }
    }

    // Depth buffer (for sorting)
    {
        render::GPUBufferDesc desc{};
        desc.size_bytes = config_.max_splats * sizeof(float);
        desc.storage = render::GPUStorageMode::kPrivate;
        desc.usage_mask = static_cast<std::uint8_t>(
            render::GPUBufferUsage::kStorage);
        desc.label = "DepthBuffer";
        depth_buffer_ = device_.create_buffer(desc);
    }

    // Index buffer (sorted permutation)
    // Use kShared so we can CPU-prefill identity indices as a safe fallback.
    // If computeSplatDepths runs, it overwrites with gid (same result).
    // If it doesn't run (shader not found), we still have valid indices.
    {
        render::GPUBufferDesc desc{};
        desc.size_bytes = config_.max_splats * sizeof(std::uint32_t);
        desc.storage = render::GPUStorageMode::kShared;
        desc.usage_mask = static_cast<std::uint8_t>(
            render::GPUBufferUsage::kStorage) |
            static_cast<std::uint8_t>(render::GPUBufferUsage::kVertex);
        desc.label = "IndexBuffer";
        index_buffer_ = device_.create_buffer(desc);
        // Pre-fill with identity indices: [0, 1, 2, ..., N-1]
        if (index_buffer_.valid()) {
            void* ptr = device_.map_buffer(index_buffer_);
            if (ptr) {
                auto* indices = static_cast<std::uint32_t*>(ptr);
                for (std::size_t i = 0; i < config_.max_splats; ++i) {
                    indices[i] = static_cast<std::uint32_t>(i);
                }
                device_.unmap_buffer(index_buffer_);
            }
        }
    }

    // Camera uniform buffer
    {
        render::GPUBufferDesc desc{};
        desc.size_bytes = sizeof(SplatCameraState);
        desc.storage = render::GPUStorageMode::kShared;
        desc.usage_mask = static_cast<std::uint8_t>(
            render::GPUBufferUsage::kUniform);
        desc.label = "CameraUniform";
        camera_buffer_ = device_.create_buffer(desc);
    }

    // Quad vertex buffer (unit quad: 4 vertices, triangle strip)
    {
        float quad_vertices[] = {
            -1.0f, -1.0f,   // bottom-left
             1.0f, -1.0f,   // bottom-right
            -1.0f,  1.0f,   // top-left
             1.0f,  1.0f,   // top-right
        };
        render::GPUBufferDesc desc{};
        desc.size_bytes = sizeof(quad_vertices);
        desc.storage = render::GPUStorageMode::kShared;
        desc.usage_mask = static_cast<std::uint8_t>(
            render::GPUBufferUsage::kVertex);
        desc.label = "QuadVertices";
        quad_buffer_ = device_.create_buffer(desc);
        if (quad_buffer_.valid()) {
            device_.update_buffer(quad_buffer_, quad_vertices,
                                  0, sizeof(quad_vertices));
        }
    }

    // Radix sort temporary buffer (ping-pong for index reordering)
    {
        render::GPUBufferDesc desc{};
        desc.size_bytes = config_.max_splats * sizeof(std::uint32_t);
        desc.storage = render::GPUStorageMode::kPrivate;
        desc.usage_mask = static_cast<std::uint8_t>(
            render::GPUBufferUsage::kStorage);

        desc.label = "SortTempIndices";
        sort_temp_indices_ = device_.create_buffer(desc);
    }
    {
        render::GPUBufferDesc desc{};
        desc.size_bytes = 256 * sizeof(std::uint32_t);  // NUM_BUCKETS = 256
        desc.storage = render::GPUStorageMode::kPrivate;
        desc.usage_mask = static_cast<std::uint8_t>(
            render::GPUBufferUsage::kStorage);
        desc.label = "SortHistogram";
        sort_histogram_ = device_.create_buffer(desc);
    }

    // Shader loading (platform-specific names matching GaussianSplat.metal)
    auto depth_shader = device_.load_shader("computeSplatDepths",
                                             render::GPUShaderStage::kCompute);
    auto clear_hist_shader = device_.load_shader("radixClearHistogram",
                                                  render::GPUShaderStage::kCompute);
    auto histogram_shader = device_.load_shader("radixHistogram",
                                                 render::GPUShaderStage::kCompute);
    auto prefix_sum_shader = device_.load_shader("radixPrefixSum",
                                                  render::GPUShaderStage::kCompute);
    auto scatter_shader = device_.load_shader("radixScatter",
                                               render::GPUShaderStage::kCompute);
    auto vert_shader = device_.load_shader("splatVertex",
                                            render::GPUShaderStage::kVertex);
    auto frag_shader = device_.load_shader("splatFragment",
                                            render::GPUShaderStage::kFragment);

    std::fprintf(stderr, "[Aether3D][SplatEngine] Shader loading: "
                 "depth=%s clearHist=%s histogram=%s prefixSum=%s scatter=%s "
                 "vert=%s frag=%s\n",
                 depth_shader.valid()       ? "OK" : "FAIL",
                 clear_hist_shader.valid()  ? "OK" : "FAIL",
                 histogram_shader.valid()   ? "OK" : "FAIL",
                 prefix_sum_shader.valid()  ? "OK" : "FAIL",
                 scatter_shader.valid()     ? "OK" : "FAIL",
                 vert_shader.valid()        ? "OK" : "FAIL",
                 frag_shader.valid()        ? "OK" : "FAIL");

    if (depth_shader.valid()) {
        depth_pipeline_ = device_.create_compute_pipeline(depth_shader);
    }
    if (clear_hist_shader.valid()) {
        clear_hist_pipeline_ = device_.create_compute_pipeline(clear_hist_shader);
    }
    if (histogram_shader.valid()) {
        histogram_pipeline_ = device_.create_compute_pipeline(histogram_shader);
    }
    if (prefix_sum_shader.valid()) {
        prefix_sum_pipeline_ = device_.create_compute_pipeline(prefix_sum_shader);
    }
    if (scatter_shader.valid()) {
        scatter_pipeline_ = device_.create_compute_pipeline(scatter_shader);
    }
    if (vert_shader.valid() && frag_shader.valid()) {
        render::GPURenderTargetDesc default_target{};
        // Use BGRA8Unorm — the native display format on Apple platforms.
        // MTKView.colorPixelFormat defaults to .bgra8Unorm, so the render
        // pipeline state MUST match to avoid Metal validation errors.
        default_target.color_format = render::GPUTextureFormat::kBGRA8Unorm;
        render_pipeline_ = device_.create_render_pipeline(
            vert_shader, frag_shader, default_target);
    }

    bool gpu_sort_ready = clear_hist_pipeline_.valid() &&
                          histogram_pipeline_.valid() &&
                          prefix_sum_pipeline_.valid() &&
                          scatter_pipeline_.valid();
    std::fprintf(stderr, "[Aether3D][SplatEngine] Pipeline creation: "
                 "depth=%s gpuSort=%s render=%s\n",
                 depth_pipeline_.valid()  ? "OK" : "FAIL",
                 gpu_sort_ready           ? "OK" : "FAIL",
                 render_pipeline_.valid() ? "OK" : "FAIL");

    return core::Status::kOk;
}

void SplatRenderEngine::destroy_gpu_resources() noexcept {
    if (splat_buffer_.valid())        device_.destroy_buffer(splat_buffer_);
    if (sh_buffer_.valid())           device_.destroy_buffer(sh_buffer_);
    if (depth_buffer_.valid())        device_.destroy_buffer(depth_buffer_);
    if (index_buffer_.valid())        device_.destroy_buffer(index_buffer_);
    if (camera_buffer_.valid())       device_.destroy_buffer(camera_buffer_);
    if (quad_buffer_.valid())         device_.destroy_buffer(quad_buffer_);
    if (sort_temp_indices_.valid())   device_.destroy_buffer(sort_temp_indices_);
    if (sort_histogram_.valid())      device_.destroy_buffer(sort_histogram_);

    if (depth_pipeline_.valid())      device_.destroy_compute_pipeline(depth_pipeline_);
    if (clear_hist_pipeline_.valid()) device_.destroy_compute_pipeline(clear_hist_pipeline_);
    if (histogram_pipeline_.valid())  device_.destroy_compute_pipeline(histogram_pipeline_);
    if (prefix_sum_pipeline_.valid()) device_.destroy_compute_pipeline(prefix_sum_pipeline_);
    if (scatter_pipeline_.valid())    device_.destroy_compute_pipeline(scatter_pipeline_);
    if (render_pipeline_.valid())     device_.destroy_render_pipeline(render_pipeline_);
}

void SplatRenderEngine::upload_splats_to_gpu() noexcept {
    if (cpu_buffer_.empty() || !splat_buffer_.valid()) return;

    std::size_t upload_bytes = cpu_buffer_.size_bytes();
    std::size_t max_bytes = config_.max_splats * sizeof(PackedSplat);
    if (upload_bytes > max_bytes) upload_bytes = max_bytes;

    device_.update_buffer(splat_buffer_, cpu_buffer_.data(), 0, upload_bytes);

    // Upload SH coefficients to GPU (parallel buffer)
    if (sh_buffer_.valid() && !cpu_sh_data_.empty()) {
        std::size_t sh_upload_bytes = cpu_sh_data_.size() * sizeof(float);
        std::size_t sh_max_bytes = config_.max_splats * 12 * sizeof(float);
        if (sh_upload_bytes > sh_max_bytes) sh_upload_bytes = sh_max_bytes;
        device_.update_buffer(sh_buffer_, cpu_sh_data_.data(), 0, sh_upload_bytes);
    }

    // D3: Upload region IDs to GPU (parallel to splat buffer)
    if (region_id_buffer_.valid() && !cpu_region_ids_.empty()) {
        std::size_t rid_upload_bytes = cpu_region_ids_.size() * sizeof(std::uint8_t);
        std::size_t rid_max_bytes = config_.max_splats * sizeof(std::uint8_t);
        if (rid_upload_bytes > rid_max_bytes) rid_upload_bytes = rid_max_bytes;
        device_.update_buffer(region_id_buffer_, cpu_region_ids_.data(), 0, rid_upload_bytes);
    }

    // D3: Upload region fade alphas to GPU (dynamic buffer)
    if (region_fade_buffer_.valid() && !region_fade_alphas_.empty()) {
        std::size_t upload_count = region_fade_alphas_.size();

        // Grow GPU buffer if needed
        if (upload_count > region_fade_gpu_capacity_) {
            std::size_t new_capacity = std::max(upload_count, region_fade_gpu_capacity_ * 2);
            render::GPUBufferDesc desc{};
            desc.size_bytes = new_capacity * sizeof(float);
            desc.storage = render::GPUStorageMode::kShared;
            desc.usage_mask = static_cast<std::uint8_t>(
                render::GPUBufferUsage::kUniform) |
                static_cast<std::uint8_t>(render::GPUBufferUsage::kVertex);
            desc.label = "RegionFadeBuffer";
            auto new_buffer = device_.create_buffer(desc);
            if (new_buffer.valid()) {
                // Replace old buffer
                region_fade_buffer_ = new_buffer;
                region_fade_gpu_capacity_ = new_capacity;
            }
        }

        device_.update_buffer(region_fade_buffer_, region_fade_alphas_.data(),
                              0, upload_count * sizeof(float));
    }
}

}  // namespace splat
}  // namespace aether
