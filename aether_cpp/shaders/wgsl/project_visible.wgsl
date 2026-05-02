// Adapted from Brush (https://github.com/ArthurBrussee/brush)
// Original: brush/crates/brush-render/src/shaders/<file>
// Brush version: v0.3.0 (commit 3edecbb2fe79d3e2c87eeab85b15e0b1dd10d486)
// License: Apache-2.0 — see aether_cpp/third_party/brush/LICENSE
// Math source: gSplat reference kernels (3DGS paper, Kerbl et al. 2023)
//
// ┏━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━┓
// ┃ Phase 6.4f.3.a — MANUAL OVERRIDE: packed 16-byte splat format       ┃
// ┃                                                                      ┃
// ┃ Replaces 5 separate splat-data buffers with 1 packed buffer (16     ┃
// ┃ bytes/splat) + a slim non-DC SH buffer (only when degree > 0).      ┃
// ┃ The DC SH coefficient is recovered from packed.rgba.rgb via         ┃
// ┃ sRGB-decode → SH_C0 inversion — saves 12 bytes/splat at degree 0.   ┃
// ┃                                                                      ┃
// ┃ DO NOT re-run scripts/wgsl_preprocess on this file — manual         ┃
// ┃ override below will be clobbered. To regenerate: also re-apply     ┃
// ┃ this packed-format diff to _brush_raw/project_visible.wgsl.        ┃
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
    // Phase 6.4f.4.b — must match project_forward.wgsl layout.
    lod_extent_min: f32,
}

struct ProjectedSplat {
    xy_x: f32,
    xy_y: f32,
    conic_x: f32,
    conic_y: f32,
    conic_z: f32,
    color_r: f32,
    color_g: f32,
    color_b: f32,
    color_a: f32,
}

struct PackedVec3 {
    x: f32,
    y: f32,
    z: f32,
}

struct ShCoeffs {
    b0_c0_: vec3<f32>,
    b1_c0_: vec3<f32>,
    b1_c1_: vec3<f32>,
    b1_c2_: vec3<f32>,
    b2_c0_: vec3<f32>,
    b2_c1_: vec3<f32>,
    b2_c2_: vec3<f32>,
    b2_c3_: vec3<f32>,
    b2_c4_: vec3<f32>,
    b3_c0_: vec3<f32>,
    b3_c1_: vec3<f32>,
    b3_c2_: vec3<f32>,
    b3_c3_: vec3<f32>,
    b3_c4_: vec3<f32>,
    b3_c5_: vec3<f32>,
    b3_c6_: vec3<f32>,
}

const COV_BLUR: f32 = 0.3f;
const SH_C0_: f32 = 0.2820948f;
const INV_SH_C0_: f32 = 3.5449078f;  // 1 / SH_C0
const PI_OVER_2_: f32 = 1.5707963f;

@group(0) @binding(0)
var<storage, read_write> uniforms: RenderUniforms;
@group(0) @binding(1)
var<storage> packed_splats: array<vec4<u32>>;
@group(0) @binding(2)
var<storage> coeffs_non_dc: array<PackedVec3>;
@group(0) @binding(3)
var<storage> global_from_compact_gid: array<u32>;
@group(0) @binding(4)
var<storage, read_write> projected: array<ProjectedSplat>;

// ─── Packed-splat unpack helpers (mirrors project_forward.wgsl) ─────

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

fn unpack_log_scale_byte(b: u32) -> f32 {
    let n = f32(b) / 255.0f;
    let log_val = n * 16.0f - 8.0f;
    return exp(log_val);
}

// sRGB byte → linear float in [0,1].
fn srgb_byte_to_linear(b: u32) -> f32 {
    let s = f32(b) / 255.0f;
    return select(pow((s + 0.055f) / 1.055f, 2.4f),
                  s / 12.92f,
                  s <= 0.04045f);
}

struct UnpackedSplatFull {
    position:    vec3<f32>,
    scale:       vec3<f32>,
    quat:        vec4<f32>,
    raw_opacity: f32,
    sh0_dc:      vec3<f32>,    // SH degree-0 (DC) coefficient already in SH-space
}

fn read_splat_full(idx: u32) -> UnpackedSplatFull {
    let p = packed_splats[idx];
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

    let alpha_lin = clamp(f32(p.x >> 24u) / 255.0f, 1.0e-6f, 1.0f - 1.0e-6f);
    let raw_opacity = log(alpha_lin / (1.0f - alpha_lin));

    // Recover the SH degree-0 coefficient from the packed sRGB-encoded
    // color bytes. The encoder did: linear_RGB → sRGB byte. Decoding to
    // linear and then inverting the kernel's `c = SH_C0 * sh0 + 0.5`
    // gives `sh0 = (linear - 0.5) / SH_C0` — same formula the C++ side
    // applied before packing in the legacy 5-buffer path.
    let lr = srgb_byte_to_linear(p.x & 0xFFu);
    let lg = srgb_byte_to_linear((p.x >> 8u) & 0xFFu);
    let lb = srgb_byte_to_linear((p.x >> 16u) & 0xFFu);
    let sh0_dc = vec3<f32>((lr - 0.5f) * INV_SH_C0_,
                            (lg - 0.5f) * INV_SH_C0_,
                            (lb - 0.5f) * INV_SH_C0_);

    var out: UnpackedSplatFull;
    out.position = position;
    out.scale = scale;
    out.quat = quat;
    out.raw_opacity = raw_opacity;
    out.sh0_dc = sh0_dc;
    return out;
}

