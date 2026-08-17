// SPDX-License-Identifier: LicenseRef-Aether3D-Proprietary
// Copyright (c) 2024-2026 Aether3D. All rights reserved.

#include "aether_structural_planesweep_c.h"

#if !defined(__EMSCRIPTEN__)
#include "stb_image.h"
#endif

extern "C" int32_t aether_planesweep_image_decode_jpeg(
    const char* jpeg_path,
    aether_planesweep_image_t** out_image,
    int32_t* out_width,
    int32_t* out_height) {
    if (out_image) *out_image = nullptr;
    if (out_width) *out_width = 0;
    if (out_height) *out_height = 0;
    if (!jpeg_path || jpeg_path[0] == '\0' || !out_image) {
        return AETHER_PLANESWEEP_ERR_BAD_ARGS;
    }
#if defined(__EMSCRIPTEN__)
    return AETHER_PLANESWEEP_ERR_UNSUPPORTED;
#else
    int width = 0;
    int height = 0;
    int channels = 0;
    stbi_uc* rgba = stbi_load(jpeg_path, &width, &height, &channels, 4);
    if (!rgba || width <= 1 || height <= 1) {
        if (rgba) stbi_image_free(rgba);
        return AETHER_PLANESWEEP_ERR_BAD_ARGS;
    }
    const int32_t rc = aether_planesweep_image_create_rgba(
        reinterpret_cast<const uint32_t*>(rgba), width, height, out_image);
    stbi_image_free(rgba);
    if (rc == AETHER_PLANESWEEP_OK) {
        if (out_width) *out_width = width;
        if (out_height) *out_height = height;
    }
    return rc;
#endif
}

extern "C" int32_t aether_planesweep_session_add_jpeg_view(
    aether_planesweep_session_t* session,
    int32_t scale_index,
    int32_t view_index,
    const char* jpeg_path,
    const float projection_row_major_3x4[12],
    const float camera_center_xyz[3],
    float patch_radius_m,
    float min_std_u8,
    int32_t* out_width,
    int32_t* out_height) {
    if (out_width) *out_width = 0;
    if (out_height) *out_height = 0;
    if (!session || !jpeg_path || jpeg_path[0] == '\0' ||
        !projection_row_major_3x4 || !camera_center_xyz) {
        return AETHER_PLANESWEEP_ERR_BAD_ARGS;
    }
#if defined(__EMSCRIPTEN__)
    (void)scale_index;
    (void)view_index;
    (void)patch_radius_m;
    (void)min_std_u8;
    return AETHER_PLANESWEEP_ERR_UNSUPPORTED;
#else
    int width = 0;
    int height = 0;
    int channels = 0;
    stbi_uc* rgba = stbi_load(jpeg_path, &width, &height, &channels, 4);
    if (!rgba || width <= 1 || height <= 1) {
        if (rgba) stbi_image_free(rgba);
        return AETHER_PLANESWEEP_ERR_BAD_ARGS;
    }
    const int32_t rc = aether_planesweep_session_add_view(
        session, scale_index, view_index,
        reinterpret_cast<const uint32_t*>(rgba), width, height,
        projection_row_major_3x4, camera_center_xyz,
        patch_radius_m, min_std_u8);
    stbi_image_free(rgba);
    if (rc == AETHER_PLANESWEEP_OK) {
        if (out_width) *out_width = width;
        if (out_height) *out_height = height;
    }
    return rc;
#endif
}

extern "C" int32_t aether_planesweep_session_add_jpeg_view_scales(
    aether_planesweep_session_t* session,
    int32_t view_index,
    const char* jpeg_path,
    const float projection_row_major_3x4[12],
    const float camera_center_xyz[3],
    const float* patch_radius_m_by_scale,
    const float* min_std_u8_by_scale,
    int32_t scale_count,
    int32_t* out_width,
    int32_t* out_height) {
    if (out_width) *out_width = 0;
    if (out_height) *out_height = 0;
    if (!session || !jpeg_path || jpeg_path[0] == '\0' ||
        !projection_row_major_3x4 || !camera_center_xyz ||
        !patch_radius_m_by_scale || !min_std_u8_by_scale || scale_count <= 0) {
        return AETHER_PLANESWEEP_ERR_BAD_ARGS;
    }
#if defined(__EMSCRIPTEN__)
    (void)view_index;
    return AETHER_PLANESWEEP_ERR_UNSUPPORTED;
#else
    aether_planesweep_image_t* image = nullptr;
    int32_t width = 0;
    int32_t height = 0;
    const int32_t decode_rc = aether_planesweep_image_decode_jpeg(
        jpeg_path, &image, &width, &height);
    if (decode_rc != AETHER_PLANESWEEP_OK) return decode_rc;
    const int32_t rc = aether_planesweep_session_add_image_view_scales(
        session, view_index, image, projection_row_major_3x4, camera_center_xyz,
        patch_radius_m_by_scale, min_std_u8_by_scale, scale_count);
    aether_planesweep_image_free(image);
    if (rc == AETHER_PLANESWEEP_OK) {
        if (out_width) *out_width = width;
        if (out_height) *out_height = height;
    }
    return rc;
#endif
}
