// SPDX-License-Identifier: LicenseRef-Aether3D-Proprietary
// Copyright (c) 2024-2026 Aether3D. All rights reserved.
//
// ─── Phase 6.3a v3 — splat_render.wgsl (Aether3D-original) ─────────────
//
// Vertex+fragment + instanced quads viewer rasterizer. Replaces Brush's
// rasterize.wgsl compute path for the VIEWER flow only — Brush's compute
// rasterizer is retained for the TRAINING flow (gradient backprop on the
// per-tile bin layout). See PHASE6_PLAN.md v3 §3 "Viewer 数据流".
//
// Why vertex+fragment for viewer:
//   - MetalSplatter (Apple App Store, MIT) ships the same model
//   - Spark.js / PlayCanvas same instanced-quad model
//   - GauRast: 23× speedup vs compute rasterizer on mobile GPUs
//   - C3DGS: 3.5× speedup, same model
//   - Compute path broken cross-platform: Brush #77 Adreno crash,
//     Flutter #157811 Maleoon Vulkan disabled, neither affects vert+frag
//
// Per-instance: one ProjectedSplat (output of project_visible.wgsl).
// Each instance emits 6 vertices forming a quad (TriangleList). Quad size
// = 3-sigma radius from the conic; fragment shader discards low-α pixels
// outside the Gaussian's effective support.
//
// Inputs (must match aether_cpp/tools/aether_dawn_splat_test_data.h):
//   @group(0) @binding(0) RenderUniforms — img_size used for NDC mapping
//   @group(0) @binding(1) array<ProjectedSplat> — output of project_visible
//
// Output: single color attachment, RGBA8Unorm, premultiplied alpha
//         (blend One / OneMinusSrcAlpha; harness sets this).

// Read-only mirror of Brush's RenderUniforms. num_visible is `atomic<u32>`
// in project_forward.wgsl (writer side) but here we just read its value;
// WGSL forbids `atomic<...>` in `<storage, read>` bindings, so we declare
// it as plain `u32` — identical 4-byte / 4-aligned layout per WGSL spec.
struct RenderUniforms {
    viewmat: mat4x4f,
    focal: vec2f,
    img_size: vec2u,
    tile_bounds: vec2u,
    pixel_center: vec2f,
    camera_position: vec4f,
    sh_degree: u32,
    num_visible: u32,
    total_splats: u32,
    max_intersects: u32,
    background: vec4f,
}

struct ProjectedSplat {
    xy_x: f32, xy_y: f32,
    conic_x: f32, conic_y: f32, conic_z: f32,
    color_r: f32, color_g: f32, color_b: f32, color_a: f32,
}

@group(0) @binding(0) var<storage, read> uniforms: RenderUniforms;
@group(0) @binding(1) var<storage, read> splats: array<ProjectedSplat>;

struct VsOut {
    @builtin(position) clip_pos: vec4f,
    @location(0) delta: vec2f,    // pixel offset from splat center
    @location(1) conic: vec3f,    // (xx, xy, yy) — conic_x, conic_y, conic_z
    @location(2) color: vec4f,    // (rgb, a) — premultiplied happens in fs
}

@vertex
fn vs_main(@builtin(vertex_index) vi: u32,
           @builtin(instance_index) ii: u32) -> VsOut {
    let s = splats[ii];
    let conic = vec3f(s.conic_x, s.conic_y, s.conic_z);
    let center = vec2f(s.xy_x, s.xy_y);

    // Phase 6.4f: invalid / unwritten projected splat (e.g. project_visible
    // never wrote to this slot because the index ≥ num_visible — see
    // scene_iosurface_renderer's per-frame clearBuffer of the projected
    // buffer). Without this early-out, conic.x = 0 → inverseSqrt(1e-6) ≈
    // 1000 → r = 3000 pixels; every invalid instance would rasterize a
    // viewport-covering quad. Emit a clip-culled degenerate point so all
    // 6 vertices collapse to the same outside-clip-space position and
    // generate zero fragments.
    if (s.color_a <= 0.0 || (conic.x <= 0.0 && conic.z <= 0.0)) {
        var o_skip: VsOut;
        o_skip.clip_pos = vec4f(2.0, 2.0, 2.0, 1.0);  // NDC z = 2 → far-clip
        o_skip.delta = vec2f(0.0);
        o_skip.conic = vec3f(0.0);
        o_skip.color = vec4f(0.0);
        return o_skip;
    }

    // 3-sigma radius from conic eigenvalues. For diagonal-dominant conic
    // (most splats post-EVD), 1/sqrt(conic_x) ≈ X-stddev; bound the quad
    // by the larger of X/Y stddev. Mild over-coverage (≤4×) is harmless
    // because the fragment shader discards low-α pixels.
    let sigma_x = inverseSqrt(max(conic.x, 1e-6));
    let sigma_y = inverseSqrt(max(conic.z, 1e-6));
    let r = 3.0 * max(sigma_x, sigma_y);

    // 6 vertices = TriangleList quad. Order: BL,BR,TR | BL,TR,TL.
    var offsets = array<vec2f, 6>(
        vec2f(-1.0, -1.0),
        vec2f( 1.0, -1.0),
        vec2f( 1.0,  1.0),
        vec2f(-1.0, -1.0),
        vec2f( 1.0,  1.0),
        vec2f(-1.0,  1.0),
    );
    let off = offsets[vi];
    let pixel_pos = center + off * r;

    // Pixel → clip space. Y flipped (pixel origin top-left, NDC y-up).
    let img = vec2f(uniforms.img_size);
    let clip_xy = vec2f(
        (pixel_pos.x / img.x) * 2.0 - 1.0,
        1.0 - (pixel_pos.y / img.y) * 2.0,
    );

    var o: VsOut;
    o.clip_pos = vec4f(clip_xy, 0.0, 1.0);
    o.delta = pixel_pos - center;
    o.conic = conic;
    o.color = vec4f(s.color_r, s.color_g, s.color_b, s.color_a);
    return o;
}

@fragment
fn fs_main(in: VsOut) -> @location(0) vec4f {
    // Gaussian σ = 0.5 (conic_xx Δx² + conic_yy Δy²) + conic_xy Δx Δy.
    let d = in.delta;
    let sigma = 0.5 * (in.conic.x * d.x * d.x + in.conic.z * d.y * d.y)
                + in.conic.y * d.x * d.y;
    if (sigma < 0.0) {
        discard;
    }
    let alpha = min(0.999, in.color.a * exp(-sigma));
    if (alpha < 1.0 / 255.0) {
        discard;
    }
    // Premultiplied output: (rgb·α, α). Blend = One / OneMinusSrcAlpha,
    // wired by harness load_render_pipeline().
    return vec4f(in.color.rgb * alpha, alpha);
}