// ─── Original Brush math (unchanged) ────────────────────────────────

fn create_projected_splat(xy: vec2<f32>, conic: vec3<f32>, color_1: vec4<f32>) -> ProjectedSplat {
    return ProjectedSplat(xy.x, xy.y, conic.x, conic.y, conic.z, color_1.x, color_1.y, color_1.z, color_1.w);
}

fn sigmoid(x: f32) -> f32 {
    return (1f / (1f + exp(-(x))));
}

fn quat_to_mat(quat: vec4<f32>) -> mat3x3<f32> {
    let w = quat.x;
    let x_1 = quat.y;
    let y = quat.z;
    let z = quat.w;
    let x2_ = (x_1 * x_1);
    let y2_ = (y * y);
    let z2_ = (z * z);
    let xy_1 = (x_1 * y);
    let xz = (x_1 * z);
    let yz = (y * z);
    let wx = (w * x_1);
    let wy = (w * y);
    let wz = (w * z);
    return mat3x3<f32>(vec3<f32>((1f - (2f * (y2_ + z2_))), (2f * (xy_1 + wz)), (2f * (xz - wy))), vec3<f32>((2f * (xy_1 - wz)), (1f - (2f * (x2_ + z2_))), (2f * (yz + wx))), vec3<f32>((2f * (xz + wy)), (2f * (yz - wx)), (1f - (2f * (x2_ + y2_)))));
}

fn scale_to_mat(scale: vec3<f32>) -> mat3x3<f32> {
    return mat3x3<f32>(vec3<f32>(scale.x, 0f, 0f), vec3<f32>(0f, scale.y, 0f), vec3<f32>(0f, 0f, scale.z));
}

