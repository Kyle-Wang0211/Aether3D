// SPDX-License-Identifier: LicenseRef-Aether3D-Proprietary
// Copyright (c) 2024-2026 Aether3D. All rights reserved.
//
// Phase 6.4d.1 smoke — verify Dawn can import an RGBA16F IOSurface,
// render into it via a clear pass, and read back finite half-float data.

#if defined(__APPLE__)

#import <CoreVideo/CoreVideo.h>
#import <IOSurface/IOSurface.h>

#include "aether/render/dawn_gpu_device.h"
#include "aether/render/gpu_command.h"
#include "aether/render/gpu_device.h"

#include <cmath>
#include <cstdint>
#include <cstring>
#include <cstdio>
#include <cstdlib>
#include <vector>

namespace {

constexpr std::uint32_t kWidth = 64;
constexpr std::uint32_t kHeight = 64;
constexpr std::uint32_t kBytesPerPixel = 8;

void add_int_value(CFMutableDictionaryRef dict, const CFStringRef key, std::int32_t value) {
    CFNumberRef number = CFNumberCreate(nullptr, kCFNumberSInt32Type, &value);
    if (!number) return;
    CFDictionaryAddValue(dict, key, number);
    CFRelease(number);
}

IOSurfaceRef create_rgba16f_iosurface(std::uint32_t width, std::uint32_t height) {
    CFMutableDictionaryRef dict = CFDictionaryCreateMutable(
        kCFAllocatorDefault, 0, &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
    if (!dict) return nullptr;

    add_int_value(dict, kIOSurfaceWidth, static_cast<std::int32_t>(width));
    add_int_value(dict, kIOSurfaceHeight, static_cast<std::int32_t>(height));
    add_int_value(dict, kIOSurfacePixelFormat, static_cast<std::int32_t>(kCVPixelFormatType_64RGBAHalf));
    add_int_value(dict, kIOSurfaceBytesPerElement, static_cast<std::int32_t>(kBytesPerPixel));
    add_int_value(dict, kIOSurfaceBytesPerRow, static_cast<std::int32_t>(width * kBytesPerPixel));

    IOSurfaceRef surface = IOSurfaceCreate(dict);
    CFRelease(dict);
    return surface;
}

float half_to_float(std::uint16_t bits) {
    const std::uint32_t sign = (bits & 0x8000u) << 16;
    const std::uint32_t exp = (bits >> 10) & 0x1Fu;
    const std::uint32_t mantissa = bits & 0x03FFu;

    std::uint32_t out = 0;
    if (exp == 0) {
        if (mantissa == 0) {
            out = sign;
        } else {
            std::uint32_t mant = mantissa;
            std::uint32_t shifted_exp = 113u;
            while ((mant & 0x0400u) == 0) {
                mant <<= 1;
                --shifted_exp;
            }
            mant &= 0x03FFu;
            out = sign | (shifted_exp << 23) | (mant << 13);
        }
    } else if (exp == 0x1Fu) {
        out = sign | 0x7F800000u | (mantissa << 13);
    } else {
        out = sign | ((exp + 112u) << 23) | (mantissa << 13);
    }

    float value = 0.0f;
    std::memcpy(&value, &out, sizeof(value));
    return value;
}

}  // namespace

int main() {
    using namespace aether::render;

    auto device = create_dawn_gpu_device();
    if (!device) {
        std::fprintf(stderr, "FAIL: create_dawn_gpu_device\n");
        return EXIT_FAILURE;
    }

    IOSurfaceRef surface = create_rgba16f_iosurface(kWidth, kHeight);
    if (!surface) {
        std::fprintf(stderr, "FAIL: IOSurfaceCreate RGBA16F\n");
        return EXIT_FAILURE;
    }

    GPUTextureHandle target = dawn_import_iosurface_texture(
        *device,
        const_cast<void*>(reinterpret_cast<const void*>(surface)),
        kWidth,
        kHeight,
        GPUTextureFormat::kRGBA16Float);
    if (!target.valid()) {
        std::fprintf(stderr, "FAIL: dawn_import_iosurface_texture RGBA16F\n");
        CFRelease(surface);
        return EXIT_FAILURE;
    }

    if (!dawn_iosurface_begin_access(*device, target)) {
        std::fprintf(stderr, "FAIL: dawn_iosurface_begin_access\n");
        device->destroy_texture(target);
        CFRelease(surface);
        return EXIT_FAILURE;
    }

    GPURenderPassDesc pass{};
    pass.width = kWidth;
    pass.height = kHeight;
    pass.sample_count = 1;
    pass.color_attachment_count = 1;
    pass.color_attachments[0].texture = target;
    pass.color_attachments[0].load = GPULoadAction::kClear;
    pass.color_attachments[0].store = GPUStoreAction::kStore;
    pass.color_attachments[0].clear_color[0] = 0.25f;
    pass.color_attachments[0].clear_color[1] = 0.50f;
    pass.color_attachments[0].clear_color[2] = 0.75f;
    pass.color_attachments[0].clear_color[3] = 1.00f;

    auto cb = device->create_command_buffer();
    auto* re = cb->make_render_encoder(pass);
    if (!re) {
        std::fprintf(stderr, "FAIL: make_render_encoder\n");
        dawn_iosurface_end_access(*device, target);
        device->destroy_texture(target);
        CFRelease(surface);
        return EXIT_FAILURE;
    }
    re->end_encoding();
    cb->commit();
    cb->wait_until_completed();

    auto bytes = device->readback_texture(target, kWidth, kHeight, kBytesPerPixel);
    if (bytes.size() != static_cast<std::size_t>(kWidth) * kHeight * kBytesPerPixel) {
        std::fprintf(stderr, "FAIL: readback size %zu\n", bytes.size());
        dawn_iosurface_end_access(*device, target);
        device->destroy_texture(target);
        CFRelease(surface);
        return EXIT_FAILURE;
    }

    if (!dawn_iosurface_end_access(*device, target)) {
        std::fprintf(stderr, "FAIL: dawn_iosurface_end_access\n");
        device->destroy_texture(target);
        CFRelease(surface);
        return EXIT_FAILURE;
    }

    const std::uint16_t* px = reinterpret_cast<const std::uint16_t*>(bytes.data());
    const float r = half_to_float(px[0]);
    const float g = half_to_float(px[1]);
    const float b = half_to_float(px[2]);
    const float a = half_to_float(px[3]);

    std::printf("=== aether_dawn_iosurface_rgba16f_smoke ===\n");
    std::printf("pixel0 rgba=(%.4f, %.4f, %.4f, %.4f)\n", r, g, b, a);

    const bool finite = std::isfinite(r) && std::isfinite(g)
        && std::isfinite(b) && std::isfinite(a);
    const bool not_zero = (r > 0.10f) && (g > 0.10f) && (b > 0.10f) && (a > 0.90f);
    const bool within_expected = (std::fabs(r - 0.25f) < 0.05f)
        && (std::fabs(g - 0.50f) < 0.05f)
        && (std::fabs(b - 0.75f) < 0.05f)
        && (std::fabs(a - 1.00f) < 0.02f);

    device->destroy_texture(target);
    CFRelease(surface);

    if (!finite) {
        std::fprintf(stderr, "FAIL: readback contains NaN/Inf\n");
        return EXIT_FAILURE;
    }
    if (!not_zero) {
        std::fprintf(stderr, "FAIL: clear pass did not write non-zero half floats\n");
        return EXIT_FAILURE;
    }
    if (!within_expected) {
        std::fprintf(stderr, "FAIL: RGBA16F clear mismatch vs expected values\n");
        return EXIT_FAILURE;
    }

    std::printf("PASS\n");
    return EXIT_SUCCESS;
}

#else

int main() {
    std::fprintf(stderr, "SKIP: aether_dawn_iosurface_rgba16f_smoke is Apple-only\n");
    return EXIT_SUCCESS;
}

#endif
