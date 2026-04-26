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
    // Sample textures.
    let base_sample = textureSample(base_color_tex, pbr_sampler, in.uv);
    // glTF spec: base color texture is sRGB-encoded → convert.
    let base_color = vec4f(
        srgb_to_linear(base_sample.rgb) * pbr_factors.base_color.rgb,
        base_sample.a * pbr_factors.base_color.a
    );

    // glTF metallic-roughness texture: G=roughness, B=metallic.
    let mr = textureSample(metallic_roughness_tex, pbr_sampler, in.uv);
    let metallic  = mr.b * pbr_factors.metallic_roughness.x;
    // Clamp roughness away from 0 — fully smooth surfaces produce a
    // delta-function specular that aliases visibly. Filament's lower
    // bound is 0.045; we use 0.05 for slightly more conservative.
    let roughness = max(0.05, mr.g * pbr_factors.metallic_roughness.y);

    // Normal map: sampled value is in [0, 1], remap to [-1, 1] in
    // tangent space, then transform to world space via TBN.
    let n_tex = textureSample(normal_tex, pbr_sampler, in.uv).xyz * 2.0 - 1.0;
    let tbn   = mat3x3f(in.world_tangent, in.world_bitangent, in.world_normal);
    let n     = normalize(tbn * n_tex);

    // Ambient occlusion: sampled R channel modulates the ambient term.
    // Strength factor lets glTF override how much AO bleeds in.
    let ao_sample = textureSample(occlusion_tex, pbr_sampler, in.uv).r;
    let ao        = mix(1.0, ao_sample, pbr_factors.occlusion_strength);

    // Emissive: sRGB-encoded per glTF spec.
    let emis_sample = textureSample(emissive_tex, pbr_sampler, in.uv).rgb;
    let emissive    = srgb_to_linear(emis_sample) * pbr_factors.emissive;

    // BRDF terms.
    let v   = normalize(camera.camera_pos.xyz - in.world_pos);
    let l   = normalize(-light.direction.xyz);  // light dir → surface, negate for surface → light
    let h   = normalize(v + l);
    let nov = max(dot(n, v), 0.001);  // ε to avoid 0 denom in Smith
    let nol = max(dot(n, l), 0.0);
    let noh = max(dot(n, h), 0.0);
    let voh = max(dot(v, h), 0.0);

    // F0: 0.04 dielectric baseline, metals reflect their base color.
    let f0 = mix(vec3f(0.04), base_color.rgb, metallic);
    let d  = d_ggx(noh, roughness);
    let g  = g_smith(nov, nol, roughness);
    let f  = f_schlick(voh, f0);

    let specular = (d * g) * f / max(4.0 * nov * nol, 1e-7);
    let kd       = (vec3f(1.0) - f) * (1.0 - metallic);
    let diffuse  = kd * base_color.rgb / PI;

    // Constant ambient — Phase 7 swaps for IBL once the cubemap pipeline
    // lands. 0.03 is the Filament-default low-energy fallback.
    let ambient  = base_color.rgb * 0.03 * ao;

    let lit = ambient
            + (diffuse + specular) * light.color.rgb * light.intensity * nol
            + emissive;

    return vec4f(lit, base_color.a);
}