fn calc_cov3d(scale_1: vec3<f32>, quat_1: vec4<f32>) -> mat3x3<f32> {
    let _e1 = quat_to_mat(quat_1);
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

fn inverse(m: mat2x2<f32>) -> mat2x2<f32> {
    let det = determinant(m);
    if (det <= 0f) {
        return mat2x2<f32>(vec2(0f), vec2(0f));
    }
    let inv_det = (1f / det);
    return mat2x2<f32>(vec2<f32>((m[1].y * inv_det), (-(m[0].y) * inv_det)), vec2<f32>((-(m[0].y) * inv_det), (m[0].x * inv_det)));
}

fn as_vec(packed: PackedVec3) -> vec3<f32> {
    return vec3<f32>(packed.x, packed.y, packed.z);
}

fn sh_coeffs_to_color(degree: u32, viewdir: vec3<f32>, sh_1: ShCoeffs) -> vec3<f32> {
    var colors: vec3<f32>;

    colors = (SH_C0_ * sh_1.b0_c0_);
    if (degree == 0u) {
        return colors;
    }
    let x_2 = viewdir.x;
    let y_1 = viewdir.y;
    let z_1 = viewdir.z;
    colors = (colors + (0.48860252f * (((-(y_1) * sh_1.b1_c0_) + (z_1 * sh_1.b1_c1_)) - (x_2 * sh_1.b1_c2_))));
    if (degree == 1u) {
        return colors;
    }
    let z2_1 = (z_1 * z_1);
    let fTmp0B = (-1.0925485f * z_1);
    let fC1_ = ((x_2 * x_2) - (y_1 * y_1));
    let fS1_ = ((2f * x_2) * y_1);
    let pSH6_ = ((0.9461747f * z2_1) - 0.31539157f);
    let pSH7_ = (fTmp0B * x_2);
    let pSH5_ = (fTmp0B * y_1);
    let pSH8_ = (0.54627424f * fC1_);
    let pSH4_ = (0.54627424f * fS1_);
    colors = (colors + (((((pSH4_ * sh_1.b2_c0_) + (pSH5_ * sh_1.b2_c1_)) + (pSH6_ * sh_1.b2_c2_)) + (pSH7_ * sh_1.b2_c3_)) + (pSH8_ * sh_1.b2_c4_)));
    if (degree == 2u) {
        return colors;
    }
    let fTmp0C = ((-2.285229f * z2_1) + 0.4570458f);
    let fTmp1B = (1.4453057f * z_1);
    let fC2_ = ((x_2 * fC1_) - (y_1 * fS1_));
    let fS2_ = ((x_2 * fS1_) + (y_1 * fC1_));
    let pSH12_ = (z_1 * ((1.8658817f * z2_1) - 1.119529f));
    let pSH13_ = (fTmp0C * x_2);
    let pSH11_ = (fTmp0C * y_1);
    let pSH14_ = (fTmp1B * fC1_);
    let pSH10_ = (fTmp1B * fS1_);
    let pSH15_ = (-0.5900436f * fC2_);
    let pSH9_ = (-0.5900436f * fS2_);
    colors = (colors + (((((((pSH9_ * sh_1.b3_c0_) + (pSH10_ * sh_1.b3_c1_)) + (pSH11_ * sh_1.b3_c2_)) + (pSH12_ * sh_1.b3_c3_)) + (pSH13_ * sh_1.b3_c4_)) + (pSH14_ * sh_1.b3_c5_)) + (pSH15_ * sh_1.b3_c6_)));
    return colors;
}

fn num_non_dc_coeffs(degree_1: u32) -> u32 {
    // degree 0 → 0, 1 → 3, 2 → 8, 3 → 15
    if (degree_1 == 0u) { return 0u; }
    if (degree_1 == 1u) { return 3u; }
    if (degree_1 == 2u) { return 8u; }
    return 15u;
}

fn read_non_dc_coeff(global_gid: u32, slot: u32) -> vec3<f32> {
    let base = global_gid * num_non_dc_coeffs(uniforms.sh_degree);
    return as_vec(coeffs_non_dc[base + slot]);
}

@compute @workgroup_size(256, 1, 1)
fn main(@builtin(global_invocation_id) gid: vec3<u32>) {
    var sh: ShCoeffs = ShCoeffs();
    var color: vec3<f32>;

    let compact_gid = gid.x;
    let _e5 = atomicLoad((&uniforms.num_visible));
    if (compact_gid >= _e5) {
        return;
    }
    let global_gid = global_from_compact_gid[compact_gid];

    let s = read_splat_full(global_gid);
    let scale_2 = s.scale;
    let quat_2 = normalize(s.quat);
    let _e26 = sigmoid(s.raw_opacity);
    let viewmat_1 = uniforms.viewmat;
    let R_1 = mat3x3<f32>(viewmat_1[0].xyz, viewmat_1[1].xyz, viewmat_1[2].xyz);
    let mean_c_2 = ((R_1 * s.position) + viewmat_1[3].xyz);
    let _e41 = calc_cov3d(scale_2, quat_2);
    let _e44 = uniforms.focal;
    let _e47 = uniforms.img_size;
    let _e50 = uniforms.pixel_center;
    let _e51 = calc_cov2d(_e41, mean_c_2, _e44, _e47, _e50, viewmat_1);
    let _e52 = inverse(_e51);
    let rz_1 = (1f / mean_c_2.z);
    let _e58 = uniforms.focal;
    let _e64 = uniforms.pixel_center;
    let mean2d = (((_e58 * mean_c_2.xy) * rz_1) + _e64);
    let sh_degree = uniforms.sh_degree;

    sh.b0_c0_ = s.sh0_dc;
    if (sh_degree >= 1u) {
        sh.b1_c0_ = read_non_dc_coeff(global_gid, 0u);
        sh.b1_c1_ = read_non_dc_coeff(global_gid, 1u);
        sh.b1_c2_ = read_non_dc_coeff(global_gid, 2u);
        if (sh_degree >= 2u) {
            sh.b2_c0_ = read_non_dc_coeff(global_gid, 3u);
            sh.b2_c1_ = read_non_dc_coeff(global_gid, 4u);
            sh.b2_c2_ = read_non_dc_coeff(global_gid, 5u);
            sh.b2_c3_ = read_non_dc_coeff(global_gid, 6u);
            sh.b2_c4_ = read_non_dc_coeff(global_gid, 7u);
            if (sh_degree >= 3u) {
                sh.b3_c0_ = read_non_dc_coeff(global_gid, 8u);
                sh.b3_c1_ = read_non_dc_coeff(global_gid, 9u);
                sh.b3_c2_ = read_non_dc_coeff(global_gid, 10u);
                sh.b3_c3_ = read_non_dc_coeff(global_gid, 11u);
                sh.b3_c4_ = read_non_dc_coeff(global_gid, 12u);
                sh.b3_c5_ = read_non_dc_coeff(global_gid, 13u);
                sh.b3_c6_ = read_non_dc_coeff(global_gid, 14u);
            }
        }
    }

    let _e134 = uniforms.camera_position;
    let viewdir_1 = normalize((s.position - _e134.xyz));
    let _e139 = sh_coeffs_to_color(sh_degree, viewdir_1, sh);
    color = (_e139 + vec3(0.5f));
    let _e155 = create_projected_splat(mean2d, vec3<f32>(_e52[0].x, _e52[0].y, _e52[1].y), vec4<f32>(color, _e26));
    projected[compact_gid] = _e155;
    return;
}
