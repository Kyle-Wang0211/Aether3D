// SPDX-License-Identifier: LicenseRef-Aether3D-Proprietary
// Copyright (c) 2024-2026 Aether3D. All rights reserved.

#include "aether_detector_free_depth_c.h"

#include <algorithm>
#include <csetjmp>
#include <cmath>
#include <cstddef>
#include <cstdint>
#include <cstdio>
#include <cstring>
#include <fstream>
#include <limits>
#include <memory>
#include <mutex>
#include <new>
#include <string>
#include <vector>

#include "jpeglib.h"

#if defined(AETHER_ENABLE_DAWN)
#include "aether/render/dawn_gpu_device.h"
#include "aether/render/gpu_command.h"
#include "aether/render/gpu_device.h"
#include "aether/shaders/wgsl_sources.h"
#endif

namespace {

bool finite(float value);
bool checked_multiply(std::size_t lhs,
                      std::size_t rhs,
                      std::size_t* output);

constexpr int kPreprocessWidth = AETHER_DETECTOR_FREE_IMAGE_WIDTH;
constexpr int kPreprocessHeight = AETHER_DETECTOR_FREE_IMAGE_HEIGHT;
constexpr int kMaximumDecodedSide = 8192;
constexpr std::size_t kMaximumDecodedPixels =
    static_cast<std::size_t>(kMaximumDecodedSide) * kMaximumDecodedSide;

struct AreaContribution {
    int source_index = 0;
    float weight = 0.0f;
};

struct AreaAxis {
    std::vector<std::size_t> offsets;
    std::vector<AreaContribution> contributions;
};

struct JpegErrorState {
    jpeg_error_mgr manager{};
    std::jmp_buf jump_buffer{};
};

void detector_free_jpeg_error_exit(j_common_ptr decoder) {
    auto* const error = reinterpret_cast<JpegErrorState*>(decoder->err);
    std::longjmp(error->jump_buffer, 1);
}

void detector_free_jpeg_output_message(j_common_ptr) {
    // Malformed or partially written capture files are reported through the
    // ABI return code. Never write decoder warnings to a product console.
}

bool decode_jpeg_rgb(const std::uint8_t* jpeg_bytes,
                     std::size_t jpeg_byte_count,
                     std::vector<std::uint8_t>* output_rgb,
                     int* output_width,
                     int* output_height) {
    if (!jpeg_bytes || jpeg_byte_count == 0 || !output_rgb || !output_width ||
        !output_height ||
        jpeg_byte_count >
            static_cast<std::size_t>(
                std::numeric_limits<unsigned long>::max())) {
        return false;
    }

    jpeg_decompress_struct decoder{};
    JpegErrorState error{};
    decoder.err = jpeg_std_error(&error.manager);
    error.manager.error_exit = detector_free_jpeg_error_exit;
    error.manager.output_message = detector_free_jpeg_output_message;
    // This flag is read after longjmp, so it must be volatile per setjmp's
    // rules for locals modified after the checkpoint.
    volatile bool decoder_created = false;
    if (setjmp(error.jump_buffer) != 0) {
        if (decoder_created) jpeg_destroy_decompress(&decoder);
        output_rgb->clear();
        *output_width = 0;
        *output_height = 0;
        return false;
    }

    jpeg_create_decompress(&decoder);
    decoder_created = true;
    jpeg_mem_src(&decoder, jpeg_bytes,
                 static_cast<unsigned long>(jpeg_byte_count));
    if (jpeg_read_header(&decoder, TRUE) != JPEG_HEADER_OK) {
        jpeg_destroy_decompress(&decoder);
        return false;
    }
    decoder.out_color_space = JCS_RGB;
    if (jpeg_start_decompress(&decoder) == FALSE ||
        decoder.output_components != 3 ||
        decoder.output_width < static_cast<JDIMENSION>(kPreprocessWidth) ||
        decoder.output_height < static_cast<JDIMENSION>(kPreprocessHeight) ||
        decoder.output_width > static_cast<JDIMENSION>(kMaximumDecodedSide) ||
        decoder.output_height > static_cast<JDIMENSION>(kMaximumDecodedSide)) {
        jpeg_destroy_decompress(&decoder);
        return false;
    }

    const std::size_t width = decoder.output_width;
    const std::size_t height = decoder.output_height;
    std::size_t pixel_count = 0;
    std::size_t byte_count = 0;
    if (!checked_multiply(width, height, &pixel_count) ||
        pixel_count > kMaximumDecodedPixels ||
        !checked_multiply(pixel_count, 3, &byte_count)) {
        jpeg_destroy_decompress(&decoder);
        return false;
    }
    output_rgb->resize(byte_count);
    const std::size_t row_bytes = width * 3;
    while (decoder.output_scanline < decoder.output_height) {
        JSAMPROW row = output_rgb->data() +
            static_cast<std::size_t>(decoder.output_scanline) * row_bytes;
        if (jpeg_read_scanlines(&decoder, &row, 1) != 1) {
            jpeg_destroy_decompress(&decoder);
            output_rgb->clear();
            return false;
        }
    }
    if (jpeg_finish_decompress(&decoder) == FALSE) {
        jpeg_destroy_decompress(&decoder);
        output_rgb->clear();
        return false;
    }
    jpeg_destroy_decompress(&decoder);
    decoder_created = false;
    *output_width = static_cast<int>(width);
    *output_height = static_cast<int>(height);
    return true;
}

bool build_area_axis(int source_size, int output_size, AreaAxis* output) {
    if (!output || source_size <= 0 || output_size <= 0 ||
        output_size > source_size) {
        return false;
    }
    output->offsets.clear();
    output->contributions.clear();
    output->offsets.reserve(static_cast<std::size_t>(output_size) + 1);
    output->offsets.push_back(0);
    const double scale = static_cast<double>(source_size) / output_size;
    for (int destination = 0; destination < output_size; ++destination) {
        const double begin = destination * scale;
        const double end = (destination + 1) * scale;
        const int first = static_cast<int>(std::floor(begin));
        const int last = std::min(
            source_size - 1, static_cast<int>(std::ceil(end)) - 1);
        for (int source = first; source <= last; ++source) {
            const double overlap = std::max(
                0.0, std::min(end, static_cast<double>(source + 1)) -
                         std::max(begin, static_cast<double>(source)));
            if (overlap > 0.0) {
                output->contributions.push_back(AreaContribution{
                    source, static_cast<float>(overlap / scale)});
            }
        }
        output->offsets.push_back(output->contributions.size());
    }
    return true;
}

std::uint8_t saturating_round_u8(double value) {
    const long rounded = std::lround(value);
    return static_cast<std::uint8_t>(std::clamp<long>(rounded, 0, 255));
}

bool resize_rgb_area(const std::uint8_t* source_rgb,
                     int source_width,
                     int source_height,
                     std::uint8_t* output_rgb) {
    if (!source_rgb || !output_rgb || source_width < kPreprocessWidth ||
        source_height < kPreprocessHeight) {
        return false;
    }
    // OpenCV INTER_AREA has an exact integer-decimation fast path. iPhone
    // capture JPEGs are 3840x2160, so the frozen 128x72 grid is exactly a
    // 30x30 box. Accumulate integer source values and use round-to-nearest,
    // ties-to-even (nearbyint under the default IEEE mode), matching cvRound.
    // Besides eliminating a float-weight rounding drift, this avoids the
    // intermediate image allocation for the production dimensions.
    if (source_width % kPreprocessWidth == 0 &&
        source_height % kPreprocessHeight == 0) {
        const int scale_x = source_width / kPreprocessWidth;
        const int scale_y = source_height / kPreprocessHeight;
        const double area = static_cast<double>(scale_x) * scale_y;
        for (int output_y = 0; output_y < kPreprocessHeight; ++output_y) {
            for (int output_x = 0; output_x < kPreprocessWidth; ++output_x) {
                std::uint64_t sums[3] = {0, 0, 0};
                for (int y = 0; y < scale_y; ++y) {
                    const int source_y = output_y * scale_y + y;
                    const std::size_t row_offset =
                        (static_cast<std::size_t>(source_y) * source_width +
                         output_x * scale_x) * 3;
                    for (int x = 0; x < scale_x; ++x) {
                        const std::size_t source_offset = row_offset + x * 3;
                        sums[0] += source_rgb[source_offset];
                        sums[1] += source_rgb[source_offset + 1];
                        sums[2] += source_rgb[source_offset + 2];
                    }
                }
                const std::size_t output_offset =
                    (static_cast<std::size_t>(output_y) * kPreprocessWidth +
                     output_x) * 3;
                for (int channel = 0; channel < 3; ++channel) {
                    output_rgb[output_offset + channel] =
                        static_cast<std::uint8_t>(std::nearbyint(
                            static_cast<double>(sums[channel]) / area));
                }
            }
        }
        return true;
    }
    AreaAxis horizontal;
    AreaAxis vertical;
    if (!build_area_axis(source_width, kPreprocessWidth, &horizontal) ||
        !build_area_axis(source_height, kPreprocessHeight, &vertical)) {
        return false;
    }

    std::size_t intermediate_count = 0;
    if (!checked_multiply(static_cast<std::size_t>(source_height),
                          static_cast<std::size_t>(kPreprocessWidth * 3),
                          &intermediate_count)) {
        return false;
    }
    std::vector<float> horizontally_resized(intermediate_count, 0.0f);
    for (int y = 0; y < source_height; ++y) {
        for (int x = 0; x < kPreprocessWidth; ++x) {
            const std::size_t contribution_begin = horizontal.offsets[x];
            const std::size_t contribution_end = horizontal.offsets[x + 1];
            for (int channel = 0; channel < 3; ++channel) {
                double value = 0.0;
                for (std::size_t index = contribution_begin;
                     index < contribution_end; ++index) {
                    const AreaContribution& contribution =
                        horizontal.contributions[index];
                    const std::size_t source_offset =
                        (static_cast<std::size_t>(y) * source_width +
                         contribution.source_index) * 3 + channel;
                    value += source_rgb[source_offset] * contribution.weight;
                }
                horizontally_resized[
                    (static_cast<std::size_t>(y) * kPreprocessWidth + x) * 3 +
                    channel] = static_cast<float>(value);
            }
        }
    }

    for (int y = 0; y < kPreprocessHeight; ++y) {
        const std::size_t contribution_begin = vertical.offsets[y];
        const std::size_t contribution_end = vertical.offsets[y + 1];
        for (int x = 0; x < kPreprocessWidth; ++x) {
            for (int channel = 0; channel < 3; ++channel) {
                double value = 0.0;
                for (std::size_t index = contribution_begin;
                     index < contribution_end; ++index) {
                    const AreaContribution& contribution =
                        vertical.contributions[index];
                    const std::size_t intermediate_offset =
                        (static_cast<std::size_t>(contribution.source_index) *
                             kPreprocessWidth +
                         x) * 3 + channel;
                    value += horizontally_resized[intermediate_offset] *
                        contribution.weight;
                }
                output_rgb[(static_cast<std::size_t>(y) * kPreprocessWidth + x) *
                               3 + channel] = saturating_round_u8(value);
            }
        }
    }
    return true;
}

std::uint8_t rgb_to_opencv_gray(std::uint8_t red,
                                std::uint8_t green,
                                std::uint8_t blue) {
    // OpenCV RGB2Gray uses a dedicated 15-bit coefficient set (not the
    // 14-bit RGB->YUV coefficients): RY15=9798, GY15=19235, BY15=3735.
    // The half-unit bias implements CV_DESCALE exactly.
    constexpr int shift = 15;
    constexpr int rounding = 1 << (shift - 1);
    const int gray = 9798 * static_cast<int>(red) +
        19235 * static_cast<int>(green) +
        3735 * static_cast<int>(blue) + rounding;
    return static_cast<std::uint8_t>(gray >> shift);
}

bool valid_intrinsics(const float* source_k) {
    if (!source_k) return false;
    for (int index = 0; index < 9; ++index) {
        if (!finite(source_k[index])) return false;
    }
    return true;
}

int32_t preprocess_decoded_rgb(
    const std::uint8_t* source_rgb,
    int source_width,
    int source_height,
    const float source_k[9],
    std::uint8_t* output_rgb,
    std::size_t rgb_capacity,
    std::uint8_t* output_gray_u8,
    std::size_t gray_u8_capacity,
    float* output_gray_f32,
    std::size_t gray_f32_capacity,
    aether_detector_free_preprocessed_image_t* output_image) {
    constexpr std::size_t pixels = AETHER_DETECTOR_FREE_IMAGE_PIXELS;
    constexpr std::size_t rgb_bytes = AETHER_DETECTOR_FREE_IMAGE_RGB_BYTES;
    if (!source_rgb || source_width < kPreprocessWidth ||
        source_height < kPreprocessHeight ||
        source_width > kMaximumDecodedSide ||
        source_height > kMaximumDecodedSide || !valid_intrinsics(source_k) ||
        !output_rgb || !output_gray_u8 || !output_gray_f32 || !output_image) {
        return AETHER_DETECTOR_FREE_ERR_BAD_ARGS;
    }
    if (rgb_capacity < rgb_bytes || gray_u8_capacity < pixels ||
        gray_f32_capacity < pixels) {
        return AETHER_DETECTOR_FREE_ERR_BUFFER_TOO_SMALL;
    }
    if (!resize_rgb_area(source_rgb, source_width, source_height, output_rgb)) {
        return AETHER_DETECTOR_FREE_ERR_INTERNAL;
    }
    for (std::size_t pixel = 0; pixel < pixels; ++pixel) {
        const std::uint8_t gray = rgb_to_opencv_gray(
            output_rgb[pixel * 3], output_rgb[pixel * 3 + 1],
            output_rgb[pixel * 3 + 2]);
        output_gray_u8[pixel] = gray;
        output_gray_f32[pixel] = static_cast<float>(gray);
    }
    std::memset(output_image, 0, sizeof(*output_image));
    output_image->source_width = source_width;
    output_image->source_height = source_height;
    output_image->output_width = kPreprocessWidth;
    output_image->output_height = kPreprocessHeight;
    output_image->scale_x =
        static_cast<float>(kPreprocessWidth) / source_width;
    output_image->scale_y =
        static_cast<float>(kPreprocessHeight) / source_height;
    for (int row = 0; row < 3; ++row) {
        const float scale = row == 0 ? output_image->scale_x
            : (row == 1 ? output_image->scale_y : 1.0f);
        for (int column = 0; column < 3; ++column) {
            output_image->scaled_k_row_major_3x3[row * 3 + column] =
                source_k[row * 3 + column] * scale;
        }
    }
    return AETHER_DETECTOR_FREE_OK;
}

int32_t preprocess_jpeg_memory(
    const std::uint8_t* jpeg_bytes,
    std::size_t jpeg_byte_count,
    const float source_k[9],
    std::uint8_t* output_rgb,
    std::size_t rgb_capacity,
    std::uint8_t* output_gray_u8,
    std::size_t gray_u8_capacity,
    float* output_gray_f32,
    std::size_t gray_f32_capacity,
    aether_detector_free_preprocessed_image_t* output_image) {
    if (output_image) std::memset(output_image, 0, sizeof(*output_image));
    if (!jpeg_bytes || jpeg_byte_count == 0 ||
        !valid_intrinsics(source_k) || !output_rgb || !output_gray_u8 ||
        !output_gray_f32 || !output_image) {
        return AETHER_DETECTOR_FREE_ERR_BAD_ARGS;
    }
    constexpr std::size_t pixels = AETHER_DETECTOR_FREE_IMAGE_PIXELS;
    constexpr std::size_t rgb_bytes = AETHER_DETECTOR_FREE_IMAGE_RGB_BYTES;
    if (rgb_capacity < rgb_bytes || gray_u8_capacity < pixels ||
        gray_f32_capacity < pixels) {
        return AETHER_DETECTOR_FREE_ERR_BUFFER_TOO_SMALL;
    }
    int source_width = 0;
    int source_height = 0;
    std::vector<std::uint8_t> decoded;
    if (!decode_jpeg_rgb(jpeg_bytes, jpeg_byte_count, &decoded, &source_width,
                         &source_height)) {
        return AETHER_DETECTOR_FREE_ERR_BAD_ARGS;
    }
    return preprocess_decoded_rgb(
        decoded.data(), source_width, source_height, source_k, output_rgb,
        rgb_capacity, output_gray_u8, gray_u8_capacity, output_gray_f32,
        gray_f32_capacity, output_image);
}

bool finite(float value) {
    return std::isfinite(value);
}

bool checked_multiply(std::size_t lhs,
                      std::size_t rhs,
                      std::size_t* output) {
    if (!output || (lhs != 0 && rhs > std::numeric_limits<std::size_t>::max() / lhs)) {
        return false;
    }
    *output = lhs * rhs;
    return true;
}

bool valid_options(const aether_detector_free_options_t& options,
                   std::size_t* image_pixels,
                   std::size_t* maximum_tile_pixels) {
    if (options.image_width <= 2 || options.image_height <= 2 ||
        options.image_width > 8192 || options.image_height > 8192 ||
        options.max_tile_width <= 0 || options.max_tile_height <= 0 ||
        options.max_tile_width > options.image_width ||
        options.max_tile_height > options.image_height ||
        options.depth_count < 2 || options.depth_count > 64 ||
        options.source_count < 1 || options.source_count > 8 ||
        options.patch_n < 1 || options.patch_n > 5 ||
        options.patch_n % 2 == 0 || options.minimum_views < 1 ||
        options.minimum_views > options.source_count ||
        options.exclusion_radius_samples < 0 ||
        options.exclusion_radius_samples >= options.depth_count ||
        !finite(options.minimum_std_u8) || options.minimum_std_u8 <= 0.0f ||
        !finite(options.ncc_min) || options.ncc_min < 0.0f ||
        options.ncc_min > 1.0f || !finite(options.unique_depth_margin) ||
        options.unique_depth_margin < 0.0f ||
        options.unique_depth_margin > 2.0f ||
        !finite(options.inverse_depth_first) ||
        !finite(options.inverse_depth_step) ||
        options.inverse_depth_step == 0.0f) {
        return false;
    }
    const float inverse_depth_last = options.inverse_depth_first +
        static_cast<float>(options.depth_count - 1) * options.inverse_depth_step;
    if (!(options.inverse_depth_first > 0.0f) ||
        !(inverse_depth_last > 0.0f)) {
        return false;
    }
    for (const float value : options.reference_inverse_k_row_major_3x3) {
        if (!finite(value)) return false;
    }
    return checked_multiply(
               static_cast<std::size_t>(options.image_width),
               static_cast<std::size_t>(options.image_height), image_pixels) &&
        checked_multiply(
               static_cast<std::size_t>(options.max_tile_width),
               static_cast<std::size_t>(options.max_tile_height),
               maximum_tile_pixels);
}

struct GpuRefineInput {
    std::uint32_t best_index;
    std::uint32_t accepted;
};
static_assert(sizeof(GpuRefineInput) == 8);

#if defined(AETHER_ENABLE_DAWN)

using aether::render::GPUBufferDesc;
using aether::render::GPUBufferHandle;
using aether::render::GPUBufferUsage;
using aether::render::GPUComputePipelineHandle;
using aether::render::GPUDevice;
using aether::render::GPUShaderStage;
using aether::render::GPUStorageMode;

struct alignas(16) GpuParams {
    std::uint32_t image_width;
    std::uint32_t image_height;
    std::uint32_t image_pixel_count;
    std::uint32_t tile_origin_x;
    std::uint32_t tile_origin_y;
    std::uint32_t tile_width;
    std::uint32_t tile_height;
    std::uint32_t tile_pixel_count;
    std::uint32_t depth_count;
    std::uint32_t source_count;
    std::uint32_t patch_n;
    std::uint32_t minimum_views;
    std::uint32_t exclusion_radius;
    std::uint32_t padding_u0;
    std::uint32_t padding_u1;
    std::uint32_t padding_u2;
    float minimum_std_u8;
    float ncc_min;
    float depth_margin;
    float inverse_depth_first;
    float inverse_depth_step;
    float padding0;
    float padding1;
    float padding2;
    float inverse_k0[4];
    float inverse_k1[4];
    float inverse_k2[4];
};
static_assert(sizeof(GpuParams) == 144);

struct GpuOutput {
    std::uint32_t best_index;
    float interpolated_depth_m;
    float best_score;
    float second_score;
    std::uint32_t views;
    std::uint32_t accepted;
};
static_assert(sizeof(GpuOutput) == 24);

struct GpuRefinedOutput {
    float depth_m;
    float best_score;
    float second_score;
    std::uint32_t supporting_views;
    std::uint32_t accepted;
};
static_assert(sizeof(GpuRefinedOutput) == 20);

GPUBufferHandle make_buffer(GPUDevice& device,
                            std::size_t bytes,
                            GPUBufferUsage usage,
                            GPUStorageMode storage,
                            const char* label) {
    GPUBufferDesc descriptor{};
    descriptor.size_bytes = bytes;
    descriptor.storage = storage;
    descriptor.usage_mask = static_cast<std::uint8_t>(usage);
    descriptor.label = label;
    return device.create_buffer(descriptor);
}

bool readback_output(GPUDevice& device,
                     GPUBufferHandle source,
                     std::size_t count,
                     std::vector<GpuOutput>* output) {
    if (!output) return false;
    const std::size_t bytes = count * sizeof(GpuOutput);
    const auto staging = make_buffer(
        device, bytes, GPUBufferUsage::kStaging, GPUStorageMode::kShared,
        "detector_free_readback");
    if (!staging.valid() || !aether::render::dawn_copy_buffer_to_buffer(
                                device, source, staging, bytes)) {
        if (staging.valid()) device.destroy_buffer(staging);
        return false;
    }
    void* mapped = device.map_buffer(staging);
    if (!mapped) {
        device.destroy_buffer(staging);
        return false;
    }
    output->resize(count);
    std::memcpy(output->data(), mapped, bytes);
    device.unmap_buffer(staging);
    device.destroy_buffer(staging);
    return true;
}

bool readback_refined_output(GPUDevice& device,
                             GPUBufferHandle source,
                             std::size_t count,
                             std::vector<GpuRefinedOutput>* output) {
    if (!output) return false;
    const std::size_t bytes = count * sizeof(GpuRefinedOutput);
    const auto staging = make_buffer(
        device, bytes, GPUBufferUsage::kStaging, GPUStorageMode::kShared,
        "detector_free_refined_readback");
    if (!staging.valid() || !aether::render::dawn_copy_buffer_to_buffer(
                                device, source, staging, bytes)) {
        if (staging.valid()) device.destroy_buffer(staging);
        return false;
    }
    void* mapped = device.map_buffer(staging);
    if (!mapped) {
        device.destroy_buffer(staging);
        return false;
    }
    output->resize(count);
    std::memcpy(output->data(), mapped, bytes);
    device.unmap_buffer(staging);
    device.destroy_buffer(staging);
    return true;
}

struct DetectorFreeRuntime {
    std::mutex execution_mutex;
    std::unique_ptr<GPUDevice> device;
    GPUComputePipelineHandle coarse_pipeline{};
    GPUComputePipelineHandle refine_pipeline{};

