// dense_preproc.cc — see header. Verbatim port of the 'o' pipeline pre-proc.
#include "dense_preproc.h"

namespace aether::dense {

std::array<float, 9> scaled_K(const std::array<float, 9>& K_npz) {
    // K[1, :] *= PROC_H / NPZ_H  (row 1 = fy/cy row). float32 throughout.
    std::array<float, 9> K = K_npz;
    const float s = static_cast<float>(PROC_H) / static_cast<float>(NPZ_H);
    K[3] *= s; K[4] *= s; K[5] *= s;   // row index 1 -> elements 3,4,5
    return K;
}

std::array<float, 32> make_proj_stage(const std::array<float, 16>& w2c,
                                      const std::array<float, 9>& K, float scale) {
    // proj shape (2,4,4): [0]=w2c (16 floats), [1]=K padded into 4x4 then rows 0..1 * scale.
    std::array<float, 32> out{};
    for (int i = 0; i < 16; ++i) out[i] = w2c[i];      // proj[0] = w2c
    // proj[1] = zeros(4x4); proj[1][:3,:3] = K; then proj[1][:2,:] *= scale.
    // K row r, col c -> proj[1] index 16 + r*4 + c.
    for (int r = 0; r < 3; ++r)
        for (int c = 0; c < 3; ++c)
            out[16 + r * 4 + c] = K[r * 3 + c];
    // scale the first TWO rows of proj[1] (all 4 columns), matching proj[:,1,:2,:] *= f.
    for (int c = 0; c < 4; ++c) {
        out[16 + 0 * 4 + c] *= scale;
        out[16 + 1 * 4 + c] *= scale;
    }
    return out;
}

std::array<float, NUM_DEPTH> depth_values(float depth_min, float depth_max) {
    // np.linspace(1/depth_max, 1/depth_min, NUM_DEPTH, dtype=float32). numpy computes
    // the ramp in FLOAT64 (start/stop are Python float64; arange*step+start promotes to
    // f64) and casts each element to float32 at the end -> must match in double, not f32.
    // The float inputs are promoted to double first (== Python's float(np.float32(x))).
    const double start = 1.0 / static_cast<double>(depth_max);
    const double stop = 1.0 / static_cast<double>(depth_min);
    const double step = (stop - start) / static_cast<double>(NUM_DEPTH - 1);
    std::array<float, NUM_DEPTH> dv{};
    for (int i = 0; i < NUM_DEPTH; ++i)
        dv[i] = static_cast<float>(start + static_cast<double>(i) * step);
    dv[NUM_DEPTH - 1] = static_cast<float>(stop);   // numpy pins the endpoint
    return dv;
}

}  // namespace aether::dense
