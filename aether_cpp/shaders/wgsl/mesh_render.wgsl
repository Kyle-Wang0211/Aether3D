// SPDX-License-Identifier: LicenseRef-Aether3D-Proprietary
// Copyright (c) 2024-2026 Aether3D. All rights reserved.
//
// ─── Phase 6.4b — mesh_render.wgsl (Filament-style PBR) ────────────────
//
// Cook-Torrance Bidirectional Reflectance Distribution Function:
//   BRDF = D(NoH) * F(VoH, F0) * G(NoV, NoL, alpha) / (4 * NoV * NoL)
// where:
//   D = GGX normal distribution
//   F = Schlick Fresnel approximation
//   G = Smith geometric attenuation with Schlick-GGX
//
// Math source (decision pin: zero in-house BRDF math):
//   Filament — Apache-2.0, Google's PBR reference
//   https://github.com/google/filament/blob/main/shaders/src/brdf.fs
//   https://google.github.io/filament/Filament.html (chapter 4.7 "Specular BRDF")
//
// Reference image: KhronosGroup glTF-Sample-Models DamagedHelmet
// rendered with Filament — used for visual A/B in Phase 6.4b verify.
//
// Shading pipeline:
//   vs_main:
//     - transform position by view_proj * model
//     - transform normal by inverse-transpose(model) (lit by camera-space)
//     - build TBN basis from normal + tangent.xyz + bitangent_sign(tangent.w)
//   fs_main:
//     - sample base_color (sRGB → linear), metallic_roughness, normal map,
//       occlusion, emissive textures
//     - reconstruct normal from TBN + normal-map sample
//     - compute F0 = lerp(0.04, base_color, metallic) (dielectric vs metal)
//     - evaluate Cook-Torrance for one directional light + ambient
//     - tonemap-less linear output (post-process is out of scope, runtime
//       handles the linear→sRGB framebuffer conversion)
//
// Why this shader is in WGSL not MSL/GLSL: decision pin 7 — WGSL is the
// only shader source-of-truth. naga_oil ETL re-baked into binary by the
// CMake bake step (decision pin 18).

// ─── Uniforms ──────────────────────────────────────────────────────────

struct Camera {
    view_proj:  mat4x4f,
    camera_pos: vec4f,
}

struct ModelTransform {
    model:      mat4x4f,
    // (model^-1)^T — used to transform normals safely under non-uniform
    // scale. For uniform-scale objects this equals model with the
    // translation row zeroed; we precompute regardless for generality.
    normal_mat: mat4x4f,
}

struct Light {
    // Directional light. direction.xyz is the world-space direction
    // FROM light TO surface (i.e. the sun's rays travel along this
    // vector). Negate at sample sites where you want surface→light.
    direction: vec4f,
    color:     vec4f,
    intensity: f32,
    _pad0:     f32,
    _pad1:     f32,
    _pad2:     f32,
}

struct PbrFactors {
    base_color:         vec4f,
    metallic_roughness: vec2f,  // x=metallic, y=roughness
    occlusion_strength: f32,
    _pad:               f32,
    emissive:           vec3f,
    _pad2:              f32,
}

@group(0) @binding(0) var<uniform> camera:      Camera;
@group(0) @binding(1) var<uniform> model_xform: ModelTransform;
@group(0) @binding(2) var<uniform> light:       Light;
@group(0) @binding(3) var<uniform> pbr_factors: PbrFactors;

@group(0) @binding(4)  var base_color_tex:         texture_2d<f32>;
@group(0) @binding(5)  var pbr_sampler:            sampler;
@group(0) @binding(6)  var metallic_roughness_tex: texture_2d<f32>;
@group(0) @binding(7)  var normal_tex:             texture_2d<f32>;
@group(0) @binding(8)  var occlusion_tex:          texture_2d<f32>;
@group(0) @binding(9)  var emissive_tex:           texture_2d<f32>;

// ─── Vertex stage ─────────────────────────────────────────────────────

struct VsIn {
    @location(0) position: vec3f,
    @location(1) normal:   vec3f,
    @location(2) uv:       vec2f,
    @location(3) tangent:  vec4f,  // .xyz = tangent dir, .w = bitangent sign (±1)
}

