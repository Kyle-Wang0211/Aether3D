// Adapted from Brush (https://github.com/ArthurBrussee/brush)
// Original: brush/crates/brush-render/src/shaders/<file>
// Brush version: v0.3.0 (commit 3edecbb2fe79d3e2c87eeab85b15e0b1dd10d486)
// License: Apache-2.0 — see aether_cpp/third_party/brush/LICENSE
// Math source: gSplat reference kernels (3DGS paper, Kerbl et al. 2023)
//
// ┏━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━┓
// ┃ Phase 6.4f.3.a — MANUAL OVERRIDE: packed 16-byte splat format       ┃
// ┃                                                                      ┃
// ┃ Original Brush kernel reads 4 separate buffers (means / quats /     ┃
// ┃ log_scales / raw_opacities) per splat — total ~36 bytes/splat       ┃
// ┃ on GPU after vec4 padding. This file replaces that with ONE         ┃
// ┃ packed buffer at 16 bytes/splat (Spark-compatible encoding).        ┃
// ┃                                                                      ┃
// ┃ DO NOT re-run scripts/wgsl_preprocess on this file — the manual     ┃
// ┃ override below will be clobbered. To regenerate: also re-apply      ┃
// ┃ this packed-format diff to _brush_raw/project_forward.wgsl.         ┃
// ┃                                                                      ┃
// ┃ Layout per packed splat (matches packed_splats.h::PackedSplat):     ┃
// ┃   bytes  0..3  : rgba (sRGB rgb + linear alpha bytes)               ┃
// ┃   bytes  4..9  : center xyz as 3 fp16                               ┃
// ┃   bytes 10..11 : quat oct UV (axis encoding)                        ┃
// ┃   bytes 12..14 : log_scale xyz bytes                                ┃
// ┃   byte  15    : quat angle byte                                     ┃
// ┃ Total: 16 bytes — represented as `array<vec4<u32>>` in WGSL,        ┃
// ┃ with bytewise interpretation defined by the unpack_* helpers.        ┃
// ┗━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━┛
//

struct RenderUniforms {
    viewmat: mat4x4<f32>,
    focal: vec2<f32>,
    img_size: vec2<u32>,
    tile_bounds: vec2<u32>,
    pixel_center: vec2<f32>,
    camera_position: vec4<f32>,
    sh_degree: u32,
    num_visible: atomic<u32>,
    total_splats: u32,
    max_intersects: u32,
    background: vec4<f32>,
    // Phase 6.4f.4.b — runtime LOD cull threshold. Splats whose
    // post-projection 2D bounding-box extent is below this value (in
    // pixels) are dropped early in this kernel without ever entering
    // the visible list. 0.0 disables the cull (legacy behavior).
    // WGSL's host-shareable struct layout pads the struct end to the
    // largest member alignment (16 B from the vec4 background) — so
    // a single trailing f32 here implicitly pads to a 16-B-aligned
    // 160-B struct, matching RenderArgsStorage on the C++ side.
    lod_extent_min: f32,
}

const COV_BLUR: f32 = 0.3f;
const PI_OVER_2_: f32 = 1.5707963f;

@group(0) @binding(0)
var<storage, read_write> uniforms: RenderUniforms;
@group(0) @binding(1)
var<storage> packed_splats: array<vec4<u32>>;
@group(0) @binding(2)
var<storage, read_write> global_from_compact_gid: array<u32>;
@group(0) @binding(3)
var<storage, read_write> depths: array<f32>;

// ─── Packed-splat unpack helpers ────────────────────────────────────
// Matches encode_*_* helpers in include/aether/splat/packed_splats.h.
// Test parity: tools/aether_dawn_packed_splat_smoke.cpp compares the
// CPU pack(unpack(P)) round-trip against this kernel's unpack(P).

// Decode an octahedral-encoded unit axis + angle byte → quaternion (w,x,y,z).
fn unpack_quat(uv0: u32, uv1: u32, angle_byte: u32) -> vec4<f32> {
    let ox = (f32(uv0) / 255.0f) * 2.0f - 1.0f;
    let oy = (f32(uv1) / 255.0f) * 2.0f - 1.0f;
    var az = 1.0f - abs(ox) - abs(oy);
    var ax = ox;
    var ay = oy;
    if (az < 0.0f) {
        let tx = (1.0f - abs(oy)) * select(-1.0f, 1.0f, ox >= 0.0f);
        let ty = (1.0f - abs(ox)) * select(-1.0f, 1.0f, oy >= 0.0f);
        ax = tx;
        ay = ty;
    }
    let len = sqrt(ax * ax + ay * ay + az * az);
    if (len < 1e-8f) {
        return vec4<f32>(1.0f, 0.0f, 0.0f, 0.0f);
    }
    let inv = 1.0f / len;
    ax = ax * inv;
    ay = ay * inv;
    az = az * inv;
    let theta = f32(angle_byte) * (PI_OVER_2_ / 255.0f);
    let s = sin(theta);
    return vec4<f32>(cos(theta), ax * s, ay * s, az * s);
}

