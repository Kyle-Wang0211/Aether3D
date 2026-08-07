// SPDX-License-Identifier: LicenseRef-Aether3D-Proprietary
// Copyright (c) 2024-2026 Aether3D. All rights reserved.

struct Params {
    point_count: u32,
    patch_n: u32,
    width: u32,
    height: u32,
    patch_radius: f32,
    min_std_u8: f32,
    padding0: f32,
    padding1: f32,
    basis_u: vec4<f32>,
    basis_v: vec4<f32>,
    projection0: vec4<f32>,
    projection1: vec4<f32>,
    projection2: vec4<f32>,
};

@group(0) @binding(0) var<storage, read> packed_rgba8: array<u32>;
@group(0) @binding(1) var<storage, read> points: array<vec4<f32>>;
@group(0) @binding(2) var<uniform> params: Params;
@group(0) @binding(3) var<storage, read_write> normalized: array<f32>;
@group(0) @binding(4) var<storage, read_write> valid: array<u32>;
@group(0) @binding(5) var<storage, read_write> stddev_u8: array<f32>;

fn rgb_u8(pixel: u32) -> vec3<f32> {
    return vec3<f32>(
        f32(pixel & 255u),
        f32((pixel >> 8u) & 255u),
        f32((pixel >> 16u) & 255u));
}

fn sample_bilinear(input_x: f32, input_y: f32) -> vec3<f32> {
    let x0 = u32(floor(input_x));
    let y0 = u32(floor(input_y));
    let x1 = min(x0 + 1u, params.width - 1u);
    let y1 = min(y0 + 1u, params.height - 1u);
    let wx = input_x - f32(x0);
    let wy = input_y - f32(y0);
    let top = mix(
        rgb_u8(packed_rgba8[y0 * params.width + x0]),
        rgb_u8(packed_rgba8[y0 * params.width + x1]), wx);
    let bottom = mix(
        rgb_u8(packed_rgba8[y1 * params.width + x0]),
        rgb_u8(packed_rgba8[y1 * params.width + x1]), wx);
    return mix(top, bottom, wy);
}

@compute @workgroup_size(64)
fn main(@builtin(global_invocation_id) global_id: vec3<u32>) {
    let gid = global_id.x;
    if (gid >= params.point_count) {
        return;
    }
    let sample_count = params.patch_n * params.patch_n;
    let output_base = gid * sample_count;
    if (params.patch_n == 0u || sample_count > 81u ||
        params.width == 0u || params.height == 0u) {
        valid[gid] = 0u;
        stddev_u8[gid] = 0.0;
        return;
    }
    var gray: array<f32, 81>;
    var inside = true;
    var sum = 0.0;
    let center = points[gid];
    var sample_index = 0u;
    for (var u_index = 0u;
         u_index < params.patch_n && inside;
         u_index = u_index + 1u) {
        let u = select(
            -params.patch_radius + 2.0 * params.patch_radius *
                f32(u_index) / f32(params.patch_n - 1u),
            0.0,
            params.patch_n == 1u);
        for (var v_index = 0u;
             v_index < params.patch_n;
             v_index = v_index + 1u) {
            let v = select(
                -params.patch_radius + 2.0 * params.patch_radius *
                    f32(v_index) / f32(params.patch_n - 1u),
                0.0,
                params.patch_n == 1u);
            let world = vec4<f32>(
                center.xyz + params.basis_u.xyz * u + params.basis_v.xyz * v,
                1.0);
            let z = dot(params.projection2, world);
            if (z <= 0.05) {
                inside = false;
                break;
            }
            let x = dot(params.projection0, world) / z;
            let y = dot(params.projection1, world) / z;
            if (x < 0.0 || y < 0.0 ||
                x > f32(params.width - 1u) ||
                y > f32(params.height - 1u)) {
                inside = false;
                break;
            }
            let rgb = sample_bilinear(x, y);
            let value = dot(rgb, vec3<f32>(0.299, 0.587, 0.114));
            gray[sample_index] = value;
            sum = sum + value;
            sample_index = sample_index + 1u;
        }
    }
    if (!inside || sample_index != sample_count) {
        valid[gid] = 0u;
        stddev_u8[gid] = 0.0;
        for (var index = 0u; index < sample_count; index = index + 1u) {
            normalized[output_base + index] = 0.0;
        }
        return;
    }
    let mean = sum / f32(sample_count);
    var sum_squared = 0.0;
    for (var index = 0u; index < sample_count; index = index + 1u) {
        let centered = gray[index] - mean;
        sum_squared = sum_squared + centered * centered;
    }
    let sigma = sqrt(sum_squared / f32(sample_count));
    stddev_u8[gid] = sigma;
    if (sigma < params.min_std_u8) {
        valid[gid] = 0u;
        for (var index = 0u; index < sample_count; index = index + 1u) {
            normalized[output_base + index] = 0.0;
        }
        return;
    }
    valid[gid] = 1u;
    let denominator = sqrt(sum_squared) + 1.0e-9;
    for (var index = 0u; index < sample_count; index = index + 1u) {
        normalized[output_base + index] =
            (gray[index] - mean) / denominator;
    }
}