struct VsOut {
    @builtin(position) clip_pos:      vec4f,
    @location(0) world_pos:           vec3f,
    @location(1) world_normal:        vec3f,
    @location(2) world_tangent:       vec3f,
    @location(3) world_bitangent:     vec3f,
    @location(4) uv:                  vec2f,
}

@vertex
fn vs_main(in: VsIn) -> VsOut {
    var out: VsOut;
    let world_pos4 = model_xform.model * vec4f(in.position, 1.0);
    out.world_pos = world_pos4.xyz;
    out.clip_pos = camera.view_proj * world_pos4;

    // Normal transform: rotation-only part of model. Using the
    // pre-computed normal_mat avoids per-vertex matrix inverse.
    let n = normalize((model_xform.normal_mat * vec4f(in.normal, 0.0)).xyz);
    let t = normalize((model_xform.model * vec4f(in.tangent.xyz, 0.0)).xyz);

    out.world_normal    = n;
    out.world_tangent   = t;
    out.world_bitangent = cross(n, t) * in.tangent.w;
    out.uv              = in.uv;
    return out;
}

// ─── BRDF helpers (Filament style) ────────────────────────────────────

const PI: f32 = 3.14159265359;

// GGX / Trowbridge-Reitz normal distribution.
// Filament reference: brdf.fs § distribution()
fn d_ggx(noh: f32, roughness: f32) -> f32 {
    let a  = roughness * roughness;
    let a2 = a * a;
    let f  = (noh * a2 - noh) * noh + 1.0;
    return a2 / max(PI * f * f, 1e-7);
}

// Smith geometric attenuation with Schlick-GGX.
// Filament reference: brdf.fs § visibility() (this is V, the unnormalized
// G/(4 NoV NoL) factor; we use the separated G + denominator form for
// clarity and parity with most online PBR references).
fn g_schlick_ggx(n_dot: f32, roughness: f32) -> f32 {
    let r = roughness + 1.0;
    let k = (r * r) / 8.0;
    return n_dot / (n_dot * (1.0 - k) + k);
}
fn g_smith(nov: f32, nol: f32, roughness: f32) -> f32 {
    return g_schlick_ggx(nov, roughness) * g_schlick_ggx(nol, roughness);
}

// Schlick Fresnel — F0 is the reflectance at normal incidence.
fn f_schlick(cos_theta: f32, f0: vec3f) -> vec3f {
    return f0 + (vec3f(1.0) - f0) * pow(1.0 - cos_theta, 5.0);
}

// glTF stores base color textures as sRGB-encoded. Convert to linear so
// the Cook-Torrance math operates in linear-light space.
fn srgb_to_linear(c: vec3f) -> vec3f {
    let cutoff = step(c, vec3f(0.04045));
    let lo = c / 12.92;
    let hi = pow((c + 0.055) / 1.055, vec3f(2.4));
    return mix(hi, lo, cutoff);
}

// ─── Fragment stage ───────────────────────────────────────────────────

