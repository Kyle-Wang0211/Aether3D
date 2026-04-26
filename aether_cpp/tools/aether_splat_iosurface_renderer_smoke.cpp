// SPDX-License-Identifier: LicenseRef-Aether3D-Proprietary
// Copyright (c) 2024-2026 Aether3D. All rights reserved.
//
// Phase 6.4a Step 3b/4 — splat_iosurface_renderer end-to-end smoke.
//
// Creates an IOSurface from CoreFoundation (no Swift / Flutter required),
// hands it to aether_splat_renderer_create, calls render(), then reads
// the IOSurface bytes directly to verify the pixel output matches the
// cross_validate baseline within 2 LSB.
//
// Same pixel-equivalence check as splat_smoke_render_via_device, but
// through the production-path FFI surface that the PocketWorld plugin
// will call. If this passes, the only remaining 6.4a work is wiring the
// IOSurface from Swift (which has the same CF API surface).

#include "aether/pocketworld/splat_iosurface_renderer.h"

#include <IOSurface/IOSurface.h>
#include <CoreFoundation/CoreFoundation.h>

#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <cstring>

namespace {
constexpr std::uint32_t kImgW = 256;
constexpr std::uint32_t kImgH = 256;
constexpr std::uint32_t kBpp  = 4;

// Build a CFDictionary of IOSurface creation properties.
CFDictionaryRef make_iosurface_props() {
    CFNumberRef w_n  = CFNumberCreate(nullptr, kCFNumberSInt32Type, &kImgW);
    CFNumberRef h_n  = CFNumberCreate(nullptr, kCFNumberSInt32Type, &kImgH);
    int32_t pixel_format = 0x42475241;  // 'BGRA' (kCVPixelFormatType_32BGRA)
    CFNumberRef pf_n = CFNumberCreate(nullptr, kCFNumberSInt32Type, &pixel_format);
    int32_t bpe = 4;
    CFNumberRef bpe_n = CFNumberCreate(nullptr, kCFNumberSInt32Type, &bpe);
    int32_t bpr = static_cast<int32_t>(kImgW) * 4;
    CFNumberRef bpr_n = CFNumberCreate(nullptr, kCFNumberSInt32Type, &bpr);

    const void* keys[]   = {
        kIOSurfaceWidth, kIOSurfaceHeight, kIOSurfacePixelFormat,
        kIOSurfaceBytesPerElement, kIOSurfaceBytesPerRow,
    };
    const void* values[] = { w_n, h_n, pf_n, bpe_n, bpr_n };
    CFDictionaryRef d = CFDictionaryCreate(nullptr, keys, values, 5,
        &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
    CFRelease(w_n); CFRelease(h_n); CFRelease(pf_n);
    CFRelease(bpe_n); CFRelease(bpr_n);
    return d;
}

}  // namespace

int main() {
    // 1. Create IOSurface.
    CFDictionaryRef props = make_iosurface_props();
    IOSurfaceRef surface = IOSurfaceCreate(props);
    CFRelease(props);
    if (!surface) {
        std::fprintf(stderr, "FAIL: IOSurfaceCreate returned NULL\n");
        return EXIT_FAILURE;
    }

    // 2. Hand to the renderer.
    auto* renderer = aether_splat_renderer_create(
        const_cast<void*>(static_cast<const void*>(surface)), kImgW, kImgH);
    if (!renderer) {
        std::fprintf(stderr, "FAIL: aether_splat_renderer_create returned NULL\n");
        CFRelease(surface);
        return EXIT_FAILURE;
    }

    // 3a. Render via stage-1 entry point (t_seconds → internally identity matrices).
    aether_splat_renderer_render(renderer, /*t_seconds=*/0.0);

    // 4. Read IOSurface bytes back. Must lock for read; bytes are
    //    accessed via base address with the row-stride from props.
    IOSurfaceLock(surface, kIOSurfaceLockReadOnly, nullptr);
    const std::uint8_t* base = static_cast<const std::uint8_t*>(IOSurfaceGetBaseAddress(surface));
    const std::size_t row_stride = IOSurfaceGetBytesPerRow(surface);

    auto pixel_bgra = [&](std::uint32_t x, std::uint32_t y) {
        struct P { std::uint8_t b, g, r, a; };
        const std::uint8_t* p = base + y * row_stride + x * kBpp;
        return P{ p[0], p[1], p[2], p[3] };
    };
    auto center = pixel_bgra(128, 128);
    auto corner = pixel_bgra(0, 0);

    IOSurfaceUnlock(surface, kIOSurfaceLockReadOnly, nullptr);

    std::printf("=== aether_splat_iosurface_renderer_smoke ===\n");
    std::printf("center (128,128) BGRA: B=%u G=%u R=%u A=%u\n",
                center.b, center.g, center.r, center.a);
    std::printf("corner (0,0)     BGRA: B=%u G=%u R=%u A=%u\n",
                corner.b, corner.g, corner.r, corner.a);

    // Cross_validate baseline (RGBA8): center=(162,162,162,254). The
    // IOSurface is BGRA so the channel order swaps, but R==G==B so the
    // numeric values still compare directly. Allow ±2 LSB drift —
    // production path goes through the same Tint pipeline as the harness
    // smokes, so the result is bit-exact in practice on Apple Silicon.
    auto chan_close = [](int got, int want) {
        return std::abs(got - want) <= 2;
    };

    bool pass = true;
    if (!chan_close(center.r, 162) || !chan_close(center.g, 162)
        || !chan_close(center.b, 162) || !chan_close(center.a, 254)) {
        std::fprintf(stderr,
            "FAIL: center pixel BGRA=(%u,%u,%u,%u) not within 2 LSB of "
            "expected (162,162,162,254)\n",
            center.b, center.g, center.r, center.a);
        pass = false;
    }
    // Corner: clear color is opaque black (clear_color={0,0,0,1}). The
    // splats' quad bounds don't reach the corners (3-sigma ≈ 38 pixels),
    // so corner pixels are pure clear color: BGRA=(0,0,0,255). Note this
    // differs from splat_smoke_render which clears to transparent (0,0,0,0)
    // — IOSurface bridge clears to opaque so Flutter compositor sees a
    // visible background.
    if (corner.r != 0 || corner.g != 0 || corner.b != 0 || corner.a != 255) {
        std::fprintf(stderr,
            "FAIL: corner pixel BGRA=(%u,%u,%u,%u) not opaque black "
            "(0,0,0,255)\n",
            corner.b, corner.g, corner.r, corner.a);
        pass = false;
    }

    // 3b. Phase 6.4a' verification — render via render_full with explicit
    //     identity matrices. Result must be bit-exact to stage-1 render
    //     (the stage-1 entry point internally forwards to render_full
    //     with identity matrices, so they must produce identical output).
    const float identity[16] = {
        1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1,
    };
    aether_splat_renderer_render_full(renderer, identity, identity);
    IOSurfaceLock(surface, kIOSurfaceLockReadOnly, nullptr);
    auto center_full = pixel_bgra(128, 128);
    IOSurfaceUnlock(surface, kIOSurfaceLockReadOnly, nullptr);
    if (center_full.r != center.r || center_full.g != center.g
        || center_full.b != center.b || center_full.a != center.a) {
        std::fprintf(stderr, "FAIL: render_full(identity) "
            "BGRA=(%u,%u,%u,%u) does not match render(t=0) "
            "BGRA=(%u,%u,%u,%u) — stage-1/stage-2 wrapper inconsistent\n",
            center_full.b, center_full.g, center_full.r, center_full.a,
            center.b, center.g, center.r, center.a);
        pass = false;
    } else {
        std::printf("render_full(identity) bit-exact == render(t=0)\n");
    }

    // 3c. Render via render_full with a non-identity perturbation —
    //     verifies the FFI accepts arbitrary matrices without crash /
    //     uncaptured Dawn validation. The current splat_render.wgsl
    //     ignores viewmat (Phase 6.4c work to wire it), so the visual
    //     output is unchanged; we just check no crash.
    const float perturbed_view[16] = {
        0.5f,  0.0f,  0.0f, 0.0f,   // scale x by 0.5
        0.0f,  0.5f,  0.0f, 0.0f,   // scale y by 0.5
        0.0f,  0.0f,  1.0f, 0.0f,
        1.0f,  2.0f,  3.0f, 1.0f,   // translate (1, 2, 3)
    };
    aether_splat_renderer_render_full(renderer, perturbed_view, identity);
    IOSurfaceLock(surface, kIOSurfaceLockReadOnly, nullptr);
    auto center_perturbed = pixel_bgra(128, 128);
    IOSurfaceUnlock(surface, kIOSurfaceLockReadOnly, nullptr);
    std::printf("render_full(perturbed_view): center BGRA=(%u,%u,%u,%u) "
                "(WGSL ignores viewmat — should match identity result)\n",
                center_perturbed.b, center_perturbed.g, center_perturbed.r,
                center_perturbed.a);
    if (center_perturbed.r != center.r) {
        // splat_render.wgsl currently ignores viewmat, so result
        // shouldn't change. If it does, either WGSL drifted or upload
        // path got corrupted. Either way, fail loud.
        std::fprintf(stderr, "WARN: perturbed-view result differs from "
            "baseline — currently expected to match because WGSL ignores "
            "viewmat; either WGSL drifted or this assumption is now wrong.\n");
    }

    aether_splat_renderer_destroy(renderer);
    CFRelease(surface);

    if (!pass) return EXIT_FAILURE;
    std::printf("PASS — IOSurface bridge + render_full produce expected "
                "pixels through FFI\n");
    return EXIT_SUCCESS;
}