// Decode log-encoded scale byte → linear scale (positive).
//   Inverse of encode_log_scale: byte → ((byte/255)*16 - 8) → exp.
fn unpack_log_scale_byte(b: u32) -> f32 {
    let n = f32(b) / 255.0f;
    let log_val = n * 16.0f - 8.0f;
    return exp(log_val);
}

struct UnpackedSplat {
    position:    vec3<f32>,
    scale:       vec3<f32>,    // linear (already exp'd from log)
    quat:        vec4<f32>,    // (w, x, y, z), unit
    raw_opacity: f32,           // pre-sigmoid logit (so kernel re-sigmoids)
}

fn read_splat(idx: u32) -> UnpackedSplat {
    let p = packed_splats[idx];
    // p.x: rgba bytes — not needed in project_forward (only opacity)
    // p.y: low 16 = center.x fp16, high 16 = center.y fp16
    // p.z: low 16 = center.z fp16, byte[2] = quat_uv0, byte[3] = quat_uv1
    // p.w: byte[0..2] = log_scale xyz, byte[3] = quat angle
    let cxy = unpack2x16float(p.y);
    let cz_etc = unpack2x16float(p.z);
    let position = vec3<f32>(cxy.x, cxy.y, cz_etc.x);

    let uv0 = (p.z >> 16u) & 0xFFu;
    let uv1 = (p.z >> 24u) & 0xFFu;
    let angle = (p.w >> 24u) & 0xFFu;
    let quat = unpack_quat(uv0, uv1, angle);

    let sx = unpack_log_scale_byte(p.w & 0xFFu);
    let sy = unpack_log_scale_byte((p.w >> 8u) & 0xFFu);
    let sz = unpack_log_scale_byte((p.w >> 16u) & 0xFFu);
    let scale = vec3<f32>(sx, sy, sz);

    // Alpha byte → linear opacity in [0,1]; project_forward expects logit
    // (it will sigmoid back). Convert: alpha_byte/255 → logit.
    let alpha_lin = clamp(f32(p.x >> 24u) / 255.0f, 1.0e-6f, 1.0f - 1.0e-6f);
    let raw_opacity = log(alpha_lin / (1.0f - alpha_lin));

    var out: UnpackedSplat;
    out.position = position;
    out.scale = scale;
    out.quat = quat;
    out.raw_opacity = raw_opacity;
    return out;
}

// ─── Original Brush math (unchanged) ────────────────────────────────

fn sigmoid(x: f32) -> f32 {
    return (1f / (1f + exp(-(x))));
}

fn quat_to_mat(quat_1: vec4<f32>) -> mat3x3<f32> {
    let w = quat_1.x;
    let x_1 = quat_1.y;
    let y = quat_1.z;
    let z = quat_1.w;
    let x2_ = (x_1 * x_1);
    let y2_ = (y * y);
    let z2_ = (z * z);
    let xy = (x_1 * y);
    let xz = (x_1 * z);
    let yz = (y * z);
    let wx = (w * x_1);
    let wy = (w * y);
    let wz = (w * z);
    return mat3x3<f32>(vec3<f32>((1f - (2f * (y2_ + z2_))), (2f * (xy + wz)), (2f * (xz - wy))), vec3<f32>((2f * (xy - wz)), (1f - (2f * (x2_ + z2_))), (2f * (yz + wx))), vec3<f32>((2f * (xz + wy)), (2f * (yz - wx)), (1f - (2f * (x2_ + y2_)))));
}

fn scale_to_mat(scale: vec3<f32>) -> mat3x3<f32> {
    return mat3x3<f32>(vec3<f32>(scale.x, 0f, 0f), vec3<f32>(0f, scale.y, 0f), vec3<f32>(0f, 0f, scale.z));
}

fn calc_cov3d(scale_1: vec3<f32>, quat_2: vec4<f32>) -> mat3x3<f32> {
    let _e1 = quat_to_mat(quat_2);
    let _e3 = scale_to_mat(scale_1);
    let M = (_e1 * _e3);
    return (M * transpose(M));
}