    ~DetectorFreeRuntime() {
        if (!device) return;
        if (coarse_pipeline.valid()) {
            device->destroy_compute_pipeline(coarse_pipeline);
        }
        if (refine_pipeline.valid()) {
            device->destroy_compute_pipeline(refine_pipeline);
        }
    }
};

std::shared_ptr<DetectorFreeRuntime> acquire_detector_free_runtime() {
    // [DETOX 2026-08-07 用户签决"摘三装机"] plane-sweep 判死残留摘除:
    // sweep / refine 两个 shader 已不再烘焙(源移入
    // shaders/wgsl_attic_planesweep/),GPU runtime 永久不可用。走既有
    // 优雅失败路径 return {} —— C ABI 保留,调用方拿到 unavailable。
    return {};
}

#endif  // AETHER_ENABLE_DAWN

}  // namespace

struct aether_detector_free_session {
    aether_detector_free_options_t options{};
    std::size_t image_pixels = 0;
    std::size_t maximum_tile_pixels = 0;
    std::mutex mutex;
#if defined(AETHER_ENABLE_DAWN)
    GpuParams params{};
    std::shared_ptr<DetectorFreeRuntime> runtime;
    GPUBufferHandle gray{};
    GPUBufferHandle projections{};
    GPUBufferHandle params_buffer{};
    GPUBufferHandle output{};
    GPUBufferHandle refine_input{};
    GPUBufferHandle refine_output{};
#endif
};

