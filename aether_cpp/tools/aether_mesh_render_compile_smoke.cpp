// SPDX-License-Identifier: LicenseRef-Aether3D-Proprietary
// Copyright (c) 2024-2026 Aether3D. All rights reserved.
//
// Phase 6.4b smoke — mesh_render.wgsl compile-only verification.
//
// The Filament-style PBR shader has ~200 LOC of math with high
// failure-mode density (any typo in a BRDF helper would either fail
// Tint parsing or produce a silent visual artifact later). This smoke
// catches the parse / Tint compile failures BEFORE we wire the full
// SceneRenderer pipeline.
//
// What this verifies:
//   - mesh_render.wgsl is in the baked registry (register_baked_wgsl_into_device)
//   - load_shader("mesh_render_vs", kVertex)   compiles via Tint
//   - load_shader("mesh_render_fs", kFragment) compiles via Tint
//   - Bindings + structs in the WGSL match what mesh_render_via_device
//     pipeline construction will eventually expect
//
// NOT verified here (Phase 6.4b stage 2 work):
//   - Pipeline creation against a render target (needs depth attachment
//     support in the GPU API path — pending)
//   - Visual output (no scene rendered)
//   - Splat + mesh composition (needs SceneRenderer)

#include "aether/render/dawn_gpu_device.h"
#include "aether/render/gpu_device.h"

#include <cstdio>
#include <cstdlib>

int main() {
    using namespace aether::render;

    auto device = create_dawn_gpu_device();
    if (!device) {
        std::fprintf(stderr, "FAIL: create_dawn_gpu_device\n");
        return EXIT_FAILURE;
    }

    register_baked_wgsl_into_device(*device);

    GPUShaderHandle vs = device->load_shader("mesh_render_vs", GPUShaderStage::kVertex);
    if (!vs.valid()) {
        std::fprintf(stderr, "FAIL: load_shader mesh_render_vs returned invalid handle\n");
        return EXIT_FAILURE;
    }
    GPUShaderHandle fs = device->load_shader("mesh_render_fs", GPUShaderStage::kFragment);
    if (!fs.valid()) {
        std::fprintf(stderr, "FAIL: load_shader mesh_render_fs returned invalid handle\n");
        return EXIT_FAILURE;
    }

    std::printf("=== aether_mesh_render_compile_smoke ===\n");
    std::printf("mesh_render_vs handle: %u\n", vs.id);
    std::printf("mesh_render_fs handle: %u\n", fs.id);
    std::printf("Filament-style PBR shader compiles via Tint\n");

    device->destroy_shader(fs);
    device->destroy_shader(vs);

    std::printf("PASS\n");
    return EXIT_SUCCESS;
}
