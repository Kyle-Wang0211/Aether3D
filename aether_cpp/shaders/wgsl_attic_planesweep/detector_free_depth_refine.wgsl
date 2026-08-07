struct Params {
    image_width: u32,
    image_height: u32,
    image_pixel_count: u32,
    tile_origin_x: u32,
    tile_origin_y: u32,
    tile_width: u32,
    tile_height: u32,
    tile_pixel_count: u32,
    depth_count: u32,
    source_count: u32,
    patch_n: u32,
    min_views: u32,
    exclusion_radius: u32,
    fine_depth_count: u32,
    padding_u1: u32,
    padding_u2: u32,
    min_std_u8: f32,
    ncc_min: f32,
    depth_margin: f32,
    inverse_depth_first: f32,
    inverse_depth_step: f32,
    coarse_step_span: f32,
    uniqueness_absolute_m: f32,
    uniqueness_relative: f32,
    inverse_k0: vec4<f32>,
    inverse_k1: vec4<f32>,
    inverse_k2: vec4<f32>,
};

struct CoarseInput {
    best_index: u32,
    accepted: u32,
};

struct RefinedOutput {
    depth_m: f32,
    best_score: f32,
    second_score: f32,
    supporting_views: u32,
    accepted: u32,
};

@group(0) @binding(0) var<storage, read> gray_frames: array<f32>;
@group(0) @binding(1) var<storage, read> source_projections: array<vec4<f32>>;
@group(0) @binding(2) var<uniform> params: Params;
@group(0) @binding(3) var<storage, read> coarse_input: array<CoarseInput>;
@group(0) @binding(4) var<storage, read_write> output: array<RefinedOutput>;

fn read_image(image_offset: u32, x: i32, y: i32) -> f32 {
    return gray_frames[image_offset + u32(y) * params.image_width + u32(x)];
}

fn sample_bilinear(image_offset: u32, input_x: f32, input_y: f32) -> f32 {
    let x = round(input_x * 32.0) / 32.0;
    let y = round(input_y * 32.0) / 32.0;
    let x0 = i32(floor(x));
    let y0 = i32(floor(y));
    let x1 = x0 + 1;
    let y1 = y0 + 1;
    let wx = x - f32(x0);
    let wy = y - f32(y0);
    let top = mix(
        read_image(image_offset, x0, y0),
        read_image(image_offset, x1, y0), wx);
    let bottom = mix(
        read_image(image_offset, x0, y1),
        read_image(image_offset, x1, y1), wx);
    return mix(top, bottom, wy);
}

fn reflect101(coordinate: i32, length: i32) -> i32 {
    if (length <= 1) {
        return 0;
    }
    var value = coordinate;
    loop {
        if (value >= 0 && value < length) {
            break;
        }
        if (value < 0) {
            value = -value;
        } else {
            value = 2 * length - value - 2;
        }
    }
    return value;
}

fn reference_ray(x: f32, y: f32) -> vec3<f32> {
    let pixel = vec4<f32>(x, y, 1.0, 0.0);
    return vec3<f32>(
        dot(params.inverse_k0, pixel),
        dot(params.inverse_k1, pixel),
        dot(params.inverse_k2, pixel));
}