extern "C" {

int32_t aether_detector_free_preprocess_jpeg_bytes(
    const uint8_t* jpeg_bytes,
    size_t jpeg_byte_count,
    const float source_k_row_major_3x3[9],
    uint8_t* out_rgb_u8,
    size_t rgb_capacity_bytes,
    uint8_t* out_gray_u8,
    size_t gray_u8_capacity,
    float* out_gray_f32,
    size_t gray_f32_capacity,
    aether_detector_free_preprocessed_image_t* out_image) {
    return preprocess_jpeg_memory(
        jpeg_bytes, jpeg_byte_count, source_k_row_major_3x3, out_rgb_u8,
        rgb_capacity_bytes, out_gray_u8, gray_u8_capacity, out_gray_f32,
        gray_f32_capacity, out_image);
}

int32_t aether_detector_free_preprocess_jpeg_path(
    const char* jpeg_path,
    const float source_k_row_major_3x3[9],
    uint8_t* out_rgb_u8,
    size_t rgb_capacity_bytes,
    uint8_t* out_gray_u8,
    size_t gray_u8_capacity,
    float* out_gray_f32,
    size_t gray_f32_capacity,
    aether_detector_free_preprocessed_image_t* out_image) {
    if (out_image) std::memset(out_image, 0, sizeof(*out_image));
    if (!jpeg_path || jpeg_path[0] == '\0' ||
        !valid_intrinsics(source_k_row_major_3x3) || !out_rgb_u8 ||
        !out_gray_u8 || !out_gray_f32 || !out_image) {
        return AETHER_DETECTOR_FREE_ERR_BAD_ARGS;
    }
#if defined(__EMSCRIPTEN__)
    (void)rgb_capacity_bytes;
    (void)gray_u8_capacity;
    (void)gray_f32_capacity;
    return AETHER_DETECTOR_FREE_ERR_UNSUPPORTED;
#else
    std::ifstream input(jpeg_path, std::ios::binary | std::ios::ate);
    if (!input) return AETHER_DETECTOR_FREE_ERR_BAD_ARGS;
    const std::streamoff byte_count = input.tellg();
    if (byte_count <= 0 ||
        static_cast<std::uintmax_t>(byte_count) >
            static_cast<std::uintmax_t>(std::numeric_limits<int>::max())) {
        return AETHER_DETECTOR_FREE_ERR_BAD_ARGS;
    }
    std::vector<std::uint8_t> compressed(
        static_cast<std::size_t>(byte_count));
    input.seekg(0, std::ios::beg);
    if (!input.read(reinterpret_cast<char*>(compressed.data()), byte_count)) {
        return AETHER_DETECTOR_FREE_ERR_BAD_ARGS;
    }
    return preprocess_jpeg_memory(
        compressed.data(), compressed.size(), source_k_row_major_3x3,
        out_rgb_u8, rgb_capacity_bytes, out_gray_u8, gray_u8_capacity,
        out_gray_f32, gray_f32_capacity, out_image);
#endif
}

void aether_detector_free_options_default(
    aether_detector_free_options_t* out_options) {
    if (!out_options) return;
    std::memset(out_options, 0, sizeof(*out_options));
    out_options->max_tile_width = 128;
    out_options->max_tile_height = 72;
    out_options->depth_count = 48;
    out_options->source_count = 7;
    out_options->patch_n = 5;
    out_options->minimum_views = 4;
    out_options->exclusion_radius_samples = 2;
    out_options->minimum_std_u8 = 6.0f;
    out_options->ncc_min = 0.75f;
    out_options->unique_depth_margin = 0.03f;
}

void aether_detector_free_reciprocal_options_default(
    aether_detector_free_reciprocal_options_t* out_options) {
    if (!out_options) return;
    out_options->minimum_reciprocal_views = 2;
    out_options->absolute_depth_tolerance_m = 0.08f;
    out_options->relative_depth_tolerance = 0.05f;
    out_options->minimum_parallax_deg = 8.0f;
}

void aether_detector_free_refine_options_default(
    aether_detector_free_refine_options_t* out_options) {
    if (!out_options) return;
    out_options->fine_depth_count = 17;
    out_options->coarse_step_span = 1.0f;
    out_options->uniqueness_absolute_m = 0.08f;
    out_options->uniqueness_relative = 0.05f;
}

int32_t aether_detector_free_filter_reciprocal_births(
    int32_t image_width,
    int32_t image_height,
    int32_t depth_count,
    float inverse_depth_first,
    float inverse_depth_step,
    const float reference_inverse_k_row_major_3x3[9],
    const uint16_t* reference_best_index,
    const uint8_t* reference_accepted,
    int32_t reciprocal_view_count,
    const uint16_t* reciprocal_best_indices,
    const uint8_t* reciprocal_accepted,
    const float* reference_to_reciprocal_projections_row_major_3x4,
    const float* reciprocal_camera_centers_in_reference_xyz,
    const aether_detector_free_reciprocal_options_t* options,
    uint8_t* out_consistent_views,
    uint8_t* out_birth,
    int32_t output_capacity) {
    if (image_width <= 0 || image_height <= 0 || depth_count < 2 ||
        depth_count > 65535 || !finite(inverse_depth_first) ||
        !finite(inverse_depth_step) || inverse_depth_step == 0.0f ||
        !reference_inverse_k_row_major_3x3 || !reference_best_index ||
        !reference_accepted || reciprocal_view_count <= 0 ||
        reciprocal_view_count > 255 || !reciprocal_best_indices ||
        !reciprocal_accepted ||
        !reference_to_reciprocal_projections_row_major_3x4 ||
        !reciprocal_camera_centers_in_reference_xyz || !options ||
        !out_consistent_views || !out_birth ||
        options->minimum_reciprocal_views <= 0 ||
        options->minimum_reciprocal_views > reciprocal_view_count ||
        !finite(options->absolute_depth_tolerance_m) ||
        !(options->absolute_depth_tolerance_m > 0.0f) ||
        !finite(options->relative_depth_tolerance) ||
        options->relative_depth_tolerance < 0.0f ||
        !finite(options->minimum_parallax_deg) ||
        options->minimum_parallax_deg < 0.0f ||
        options->minimum_parallax_deg > 180.0f) {
        return AETHER_DETECTOR_FREE_ERR_BAD_ARGS;
    }
    const std::int64_t pixel_count_64 =
        static_cast<std::int64_t>(image_width) * image_height;
    if (pixel_count_64 <= 0 || pixel_count_64 > output_capacity) {
        return pixel_count_64 > output_capacity
            ? AETHER_DETECTOR_FREE_ERR_BUFFER_TOO_SMALL
            : AETHER_DETECTOR_FREE_ERR_BAD_ARGS;
    }
    const float inverse_depth_last = inverse_depth_first +
        static_cast<float>(depth_count - 1) * inverse_depth_step;
    if (!(inverse_depth_first > 0.0f) || !(inverse_depth_last > 0.0f)) {
        return AETHER_DETECTOR_FREE_ERR_BAD_ARGS;
    }
    for (int index = 0; index < 9; ++index) {
        if (!finite(reference_inverse_k_row_major_3x3[index])) {
            return AETHER_DETECTOR_FREE_ERR_BAD_ARGS;
        }
    }
    for (int32_t view = 0; view < reciprocal_view_count; ++view) {
        for (int index = 0; index < 12; ++index) {
            if (!finite(reference_to_reciprocal_projections_row_major_3x4[
                    static_cast<std::size_t>(view) * 12 + index])) {
                return AETHER_DETECTOR_FREE_ERR_BAD_ARGS;
            }
        }
        for (int axis = 0; axis < 3; ++axis) {
            if (!finite(reciprocal_camera_centers_in_reference_xyz[
                    static_cast<std::size_t>(view) * 3 + axis])) {
                return AETHER_DETECTOR_FREE_ERR_BAD_ARGS;
            }
        }
    }

    constexpr double kRadiansToDegrees =
        57.295779513082320876798154814105;
    const std::size_t pixel_count =
        static_cast<std::size_t>(pixel_count_64);
    std::memset(out_consistent_views, 0, pixel_count);
    std::memset(out_birth, 0, pixel_count);
    for (int32_t y = 0; y < image_height; ++y) {
        for (int32_t x = 0; x < image_width; ++x) {
            const std::size_t pixel =
                static_cast<std::size_t>(y) * image_width + x;
            if (reference_accepted[pixel] == 0) continue;
            const std::uint16_t best_index = reference_best_index[pixel];
            if (best_index >= depth_count) {
                return AETHER_DETECTOR_FREE_ERR_BAD_ARGS;
            }
            const double inverse_depth = inverse_depth_first +
                static_cast<double>(best_index) * inverse_depth_step;
            if (!(inverse_depth > 0.0)) {
                return AETHER_DETECTOR_FREE_ERR_BAD_ARGS;
            }
            const double depth = 1.0 / inverse_depth;
            const double homogeneous[3] = {
                static_cast<double>(x), static_cast<double>(y), 1.0};
            double point[3] = {};
            for (int row = 0; row < 3; ++row) {
                for (int column = 0; column < 3; ++column) {
                    point[row] +=
                        reference_inverse_k_row_major_3x3[row * 3 + column] *
                        homogeneous[column];
                }
                point[row] *= depth;
            }
            const double reference_norm = std::sqrt(
                point[0] * point[0] + point[1] * point[1] +
                point[2] * point[2]);
            if (!(reference_norm > 0.0)) continue;

            std::uint8_t consistent_views = 0;
            for (int32_t view = 0; view < reciprocal_view_count; ++view) {
                const float* projection =
                    reference_to_reciprocal_projections_row_major_3x4 +
                    static_cast<std::size_t>(view) * 12;
                double projected[3] = {};
                for (int row = 0; row < 3; ++row) {
                    projected[row] = projection[row * 4 + 3];
                    for (int column = 0; column < 3; ++column) {
                        projected[row] +=
                            projection[row * 4 + column] * point[column];
                    }
                }
                const double predicted_depth = projected[2];
                if (!(predicted_depth > 0.05)) continue;
                const int32_t reciprocal_x = static_cast<int32_t>(
                    std::nearbyint(projected[0] / predicted_depth));
                const int32_t reciprocal_y = static_cast<int32_t>(
                    std::nearbyint(projected[1] / predicted_depth));
                if (reciprocal_x < 0 || reciprocal_y < 0 ||
                    reciprocal_x >= image_width ||
                    reciprocal_y >= image_height) {
                    continue;
                }
                const std::size_t reciprocal_pixel =
                    static_cast<std::size_t>(view) * pixel_count +
                    static_cast<std::size_t>(reciprocal_y) * image_width +
                    reciprocal_x;
                if (reciprocal_accepted[reciprocal_pixel] == 0) continue;
                const std::uint16_t reciprocal_index =
                    reciprocal_best_indices[reciprocal_pixel];
                if (reciprocal_index >= depth_count) {
                    return AETHER_DETECTOR_FREE_ERR_BAD_ARGS;
                }
                const double reciprocal_inverse_depth = inverse_depth_first +
                    static_cast<double>(reciprocal_index) * inverse_depth_step;
                if (!(reciprocal_inverse_depth > 0.0)) {
                    return AETHER_DETECTOR_FREE_ERR_BAD_ARGS;
                }
                const double reciprocal_depth = 1.0 / reciprocal_inverse_depth;
                const double tolerance = std::max(
                    static_cast<double>(options->absolute_depth_tolerance_m),
                    static_cast<double>(options->relative_depth_tolerance) *
                        predicted_depth);
                if (std::abs(reciprocal_depth - predicted_depth) > tolerance) {
                    continue;
                }

                const float* center =
                    reciprocal_camera_centers_in_reference_xyz +
                    static_cast<std::size_t>(view) * 3;
                const double source_ray[3] = {
                    point[0] - center[0], point[1] - center[1],
                    point[2] - center[2]};
                const double source_norm = std::sqrt(
                    source_ray[0] * source_ray[0] +
                    source_ray[1] * source_ray[1] +
                    source_ray[2] * source_ray[2]);
                if (!(source_norm > 0.0)) continue;
                const double cosine = std::clamp(
                    (point[0] * source_ray[0] +
                     point[1] * source_ray[1] +
                     point[2] * source_ray[2]) /
                        (reference_norm * source_norm),
                    -1.0, 1.0);
                const double parallax_degrees =
                    std::acos(cosine) * kRadiansToDegrees;
                if (parallax_degrees < options->minimum_parallax_deg) continue;
                ++consistent_views;
            }
            out_consistent_views[pixel] = consistent_views;
            out_birth[pixel] = consistent_views >=
                    options->minimum_reciprocal_views
                ? 1
                : 0;
        }
    }
    return AETHER_DETECTOR_FREE_OK;
}

int32_t aether_detector_free_filter_reciprocal_depth_births(
    int32_t image_width,
    int32_t image_height,
    const float reference_inverse_k_row_major_3x3[9],
    const float* reference_depth_m,
    const uint8_t* reference_accepted,
    int32_t reciprocal_view_count,
    const float* reciprocal_depths_m,
    const uint8_t* reciprocal_accepted,
    const float* reference_to_reciprocal_projections_row_major_3x4,
    const float* reciprocal_camera_centers_in_reference_xyz,
    const aether_detector_free_reciprocal_options_t* options,
    uint8_t* out_consistent_views,
    uint8_t* out_birth,
    int32_t output_capacity) {
    if (image_width <= 0 || image_height <= 0 ||
        !reference_inverse_k_row_major_3x3 || !reference_depth_m ||
        !reference_accepted || reciprocal_view_count <= 0 ||
        reciprocal_view_count > 255 || !reciprocal_depths_m ||
        !reciprocal_accepted ||
        !reference_to_reciprocal_projections_row_major_3x4 ||
        !reciprocal_camera_centers_in_reference_xyz || !options ||
        !out_consistent_views || !out_birth ||
        options->minimum_reciprocal_views <= 0 ||
        options->minimum_reciprocal_views > reciprocal_view_count ||
        !finite(options->absolute_depth_tolerance_m) ||
        !(options->absolute_depth_tolerance_m > 0.0f) ||
        !finite(options->relative_depth_tolerance) ||
        options->relative_depth_tolerance < 0.0f ||
        !finite(options->minimum_parallax_deg) ||
        options->minimum_parallax_deg < 0.0f ||
        options->minimum_parallax_deg > 180.0f) {
        return AETHER_DETECTOR_FREE_ERR_BAD_ARGS;
    }
    const std::int64_t pixel_count_64 =
        static_cast<std::int64_t>(image_width) * image_height;
    if (pixel_count_64 <= 0 || pixel_count_64 > output_capacity) {
        return pixel_count_64 > output_capacity
            ? AETHER_DETECTOR_FREE_ERR_BUFFER_TOO_SMALL
            : AETHER_DETECTOR_FREE_ERR_BAD_ARGS;
    }
    const std::size_t pixel_count = static_cast<std::size_t>(pixel_count_64);
    for (int index = 0; index < 9; ++index) {
        if (!finite(reference_inverse_k_row_major_3x3[index])) {
            return AETHER_DETECTOR_FREE_ERR_BAD_ARGS;
        }
    }
    for (std::size_t pixel = 0; pixel < pixel_count; ++pixel) {
        if (reference_accepted[pixel] > 1 ||
            (reference_accepted[pixel] != 0 &&
             (!finite(reference_depth_m[pixel]) ||
              !(reference_depth_m[pixel] > 0.05f)))) {
            return AETHER_DETECTOR_FREE_ERR_BAD_ARGS;
        }
    }
    for (int32_t view = 0; view < reciprocal_view_count; ++view) {
        for (int index = 0; index < 12; ++index) {
            if (!finite(reference_to_reciprocal_projections_row_major_3x4[
                    static_cast<std::size_t>(view) * 12 + index])) {
                return AETHER_DETECTOR_FREE_ERR_BAD_ARGS;
            }
        }
        for (int axis = 0; axis < 3; ++axis) {
            if (!finite(reciprocal_camera_centers_in_reference_xyz[
                    static_cast<std::size_t>(view) * 3 + axis])) {
                return AETHER_DETECTOR_FREE_ERR_BAD_ARGS;
            }
        }
        for (std::size_t pixel = 0; pixel < pixel_count; ++pixel) {
            const std::size_t offset =
                static_cast<std::size_t>(view) * pixel_count + pixel;
            if (reciprocal_accepted[offset] > 1 ||
                (reciprocal_accepted[offset] != 0 &&
                 (!finite(reciprocal_depths_m[offset]) ||
                  !(reciprocal_depths_m[offset] > 0.05f)))) {
                return AETHER_DETECTOR_FREE_ERR_BAD_ARGS;
            }
        }
    }

    constexpr double kRadiansToDegrees =
        57.295779513082320876798154814105;
    std::memset(out_consistent_views, 0, pixel_count);
    std::memset(out_birth, 0, pixel_count);
    for (int32_t y = 0; y < image_height; ++y) {
        for (int32_t x = 0; x < image_width; ++x) {
            const std::size_t pixel =
                static_cast<std::size_t>(y) * image_width + x;
            if (reference_accepted[pixel] == 0) continue;
            const double depth = reference_depth_m[pixel];
            const double homogeneous[3] = {
                static_cast<double>(x), static_cast<double>(y), 1.0};
            double point[3] = {};
            for (int row = 0; row < 3; ++row) {
                for (int column = 0; column < 3; ++column) {
                    point[row] +=
                        reference_inverse_k_row_major_3x3[row * 3 + column] *
                        homogeneous[column];
                }
                point[row] *= depth;
            }
            const double reference_norm = std::sqrt(
                point[0] * point[0] + point[1] * point[1] +
                point[2] * point[2]);
            if (!(reference_norm > 0.0)) continue;

            std::uint8_t consistent_views = 0;
            for (int32_t view = 0; view < reciprocal_view_count; ++view) {
                const float* projection =
                    reference_to_reciprocal_projections_row_major_3x4 +
                    static_cast<std::size_t>(view) * 12;
                double projected[3] = {};
                for (int row = 0; row < 3; ++row) {
                    projected[row] = projection[row * 4 + 3];
                    for (int column = 0; column < 3; ++column) {
                        projected[row] +=
                            projection[row * 4 + column] * point[column];
                    }
                }
                const double predicted_depth = projected[2];
                if (!(predicted_depth > 0.05)) continue;
                const int32_t reciprocal_x = static_cast<int32_t>(
                    std::nearbyint(projected[0] / predicted_depth));
                const int32_t reciprocal_y = static_cast<int32_t>(
                    std::nearbyint(projected[1] / predicted_depth));
                if (reciprocal_x < 0 || reciprocal_y < 0 ||
                    reciprocal_x >= image_width ||
                    reciprocal_y >= image_height) {
                    continue;
                }
                const std::size_t reciprocal_pixel =
                    static_cast<std::size_t>(view) * pixel_count +
                    static_cast<std::size_t>(reciprocal_y) * image_width +
                    reciprocal_x;
                if (reciprocal_accepted[reciprocal_pixel] == 0) continue;
                const double reciprocal_depth =
                    reciprocal_depths_m[reciprocal_pixel];
                const double tolerance = std::max(
                    static_cast<double>(options->absolute_depth_tolerance_m),
                    static_cast<double>(options->relative_depth_tolerance) *
                        predicted_depth);
                if (std::abs(reciprocal_depth - predicted_depth) > tolerance) {
                    continue;
                }

                const float* center =
                    reciprocal_camera_centers_in_reference_xyz +
                    static_cast<std::size_t>(view) * 3;
                const double source_ray[3] = {
                    point[0] - center[0], point[1] - center[1],
                    point[2] - center[2]};
                const double source_norm = std::sqrt(
                    source_ray[0] * source_ray[0] +
                    source_ray[1] * source_ray[1] +
                    source_ray[2] * source_ray[2]);
                if (!(source_norm > 0.0)) continue;
                const double cosine = std::clamp(
                    (point[0] * source_ray[0] +
                     point[1] * source_ray[1] +
                     point[2] * source_ray[2]) /
                        (reference_norm * source_norm),
                    -1.0, 1.0);
                if (std::acos(cosine) * kRadiansToDegrees <
                    options->minimum_parallax_deg) {
                    continue;
                }
                ++consistent_views;
            }
            out_consistent_views[pixel] = consistent_views;
            out_birth[pixel] = consistent_views >=
                    options->minimum_reciprocal_views
                ? 1
                : 0;
        }
    }
    return AETHER_DETECTOR_FREE_OK;
}

int32_t aether_detector_free_session_create(
    const aether_detector_free_options_t* options,
    const float* gray_frames,
    size_t gray_value_count,
    const float* source_projections,
    size_t projection_value_count,
    aether_detector_free_session_t** out_session) {
    if (!options || !gray_frames || !source_projections || !out_session) {
        return AETHER_DETECTOR_FREE_ERR_BAD_ARGS;
    }
    *out_session = nullptr;
    std::size_t image_pixels = 0;
    std::size_t maximum_tile_pixels = 0;
    if (!valid_options(*options, &image_pixels, &maximum_tile_pixels)) {
        return AETHER_DETECTOR_FREE_ERR_BAD_ARGS;
    }
    std::size_t expected_gray_values = 0;
    if (!checked_multiply(
            image_pixels, static_cast<std::size_t>(options->source_count + 1),
            &expected_gray_values) ||
        gray_value_count != expected_gray_values ||
        projection_value_count !=
            static_cast<std::size_t>(options->source_count) * 12) {
        return AETHER_DETECTOR_FREE_ERR_BAD_ARGS;
    }
    for (std::size_t index = 0; index < gray_value_count; ++index) {
        if (!finite(gray_frames[index])) {
            return AETHER_DETECTOR_FREE_ERR_BAD_ARGS;
        }
    }
    for (std::size_t index = 0; index < projection_value_count; ++index) {
        if (!finite(source_projections[index])) {
            return AETHER_DETECTOR_FREE_ERR_BAD_ARGS;
        }
    }
#if !defined(AETHER_ENABLE_DAWN)
    return AETHER_DETECTOR_FREE_ERR_UNSUPPORTED;
#else
    std::unique_ptr<aether_detector_free_session> session(
        new (std::nothrow) aether_detector_free_session());
    if (!session) return AETHER_DETECTOR_FREE_ERR_INTERNAL;
    session->options = *options;
    session->image_pixels = image_pixels;
    session->maximum_tile_pixels = maximum_tile_pixels;
    session->runtime = acquire_detector_free_runtime();
    if (!session->runtime || !session->runtime->device) {
        return AETHER_DETECTOR_FREE_ERR_GPU;
    }
    std::lock_guard<std::mutex> runtime_lock(
        session->runtime->execution_mutex);
    auto& device = *session->runtime->device;

    const std::size_t gray_bytes = gray_value_count * sizeof(float);
    const std::size_t projection_bytes = projection_value_count * sizeof(float);
    session->gray = make_buffer(
        device, gray_bytes, GPUBufferUsage::kStorage,
        GPUStorageMode::kPrivate, "detector_free_gray");
    session->projections = make_buffer(
        device, projection_bytes, GPUBufferUsage::kStorage,
        GPUStorageMode::kPrivate, "detector_free_projections");
    session->params_buffer = make_buffer(
        device, sizeof(GpuParams), GPUBufferUsage::kUniform,
        GPUStorageMode::kPrivate, "detector_free_params");
    session->output = make_buffer(
        device, maximum_tile_pixels * sizeof(GpuOutput),
        GPUBufferUsage::kStorage, GPUStorageMode::kPrivate,
        "detector_free_output");
    session->refine_input = make_buffer(
        device, maximum_tile_pixels * sizeof(GpuRefineInput),
        GPUBufferUsage::kStorage, GPUStorageMode::kPrivate,
        "detector_free_refine_input");
    session->refine_output = make_buffer(
        device, maximum_tile_pixels * sizeof(GpuRefinedOutput),
        GPUBufferUsage::kStorage, GPUStorageMode::kPrivate,
        "detector_free_refine_output");
    if (!session->gray.valid() || !session->projections.valid() ||
        !session->params_buffer.valid() || !session->output.valid() ||
        !session->refine_input.valid() || !session->refine_output.valid()) {
        return AETHER_DETECTOR_FREE_ERR_GPU;
    }
    device.update_buffer(
        session->gray, gray_frames, 0, gray_bytes);
    device.update_buffer(
        session->projections, source_projections, 0, projection_bytes);

    auto& params = session->params;
    params.image_width = static_cast<std::uint32_t>(options->image_width);
    params.image_height = static_cast<std::uint32_t>(options->image_height);
    params.image_pixel_count = static_cast<std::uint32_t>(image_pixels);
    params.depth_count = static_cast<std::uint32_t>(options->depth_count);
    params.source_count = static_cast<std::uint32_t>(options->source_count);
    params.patch_n = static_cast<std::uint32_t>(options->patch_n);
    params.minimum_views = static_cast<std::uint32_t>(options->minimum_views);
    params.exclusion_radius =
        static_cast<std::uint32_t>(options->exclusion_radius_samples);
    params.minimum_std_u8 = options->minimum_std_u8;
    params.ncc_min = options->ncc_min;
    params.depth_margin = options->unique_depth_margin;
    params.inverse_depth_first = options->inverse_depth_first;
    params.inverse_depth_step = options->inverse_depth_step;
    for (int column = 0; column < 3; ++column) {
        params.inverse_k0[column] =
            options->reference_inverse_k_row_major_3x3[column];
        params.inverse_k1[column] =
            options->reference_inverse_k_row_major_3x3[3 + column];
        params.inverse_k2[column] =
            options->reference_inverse_k_row_major_3x3[6 + column];
    }
    *out_session = session.release();
    return AETHER_DETECTOR_FREE_OK;
#endif
}

int32_t aether_detector_free_session_set_view_aggregation(
    aether_detector_free_session_t* session,
    int32_t aggregation) {
    if (!session ||
        aggregation < AETHER_DETECTOR_FREE_VIEW_AGGREGATION_TOP_MINIMUM ||
        aggregation >
            AETHER_DETECTOR_FREE_VIEW_AGGREGATION_TOP_MINIMUM_WITH_DISSENT) {
        return AETHER_DETECTOR_FREE_ERR_BAD_ARGS;
    }
    std::lock_guard<std::mutex> lock(session->mutex);
#if defined(AETHER_ENABLE_DAWN)
    session->params.padding_u2 = static_cast<std::uint32_t>(aggregation);
#else
    (void)aggregation;
#endif
    return AETHER_DETECTOR_FREE_OK;
}

int32_t aether_detector_free_session_run_refined_tile(
    aether_detector_free_session_t* session,
    int32_t tile_origin_x,
    int32_t tile_origin_y,
    int32_t tile_width,
    int32_t tile_height,
    const uint16_t* coarse_best_index,
    const uint8_t* coarse_accepted,
    const aether_detector_free_refine_options_t* refine_options,
    float* out_refined_depth_m,
    float* out_best_score,
    float* out_second_score,
    uint8_t* out_supporting_views,
    uint8_t* out_accepted,
    int32_t output_capacity) {
    if (!session || !coarse_best_index || !coarse_accepted ||
        !refine_options || !out_refined_depth_m || !out_best_score ||
        !out_second_score || !out_supporting_views || !out_accepted ||
        tile_origin_x < 0 || tile_origin_y < 0 || tile_width <= 0 ||
        tile_height <= 0 || tile_width > session->options.max_tile_width ||
        tile_height > session->options.max_tile_height ||
        static_cast<std::int64_t>(tile_origin_x) + tile_width >
            session->options.image_width ||
        static_cast<std::int64_t>(tile_origin_y) + tile_height >
            session->options.image_height ||
        refine_options->fine_depth_count < 3 ||
        refine_options->fine_depth_count > 64 ||
        refine_options->fine_depth_count % 2 == 0 ||
        !finite(refine_options->coarse_step_span) ||
        !(refine_options->coarse_step_span > 0.0f) ||
        refine_options->coarse_step_span > 2.0f ||
        !finite(refine_options->uniqueness_absolute_m) ||
        !(refine_options->uniqueness_absolute_m > 0.0f) ||
        refine_options->uniqueness_absolute_m > 2.0f ||
        !finite(refine_options->uniqueness_relative) ||
        refine_options->uniqueness_relative < 0.0f ||
        refine_options->uniqueness_relative > 1.0f) {
        return AETHER_DETECTOR_FREE_ERR_BAD_ARGS;
    }
    const std::int64_t pixel_count_64 =
        static_cast<std::int64_t>(tile_width) * tile_height;
    if (output_capacity < pixel_count_64) {
        return AETHER_DETECTOR_FREE_ERR_BUFFER_TOO_SMALL;
    }
    const std::size_t pixel_count = static_cast<std::size_t>(pixel_count_64);
    std::vector<GpuRefineInput> input(pixel_count);
    for (std::size_t index = 0; index < pixel_count; ++index) {
        if (coarse_best_index[index] >= session->options.depth_count ||
            coarse_accepted[index] > 1) {
            return AETHER_DETECTOR_FREE_ERR_BAD_ARGS;
        }
        input[index].best_index = coarse_best_index[index];
        input[index].accepted = coarse_accepted[index];
    }
#if !defined(AETHER_ENABLE_DAWN)
    return AETHER_DETECTOR_FREE_ERR_UNSUPPORTED;
#else
    if (!session->runtime || !session->runtime->device) {
        return AETHER_DETECTOR_FREE_ERR_GPU;
    }
    std::scoped_lock lock(
        session->mutex, session->runtime->execution_mutex);
    auto& device = *session->runtime->device;
    auto& params = session->params;
    params.tile_origin_x = static_cast<std::uint32_t>(tile_origin_x);
    params.tile_origin_y = static_cast<std::uint32_t>(tile_origin_y);
    params.tile_width = static_cast<std::uint32_t>(tile_width);
    params.tile_height = static_cast<std::uint32_t>(tile_height);
    params.tile_pixel_count = static_cast<std::uint32_t>(pixel_count);
    params.padding_u0 =
        static_cast<std::uint32_t>(refine_options->fine_depth_count);
    params.padding0 = refine_options->coarse_step_span;
    params.padding1 = refine_options->uniqueness_absolute_m;
    params.padding2 = refine_options->uniqueness_relative;
    device.update_buffer(
        session->params_buffer, &params, 0, sizeof(params));
    device.update_buffer(
        session->refine_input, input.data(), 0,
        pixel_count * sizeof(GpuRefineInput));

    auto command = device.create_command_buffer();
    auto* encoder = command ? command->make_compute_encoder() : nullptr;
    if (!encoder) return AETHER_DETECTOR_FREE_ERR_GPU;
    encoder->set_pipeline(session->runtime->refine_pipeline);
    encoder->set_buffer(session->gray, 0, 0);
    encoder->set_buffer(session->projections, 0, 1);
    encoder->set_buffer(session->params_buffer, 0, 2);
    encoder->set_buffer(session->refine_input, 0, 3);
    encoder->set_buffer(session->refine_output, 0, 4);
    encoder->dispatch_1d(static_cast<std::uint32_t>(pixel_count), 64);
    encoder->end_encoding();
    command->commit();
    command->wait_until_completed();
    if (command->had_error()) return AETHER_DETECTOR_FREE_ERR_GPU;

    std::vector<GpuRefinedOutput> output;
    if (!readback_refined_output(
            device, session->refine_output, pixel_count, &output)) {
        return AETHER_DETECTOR_FREE_ERR_GPU;
    }
    for (std::size_t index = 0; index < output.size(); ++index) {
        out_refined_depth_m[index] = output[index].depth_m;
        out_best_score[index] = output[index].best_score;
        out_second_score[index] = output[index].second_score;
        out_supporting_views[index] = static_cast<std::uint8_t>(
            output[index].supporting_views);
        out_accepted[index] = static_cast<std::uint8_t>(
            output[index].accepted != 0 ? 1 : 0);
    }
    return AETHER_DETECTOR_FREE_OK;
#endif
}

static int32_t run_tile_common(
    aether_detector_free_session_t* session,
    int32_t tile_origin_x,
    int32_t tile_origin_y,
    int32_t tile_width,
    int32_t tile_height,
    uint16_t* out_best_index,
    float* out_interpolated_depth_m,
    float* out_peak_min_neighbor_drop,
    float* out_all_view_dissent,
    float* out_best_score,
    float* out_second_score,
    uint8_t* out_supporting_views,
    uint8_t* out_accepted,
    int32_t output_capacity) {
    (void)out_interpolated_depth_m;
    (void)out_peak_min_neighbor_drop;
    (void)out_all_view_dissent;
    if (!session || !out_best_index || !out_best_score || !out_second_score ||
        !out_supporting_views || !out_accepted || tile_origin_x < 0 ||
        tile_origin_y < 0 || tile_width <= 0 || tile_height <= 0 ||
        tile_width > session->options.max_tile_width ||
        tile_height > session->options.max_tile_height ||
        static_cast<std::int64_t>(tile_origin_x) + tile_width >
            session->options.image_width ||
        static_cast<std::int64_t>(tile_origin_y) + tile_height >
            session->options.image_height) {
        return AETHER_DETECTOR_FREE_ERR_BAD_ARGS;
    }
    const std::int64_t pixel_count_64 =
        static_cast<std::int64_t>(tile_width) * tile_height;
    if (output_capacity < pixel_count_64) {
        return AETHER_DETECTOR_FREE_ERR_BUFFER_TOO_SMALL;
    }
#if !defined(AETHER_ENABLE_DAWN)
    return AETHER_DETECTOR_FREE_ERR_UNSUPPORTED;
#else
    if (!session->runtime || !session->runtime->device) {
        return AETHER_DETECTOR_FREE_ERR_GPU;
    }
    std::scoped_lock lock(
        session->mutex, session->runtime->execution_mutex);
    auto& device = *session->runtime->device;
    auto& params = session->params;
    params.tile_origin_x = static_cast<std::uint32_t>(tile_origin_x);
    params.tile_origin_y = static_cast<std::uint32_t>(tile_origin_y);
    params.tile_width = static_cast<std::uint32_t>(tile_width);
    params.tile_height = static_cast<std::uint32_t>(tile_height);
    params.tile_pixel_count = static_cast<std::uint32_t>(pixel_count_64);
    params.padding_u1 = out_interpolated_depth_m ? 1u : 0u;
    device.update_buffer(
        session->params_buffer, &params, 0, sizeof(params));

    auto command = device.create_command_buffer();
    auto* encoder = command ? command->make_compute_encoder() : nullptr;
    if (!encoder) return AETHER_DETECTOR_FREE_ERR_GPU;
    encoder->set_pipeline(session->runtime->coarse_pipeline);
    encoder->set_buffer(session->gray, 0, 0);
    encoder->set_buffer(session->projections, 0, 1);
    encoder->set_buffer(session->params_buffer, 0, 2);
    encoder->set_buffer(session->output, 0, 3);
    encoder->dispatch_1d(static_cast<std::uint32_t>(pixel_count_64), 64);
    encoder->end_encoding();
    command->commit();
    command->wait_until_completed();
    if (command->had_error()) return AETHER_DETECTOR_FREE_ERR_GPU;

    std::vector<GpuOutput> output;
    if (!readback_output(
            device, session->output,
            static_cast<std::size_t>(pixel_count_64), &output)) {
        return AETHER_DETECTOR_FREE_ERR_GPU;
    }
    for (std::size_t index = 0; index < output.size(); ++index) {
        out_best_index[index] =
            static_cast<std::uint16_t>(output[index].best_index);
        if (out_interpolated_depth_m) {
            out_interpolated_depth_m[index] = output[index].interpolated_depth_m;
            out_peak_min_neighbor_drop[index] = static_cast<float>(
                (output[index].views >> 8u) & 0xffffu) / 32767.0f;
        }
        if (out_all_view_dissent) {
            out_all_view_dissent[index] = static_cast<float>(
                (output[index].views >> 24u) & 0xffu) * (2.0f / 255.0f);
        }
        out_best_score[index] = output[index].best_score;
        out_second_score[index] = output[index].second_score;
        out_supporting_views[index] =
            static_cast<std::uint8_t>(output[index].views & 0xffu);
        out_accepted[index] =
            static_cast<std::uint8_t>(output[index].accepted != 0 ? 1 : 0);
    }
    return AETHER_DETECTOR_FREE_OK;
#endif
}

int32_t aether_detector_free_session_run_tile(
    aether_detector_free_session_t* session,
    int32_t tile_origin_x,
    int32_t tile_origin_y,
    int32_t tile_width,
    int32_t tile_height,
    uint16_t* out_best_index,
    float* out_best_score,
    float* out_second_score,
    uint8_t* out_supporting_views,
    uint8_t* out_accepted,
    int32_t output_capacity) {
    return run_tile_common(
        session, tile_origin_x, tile_origin_y, tile_width, tile_height,
        out_best_index, nullptr, nullptr, nullptr,
        out_best_score, out_second_score,
        out_supporting_views, out_accepted, output_capacity);
}

int32_t aether_detector_free_session_run_interpolated_tile(
    aether_detector_free_session_t* session,
    int32_t tile_origin_x,
    int32_t tile_origin_y,
    int32_t tile_width,
    int32_t tile_height,
    uint16_t* out_best_index,
    float* out_interpolated_depth_m,
    float* out_peak_min_neighbor_drop,
    float* out_best_score,
    float* out_second_score,
    uint8_t* out_supporting_views,
    uint8_t* out_accepted,
    int32_t output_capacity) {
    if (!out_interpolated_depth_m || !out_peak_min_neighbor_drop) {
        return AETHER_DETECTOR_FREE_ERR_BAD_ARGS;
    }
    return run_tile_common(
        session, tile_origin_x, tile_origin_y, tile_width, tile_height,
        out_best_index, out_interpolated_depth_m,
        out_peak_min_neighbor_drop, nullptr, out_best_score, out_second_score,
        out_supporting_views, out_accepted,
        output_capacity);
}

int32_t aether_detector_free_session_run_diagnostic_tile(
    aether_detector_free_session_t* session,
    int32_t tile_origin_x,
    int32_t tile_origin_y,
    int32_t tile_width,
    int32_t tile_height,
    uint16_t* out_best_index,
    float* out_all_view_dissent,
    float* out_best_score,
    float* out_second_score,
    uint8_t* out_supporting_views,
    uint8_t* out_accepted,
    int32_t output_capacity) {
    if (!out_all_view_dissent) {
        return AETHER_DETECTOR_FREE_ERR_BAD_ARGS;
    }
    return run_tile_common(
        session, tile_origin_x, tile_origin_y, tile_width, tile_height,
        out_best_index, nullptr, nullptr, out_all_view_dissent,
        out_best_score, out_second_score, out_supporting_views, out_accepted,
        output_capacity);
}

void aether_detector_free_session_free(
    aether_detector_free_session_t* session) {
    if (!session) return;
#if defined(AETHER_ENABLE_DAWN)
    if (session->runtime && session->runtime->device) {
        std::lock_guard<std::mutex> lock(
            session->runtime->execution_mutex);
        auto& device = *session->runtime->device;
        if (session->gray.valid()) device.destroy_buffer(session->gray);
        if (session->projections.valid()) {
            device.destroy_buffer(session->projections);
        }
        if (session->params_buffer.valid()) {
            device.destroy_buffer(session->params_buffer);
        }
        if (session->output.valid()) {
            device.destroy_buffer(session->output);
        }
        if (session->refine_input.valid()) {
            device.destroy_buffer(session->refine_input);
        }
        if (session->refine_output.valid()) {
            device.destroy_buffer(session->refine_output);
        }
    }
#endif
    delete session;
}

const char* aether_detector_free_result_str(int32_t rc) {
    switch (rc) {
        case AETHER_DETECTOR_FREE_OK: return "ok";
        case AETHER_DETECTOR_FREE_ERR_BAD_ARGS: return "bad_args";
        case AETHER_DETECTOR_FREE_ERR_UNSUPPORTED: return "unsupported";
        case AETHER_DETECTOR_FREE_ERR_GPU: return "gpu";
        case AETHER_DETECTOR_FREE_ERR_BUFFER_TOO_SMALL: return "buffer_too_small";
        case AETHER_DETECTOR_FREE_ERR_INTERNAL: return "internal";
        default: return "unknown";
    }
}

}  // extern "C"