@fragment
fn fs_main(in: VsOut) -> @location(0) vec4f {
    // ─── UNLIT MODE (project decision 2026-05-01) ──────────────────────
    // PocketWorld's long-term content is captured 3D scans whose
    // baseColor textures already bake in the natural lighting from
    // the capture environment. Stacking a BRDF + directional light on
    // top double-lights them into oversaturated noise. So fragment
    // shading is reduced to: srgb-decoded base color × base_color
    // factor + emissive. AO is still respected as a multiplier
    // because it darkens crevices believably even on already-baked
    // textures.
    //
    // The Khronos PBR sample assets currently in the seeded feed
    // (DamagedHelmet, ToyCar, etc.) DON'T have baked lighting and
    // will look flat under this mode — that's accepted as
    // placeholder-content collateral. When real captures replace the
    // seed data the unlit path is correct.
    //
    // The Cook-Torrance / Smith / Schlick helper functions above stay
    // in the shader unused for now; flipping back to lit (e.g. for a
    // debug toggle) is a one-block restore. They incur no GPU cost
    // when not called.
    // GAMMA: textures are loaded as RGBA8Unorm (NOT _Srgb variant —
    // see glb_loader.cpp's create_texture call), so textureSample
    // returns the raw bytes the artist authored — already sRGB-
    // encoded. Our IOSurface output is BGRA8Unorm; the Flutter
    // compositor then reads those bytes back as sRGB-encoded for
    // display. So the right unlit path is SAMPLE → MULTIPLY →
    // OUTPUT, all staying in sRGB-encoded space. Calling
    // srgb_to_linear() here was a double-decode bug — input
    // sRGB 0.5 became linear 0.21, written to the byte as 0.21,
    // then Flutter interpreted that 0.21 as perceptual sRGB → ~5%
    // linear. The chess board, Antique Camera, and Corset all
    // rendered ~5x too dark. For PROPER PBR (future "lit" toggle),
    // we'd switch glb_loader to RGBA8UnormSrgb (auto-decode on
    // sample) + write a BGRA8UnormSrgb framebuffer (auto-encode on
    // output). For unlit, the no-conversion path is both simpler
    // AND correct.
    let base_sample = textureSample(base_color_tex, pbr_sampler, in.uv);

    // ─── Compensate for "tint-down" baseColorFactor in unlit mode ─────
    //
    // PBR materials authored for lit pipelines often have
    // baseColorFactor < (1,1,1) — the artist tints down expecting
    // direct + ambient light to multiply UP and balance to a target
    // brightness. Khronos ToyCar's `Fabric` material is the canonical
    // example: factor=(0.15, 0.15, 0.15) on a fabric texture. Lit:
    // 0.15 × texture × ~5 light = ~0.6 visible gray. Unlit:
    // 0.15 × texture × 1 = ~0.09 ≈ black blob.
    //
    // Heuristic: if the artist's tint is bright (≥ 0.7 average),
    // honour it — they meant deliberate color shift. If it's tinted
    // DOWN (< 0.7), they were balancing for lighting that doesn't
    // exist here, so ignore the rgb tint and use (1,1,1). The alpha
    // channel is ALWAYS honoured — it's transparency intent, not
    // brightness intent.
    //
    // Real-world impact:
    //   • Khronos PBR samples (factor 0.1-0.5): rendered as raw
    //     texture color → visible & natural-looking
    //   • Real captured scans (factor=1,1,1 universally): unchanged
    //   • Artist who deliberately wants a DARK material via factor:
    //     loses some authoring intent. Acceptable trade-off — that
    //     material was already broken in unlit mode anyway.
    let bcf = pbr_factors.base_color.rgb;
    let bcf_brightness = (bcf.r + bcf.g + bcf.b) * (1.0 / 3.0);
    let effective_bcf = select(vec3f(1.0), bcf, bcf_brightness >= 0.7);

    let base_color = vec4f(
        base_sample.rgb * effective_bcf,
        base_sample.a * pbr_factors.base_color.a
    );
    let emis_sample = textureSample(emissive_tex, pbr_sampler, in.uv).rgb;
    let emissive    = emis_sample * pbr_factors.emissive;

    // Pure unlit — base color + emissive, full stop.
    //
    // glTF 2.0 spec, Materials §4.6.4: "occlusion textures indicate
    // areas that receive less indirect lighting. Direct lighting is
    // NOT affected." Multiplying base_color by AO in an unlit
    // pipeline (no direct OR indirect light to occlude) breaks the
    // contract — every sample with an AO contact shadow plane (e.g.
    // the Khronos ToyCar's ground plane, the Corset's base) renders
    // as a pure black blob instead of a subtle gray shadow. Real
    // captured scans bake their lighting + AO directly into the
    // baseColor texture and don't ship a separate AO map; the unlit
    // path is correct for them by construction.
    //
    // OUTPUT: premultiplied alpha, so the pipeline's blend state
    // (One / OneMinusSrcAlpha) composites translucent fragments over
    // opaque ones correctly. glTF's `alphaMode: BLEND` materials
    // (typical of contact-shadow planes) pre-multiply through the
    // `* base_color.a` here; opaque materials hit `a == 1` and the
    // multiply is a no-op.
    //
    // The unused bindings (`light`, `metallic_roughness_tex`,
    // `normal_tex`, `occlusion_tex`) are preserved in the BindGroup
    // because scene_iosurface_renderer.cpp ships an EXPLICIT
    // BindGroupLayout (see create_mesh_bind_group_layout) that locks
    // all 10 entries regardless of which ones the shader samples.
    // Adding a debug "lit" toggle later is a one-block restore — no
    // layout churn.
    let lit = base_color.rgb + emissive;
    return vec4f(lit * base_color.a, base_color.a);
}
