// SPDX-License-Identifier: LicenseRef-Aether3D-Proprietary
// Copyright (c) 2024-2026 Aether3D. All rights reserved.

#include "aether/render/shader_source.h"

#include <cstdio>
#include <cstring>

int main() {
    int failed = 0;

    const char* msl = aether::render::brdf_shader_source(aether::render::ShaderLanguage::kMSL);
    const char* glsl = aether::render::brdf_shader_source(aether::render::ShaderLanguage::kGLSL_ES300);
    if (msl == nullptr || glsl == nullptr || std::strlen(msl) == 0u || std::strlen(glsl) == 0u) {
        std::fprintf(stderr, "brdf_shader_source returned empty string\n");
        failed++;
    }

    const char* sh = aether::render::sh_evaluation_source(aether::render::ShaderLanguage::kGLSL_Vulkan);
    const char* flip = aether::render::flip_rotation_source(aether::render::ShaderLanguage::kMSL);
    if (sh == nullptr || flip == nullptr || std::strlen(sh) == 0u || std::strlen(flip) == 0u) {
        std::fprintf(stderr, "shader helper source returned empty string\n");
        failed++;
    }

    if (aether::render::shader_source_version() == 0u) {
        std::fprintf(stderr, "shader_source_version must be non-zero\n");
        failed++;
    }

    return failed;
}
