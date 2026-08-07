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
    padding_u0: u32,
    padding_u1: u32,
    padding_u2: u32,
    min_std_u8: f32,
    ncc_min: f32,
    depth_margin: f32,
    inverse_depth_first: f32,
    inverse_depth_step: f32,
    padding0: f32,
    padding1: f32,
    padding2: f32,
    inverse_k0: vec4<f32>,
    inverse_k1: vec4<f32>,
    inverse_k2: vec4<f32>,
};

@group(0) @binding(0) var<storage, read> gray_frames: array<f32>;
@group(0) @binding(1) var<storage, read> source_projections: array<vec4<f32>>;
@group(0) @binding(2) var<uniform> params: Params;

struct PixelOutput {
    best_index: u32,
    interpolated_depth_m: f32,
    best_score: f32,
    second_score: f32,
    views: u32,
    accepted: u32,
};

@group(0) @binding(3) var<storage, read_write> output: array<PixelOutput>;

fn read_constant(image_offset: u32, x: i32, y: i32) -> f32 {
    if (x < 0 || y < 0 ||
        x >= i32(params.image_width) || y >= i32(params.image_height)) {
        return 0.0;
    }
    return gray_frames[image_offset + u32(y) * params.image_width + u32(x)];
}

fn sample_bilinear_constant(image_offset: u32, input_x: f32, input_y: f32) -> f32 {
    let x = round(input_x * 32.0) / 32.0;
    let y = round(input_y * 32.0) / 32.0;
    let x0 = i32(floor(x));
    let y0 = i32(floor(y));
    let x1 = x0 + 1;
    let y1 = y0 + 1;
    let wx = x - f32(x0);
    let wy = y - f32(y0);
    let top = mix(
        read_constant(image_offset, x0, y0),
        read_constant(image_offset, x1, y0), wx);
    let bottom = mix(
        read_constant(image_offset, x0, y1),
        read_constant(image_offset, x1, y1), wx);
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
        params.min_views == 0u || params.min_views > params.source_count) {
        output[gid] = PixelOutput(0u, 0.0, -2.0, -2.0, 0u, 0u);
        return;
    }

    let x = params.tile_origin_x + gid % params.tile_width;
    let y = params.tile_origin_y + gid / params.tile_width;
    let half_patch = i32(params.patch_n / 2u);
    var reference_patch: array<f32, 25>;
    var reference_sum = 0.0;
    var sample_index = 0u;
    for (var dy = -half_patch; dy <= half_patch; dy = dy + 1) {
        for (var dx = -half_patch; dx <= half_patch; dx = dx + 1) {
            let reflected_x = reflect101(i32(x) + dx, i32(params.image_width));
            let reflected_y = reflect101(i32(y) + dy, i32(params.image_height));
            let value = gray_frames[
                u32(reflected_y) * params.image_width + u32(reflected_x)];
            reference_patch[sample_index] = value;
            sample_index = sample_index + 1u;
            reference_sum = reference_sum + value;
        }
    }
    let area = f32(sample_index);
    let reference_mean = reference_sum / area;
    var reference_variance = 0.0;
    for (var index = 0u; index < sample_index; index = index + 1u) {
        let centered = reference_patch[index] - reference_mean;
        reference_variance = reference_variance + centered * centered;
    }
    if (sqrt(reference_variance / area) < params.min_std_u8) {
        output[gid] = PixelOutput(0u, 0.0, -2.0, -2.0, 0u, 0u);
        return;
    }

    var costs: array<f32, 64>;
    var depth_views: array<u32, 64>;
    let center_margin = f32(half_patch + 1);
    for (var depth_index = 0u; depth_index < params.depth_count;
         depth_index = depth_index + 1u) {
        let inverse_depth = params.inverse_depth_first +
            f32(depth_index) * params.inverse_depth_step;
        let depth = 1.0 / inverse_depth;
        var top_scores: array<f32, 8>;
        for (var top_index = 0u; top_index < 8u; top_index = top_index + 1u) {
            top_scores[top_index] = -2.0;
        }
        var valid_count = 0u;
        for (var source = 0u; source < params.source_count; source = source + 1u) {
            let projection_base = source * 3u;
            let center_ray = reference_ray(f32(x), f32(y));
            let center = vec4<f32>(center_ray * depth, 1.0);
            let center_z = dot(source_projections[projection_base + 2u], center);
            if (center_z <= 0.05) {
                continue;
            }
            let center_x = dot(source_projections[projection_base], center) / center_z;
            let center_y = dot(source_projections[projection_base + 1u], center) / center_z;
            if (center_x < center_margin ||
                center_x >= f32(params.image_width) - center_margin ||
                center_y < center_margin ||
                center_y >= f32(params.image_height) - center_margin) {
                continue;
            }

            var source_patch: array<f32, 25>;
            var source_sum = 0.0;
            var patch_index = 0u;
            let source_offset = (source + 1u) * params.image_pixel_count;
            for (var dy = -half_patch; dy <= half_patch; dy = dy + 1) {
                for (var dx = -half_patch; dx <= half_patch; dx = dx + 1) {
                    let reflected_x = reflect101(
                        i32(x) + dx, i32(params.image_width));
                    let reflected_y = reflect101(
                        i32(y) + dy, i32(params.image_height));
                    let ray = reference_ray(f32(reflected_x), f32(reflected_y));
                    let point = vec4<f32>(ray * depth, 1.0);
                    let z = dot(source_projections[projection_base + 2u], point);
                    var denominator = 1.0;
                    if (z > 1.0e-12) {
                        denominator = z;
                    }
                    let projected_x = dot(source_projections[projection_base], point) / denominator;
                    let projected_y = dot(source_projections[projection_base + 1u], point) / denominator;
                    let value = sample_bilinear_constant(
                        source_offset, projected_x, projected_y);
                    source_patch[patch_index] = value;
                    patch_index = patch_index + 1u;
                    source_sum = source_sum + value;
                }
            }
            let source_mean = source_sum / area;
            var source_variance = 0.0;
            var covariance = 0.0;
            for (var index = 0u; index < sample_index; index = index + 1u) {
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
            valid_count = valid_count + 1u;
            // Keep every already-sampled view score in descending order.  The
            // default path still reads only the first min_views entries and is
            // therefore numerically identical to the original top-K mean.
            var stored_count = params.min_views;
            if (params.padding_u2 != 0u) {
                stored_count = min(valid_count, 8u);
            }
            for (var slot = 0u; slot < stored_count; slot = slot + 1u) {
                if (score <= top_scores[slot]) {
                    continue;
                }
                var shift = stored_count - 1u;
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
        var cost = -2.0;
        if (valid_count >= params.min_views) {
            cost = 0.0;
            var first_score = 0u;
            var score_count = params.min_views;
            if (params.padding_u2 == 2u) {
                // Mean of every geometrically valid view: strongest dissent
                // signal, but no occlusion trimming.
                score_count = valid_count;
            } else if (params.padding_u2 == 1u && valid_count >= 5u) {
                // Drop one best and one worst score.  This lets a single
                // occluded view abstain while preventing an arbitrary top-K
                // subset from hiding all remaining counter-evidence.
                first_score = 1u;
                score_count = valid_count - 2u;
            }
            for (var index = 0u; index < score_count; index = index + 1u) {
                cost = cost + top_scores[first_score + index];
            }
            cost = cost / f32(score_count);
        }
        costs[depth_index] = cost;
        var quantized_dissent = 0u;
        if (params.padding_u2 == 3u && valid_count >= params.min_views) {
            var all_view_sum = 0.0;
            for (var index = 0u; index < valid_count; index = index + 1u) {
                all_view_sum = all_view_sum + top_scores[index];
            }
            let all_view_mean = all_view_sum / f32(valid_count);
            let dissent = clamp(cost - all_view_mean, 0.0, 2.0);
            quantized_dissent = u32(round(dissent * (255.0 / 2.0)));
        }
        depth_views[depth_index] =
            (valid_count & 255u) | (quantized_dissent << 8u);
    }

    var best_index = 0u;
    var best_score = costs[0];
    for (var index = 1u; index < params.depth_count; index = index + 1u) {
        if (costs[index] > best_score) {
            best_score = costs[index];
            best_index = index;
        }
    }
    var second_score = -2.0;
    for (var index = 0u; index < params.depth_count; index = index + 1u) {
        let delta = i32(index) - i32(best_index);
        if (abs(delta) <= i32(params.exclusion_radius)) {
            continue;
        }
        second_score = max(second_score, costs[index]);
    }
    let packed_depth_views = depth_views[best_index];
    let views = packed_depth_views & 255u;
    let quantized_dissent = (packed_depth_views >> 8u) & 255u;
    var accepted = 0u;
    if (best_score >= params.ncc_min &&
        best_score - second_score >= params.depth_margin &&
        views >= params.min_views) {
        accepted = 1u;
    }

    // The full sweep has already paid for every NCC sample.  Fit a parabola
    // through the winner and its immediate neighbours in inverse-depth space;
    // this adds no texture reads or second dispatch.  Fail closed to the exact
    // discrete winner at boundaries, invalid neighbours, or unstable curvature.
    var interpolated_index = f32(best_index);
    var peak_min_neighbor_drop = 0.0;
    if (params.padding_u1 != 0u &&
        best_index > 0u && best_index + 1u < params.depth_count) {
        let left_score = costs[best_index - 1u];
        let right_score = costs[best_index + 1u];
        let curvature = left_score - 2.0 * best_score + right_score;
        if (left_score > -1.5 && right_score > -1.5 && curvature < -1.0e-5) {
            peak_min_neighbor_drop = max(
                0.0, min(best_score - left_score, best_score - right_score));
            let offset = clamp(
                0.5 * (left_score - right_score) / curvature, -0.5, 0.5);
            interpolated_index = interpolated_index + offset;
        }
    }
    let interpolated_inverse_depth = params.inverse_depth_first +
        interpolated_index * params.inverse_depth_step;
    let interpolated_depth_m = 1.0 / interpolated_inverse_depth;
    let quantized_peak_drop = u32(clamp(
        round(peak_min_neighbor_drop * 32767.0), 0.0, 65535.0));
    let packed_views = (views & 255u) | (quantized_peak_drop << 8u) |
        (quantized_dissent << 24u);
    output[gid] = PixelOutput(
        best_index, interpolated_depth_m, best_score, second_score,
        packed_views, accepted);
}