fn calc_cam_J(mean_c: vec3<f32>, focal: vec2<f32>, img_size: vec2<u32>, pixel_center: vec2<f32>) -> mat3x2<f32> {
    let lims_pos = (((1.15f * vec2<f32>(img_size.xy)) - pixel_center) / focal);
    let lims_neg = (((-0.15f * vec2<f32>(img_size.xy)) - pixel_center) / focal);
    let rz = (1f / mean_c.z);
    let uv_clipped = clamp((mean_c.xy * rz), lims_neg, lims_pos);
    let duv_dxy = (focal * rz);
    let J = mat3x2<f32>(vec2<f32>(duv_dxy.x, 0f), vec2<f32>(0f, duv_dxy.y), (-(duv_dxy) * uv_clipped));
    return J;
}

fn calc_cov2d(cov3d: mat3x3<f32>, mean_c_1: vec3<f32>, focal_1: vec2<f32>, img_size_1: vec2<u32>, pixel_center_1: vec2<f32>, viewmat: mat4x4<f32>) -> mat2x2<f32> {
    var cov2d: mat2x2<f32>;

    let R = mat3x3<f32>(viewmat[0].xyz, viewmat[1].xyz, viewmat[2].xyz);
    let covar_cam = ((R * cov3d) * transpose(R));
    let _e16 = calc_cam_J(mean_c_1, focal_1, img_size_1, pixel_center_1);
    cov2d = ((_e16 * covar_cam) * transpose(_e16));
    let _e24 = cov2d[0][0];
    cov2d[0][0] = (_e24 + COV_BLUR);
    let _e29 = cov2d[1][1];
    cov2d[1][1] = (_e29 + COV_BLUR);
    let _e31 = cov2d;
    return _e31;
}

fn compute_bbox_extent(cov2d_1: mat2x2<f32>, power_threshold: f32) -> vec2<f32> {
    return vec2<f32>(sqrt(((2f * power_threshold) * cov2d_1[0].x)), sqrt(((2f * power_threshold) * cov2d_1[1].y)));
}

@compute @workgroup_size(256, 1, 1)
fn main(@builtin(global_invocation_id) global_id: vec3<u32>) {
    let global_gid = global_id.x;
    let _e4 = uniforms.total_splats;
    if (global_gid >= _e4) {
        return;
    }
    let s = read_splat(global_gid);

    let img_size_2 = uniforms.img_size;
    let viewmat_1 = uniforms.viewmat;
    let R_1 = mat3x3<f32>(viewmat_1[0].xyz, viewmat_1[1].xyz, viewmat_1[2].xyz);
    let mean_c_2 = ((R_1 * s.position) + viewmat_1[3].xyz);
    if ((mean_c_2.z < 0.01f) || (mean_c_2.z > 10000000000f)) {
        return;
    }
    let scale_2 = s.scale;
    let quat_norm_sqr = dot(s.quat, s.quat);
    if (quat_norm_sqr < 0.000001f) {
        return;
    }
    let quat = s.quat * inverseSqrt(quat_norm_sqr);
    let _e52 = calc_cov3d(scale_2, quat);
    let _e55 = uniforms.focal;
    let _e58 = uniforms.img_size;
    let _e61 = uniforms.pixel_center;
    let _e62 = calc_cov2d(_e52, mean_c_2, _e55, _e58, _e61, viewmat_1);
    if (abs(determinant(_e62)) < 0.000000000000000000000001f) {
        return;
    }
    let _e69 = uniforms.focal;
    let _e78 = uniforms.pixel_center;
    let mean2d = (((_e69 * mean_c_2.xy) * (1f / mean_c_2.z)) + _e78);
    let _e83 = sigmoid(s.raw_opacity);
    if (_e83 < 0.003921569f) {
        return;
    }
    let _e89 = compute_bbox_extent(_e62, log((255f * _e83)));
    if ((_e89.x < 0f) || (_e89.y < 0f)) {
        return;
    }
    // Phase 6.4f.4.b — runtime LOD cull on projected extent.
    let lod_min = uniforms.lod_extent_min;
    if ((lod_min > 0f) && (max(_e89.x, _e89.y) < lod_min)) {
        return;
    }
    let _e108 = uniforms.img_size.x;
    let _e124 = uniforms.img_size.y;
    if (((((mean2d.x + _e89.x) <= 0f) || ((mean2d.x - _e89.x) >= f32(_e108))) || ((mean2d.y + _e89.y) <= 0f)) || ((mean2d.y - _e89.y) >= f32(_e124))) {
        return;
    }
    let _e131 = atomicAdd((&uniforms.num_visible), 1u);
    global_from_compact_gid[_e131] = global_gid;
    depths[_e131] = mean_c_2.z;
    return;
}