@compute @workgroup_size(64)
fn main(@builtin(global_invocation_id) global_id: vec3<u32>) {
    let gid = global_id.x;
    if (gid >= params.tile_pixel_count) {
        return;
    }
    if (params.patch_n == 0u || params.patch_n * params.patch_n > 25u ||
        params.depth_count > 64u || params.source_count > 8u ||
        params.min_views == 0u || params.min_views > params.source_count ||
        params.fine_depth_count < 3u || params.fine_depth_count > 64u ||
        params.fine_depth_count % 2u == 0u) {
        output[gid] = RefinedOutput(0.0, -2.0, -2.0, 0u, 0u);
        return;
    }
    let coarse = coarse_input[gid];
    if (coarse.accepted == 0u || coarse.best_index >= params.depth_count) {
        output[gid] = RefinedOutput(0.0, -2.0, -2.0, 0u, 0u);
        return;
    }

    let x = params.tile_origin_x + gid % params.tile_width;
    let y = params.tile_origin_y + gid / params.tile_width;
    let half_patch = i32(params.patch_n / 2u);
    var reference_patch: array<f32, 25>;
    var reference_sum = 0.0;
    var sample_count = 0u;
    for (var dy = -half_patch; dy <= half_patch; dy = dy + 1) {
        for (var dx = -half_patch; dx <= half_patch; dx = dx + 1) {
            let reflected_x = reflect101(i32(x) + dx, i32(params.image_width));
            let reflected_y = reflect101(i32(y) + dy, i32(params.image_height));
            let value = gray_frames[
                u32(reflected_y) * params.image_width + u32(reflected_x)];
            reference_patch[sample_count] = value;
            reference_sum = reference_sum + value;
            sample_count = sample_count + 1u;
        }
    }
    let area = f32(sample_count);
    let reference_mean = reference_sum / area;
    var reference_variance = 0.0;
    for (var index = 0u; index < sample_count; index = index + 1u) {
        let centered = reference_patch[index] - reference_mean;
        reference_variance = reference_variance + centered * centered;
    }
    if (sqrt(reference_variance / area) < params.min_std_u8) {
        output[gid] = RefinedOutput(0.0, -2.0, -2.0, 0u, 0u);
        return;
    }

    let coarse_inverse_depth = params.inverse_depth_first +
        f32(coarse.best_index) * params.inverse_depth_step;
    let half_fine = params.fine_depth_count / 2u;
    let fine_step = params.inverse_depth_step * params.coarse_step_span /
        f32(half_fine);
    let inverse_depth_last = params.inverse_depth_first +
        f32(params.depth_count - 1u) * params.inverse_depth_step;
    let minimum_inverse_depth = min(params.inverse_depth_first, inverse_depth_last);
    let maximum_inverse_depth = max(params.inverse_depth_first, inverse_depth_last);
    var costs: array<f32, 64>;
    var supporting_views: array<u32, 64>;
    var inverse_depths: array<f32, 64>;

    for (var fine_index = 0u; fine_index < params.fine_depth_count;
         fine_index = fine_index + 1u) {
        let signed_offset = i32(fine_index) - i32(half_fine);
        let inverse_depth = coarse_inverse_depth + f32(signed_offset) * fine_step;
        inverse_depths[fine_index] = inverse_depth;
        costs[fine_index] = -2.0;
        supporting_views[fine_index] = 0u;
        if (inverse_depth < minimum_inverse_depth ||
            inverse_depth > maximum_inverse_depth || inverse_depth <= 0.0) {
            continue;
        }
        let depth = 1.0 / inverse_depth;
        var top_scores: array<f32, 8>;
        for (var slot = 0u; slot < 8u; slot = slot + 1u) {
            top_scores[slot] = -2.0;
        }
        var support_count = 0u;
        for (var source = 0u; source < params.source_count; source = source + 1u) {
            let projection_base = source * 3u;
            let source_offset = (source + 1u) * params.image_pixel_count;
            var source_patch: array<f32, 25>;
            var source_sum = 0.0;
            var patch_index = 0u;
            var patch_valid = true;
            for (var dy = -half_patch; dy <= half_patch; dy = dy + 1) {
                for (var dx = -half_patch; dx <= half_patch; dx = dx + 1) {
                    let reflected_x = reflect101(i32(x) + dx, i32(params.image_width));
                    let reflected_y = reflect101(i32(y) + dy, i32(params.image_height));
                    let ray = reference_ray(f32(reflected_x), f32(reflected_y));
                    let point = vec4<f32>(ray * depth, 1.0);
                    let z = dot(source_projections[projection_base + 2u], point);
                    var value = 0.0;
                    if (z > 0.05) {
                        let projected_x =
                            dot(source_projections[projection_base], point) / z;
                        let projected_y =
                            dot(source_projections[projection_base + 1u], point) / z;
                        let quantized_x = round(projected_x * 32.0) / 32.0;
                        let quantized_y = round(projected_y * 32.0) / 32.0;
                        if (quantized_x >= 0.0 && quantized_y >= 0.0 &&
                            quantized_x < f32(params.image_width - 1u) &&
                            quantized_y < f32(params.image_height - 1u)) {
                            value = sample_bilinear(
                                source_offset, projected_x, projected_y);
                        } else {
                            patch_valid = false;
                        }
                    } else {
                        patch_valid = false;
                    }
                    source_patch[patch_index] = value;
                    source_sum = source_sum + value;
                    patch_index = patch_index + 1u;
                }
            }
            if (!patch_valid) {
                continue;
            }
            let source_mean = source_sum / area;
            var source_variance = 0.0;
            var covariance = 0.0;
            for (var index = 0u; index < sample_count; index = index + 1u) {
                let reference_centered = reference_patch[index] - reference_mean;
                let source_centered = source_patch[index] - source_mean;
                source_variance = source_variance + source_centered * source_centered;
                covariance = covariance + reference_centered * source_centered;
            }
            if (sqrt(source_variance / area) < params.min_std_u8) {
                continue;
            }
            let score = covariance /
                (sqrt(reference_variance * source_variance) + 1.0e-6);
            if (score >= params.ncc_min) {
                support_count = support_count + 1u;
            }
            for (var slot = 0u; slot < params.min_views; slot = slot + 1u) {
                if (score <= top_scores[slot]) {
                    continue;
                }
                var shift = params.min_views - 1u;
                loop {
                    if (shift <= slot) {
                        break;
                    }
                    top_scores[shift] = top_scores[shift - 1u];
                    shift = shift - 1u;
                }
                top_scores[slot] = score;
                break;
            }
        }
        if (support_count >= params.min_views) {
            var cost = 0.0;
            for (var slot = 0u; slot < params.min_views; slot = slot + 1u) {
                cost = cost + top_scores[slot];
            }
            costs[fine_index] = cost / f32(params.min_views);
            supporting_views[fine_index] = support_count;
        }
    }

    var best_index = 0u;
    var best_score = costs[0];
    for (var index = 1u; index < params.fine_depth_count; index = index + 1u) {
        if (costs[index] > best_score) {
            best_score = costs[index];
            best_index = index;
        }
    }
    let best_depth = 1.0 / inverse_depths[best_index];
    let uniqueness_band = max(
        params.uniqueness_absolute_m,
        params.uniqueness_relative * best_depth);
    var second_score = -2.0;
    for (var index = 0u; index < params.fine_depth_count; index = index + 1u) {
        if (costs[index] <= -1.5) {
            continue;
        }
        if (abs(1.0 / inverse_depths[index] - best_depth) <= uniqueness_band) {
            continue;
        }
        second_score = max(second_score, costs[index]);
    }
    let views = supporting_views[best_index];
    var accepted = 0u;
    if (best_score >= params.ncc_min &&
        best_score - second_score >= params.depth_margin &&
        views >= params.min_views) {
        accepted = 1u;
    }
    output[gid] = RefinedOutput(
        best_depth, best_score, second_score, views, accepted);
}
