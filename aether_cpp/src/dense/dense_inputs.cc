// dense_inputs.cc — see dense_inputs.h.
#include "dense_inputs.h"
#include <cmath>
#include <cstring>

namespace aether::dense {

void build_frame_inputs(const float* cams, const std::vector<int32_t>& views, FrameInputs& out) {
    const int nv = (int)views.size();
    out.n_view = nv;
    std::vector<float> base((size_t)nv * 32, 0.f);
    for (int v = 0; v < nv; ++v) {
        const float* c = cams + (size_t)views[v] * 36;
        float* b = &base[(size_t)v * 32];
        // base[:,0] = [[R | t], [0 0 0 1]]
        for (int r = 0; r < 3; ++r) { for (int k = 0; k < 3; ++k) b[r * 4 + k] = c[9 + r * 3 + k]; b[r * 4 + 3] = c[18 + r]; }
        b[12] = 0.f; b[13] = 0.f; b[14] = 0.f; b[15] = 1.f;
        // base[:,1,:3,:3] = K
        for (int r = 0; r < 3; ++r) for (int k = 0; k < 3; ++k) b[16 + r * 4 + k] = c[r * 3 + k];
    }
    const float div[3] = {8.0f, 4.0f, 2.0f};
    for (int s = 0; s < 3; ++s) {
        out.pm[s] = base;
        for (int v = 0; v < nv; ++v) {
            float* b = &out.pm[s][(size_t)v * 32];
            for (int i = 16; i < 24; ++i) b[i] = b[i] / div[s];   // mm[:,1,:2,:] = base[:,1,:2,:] / dv_
        }
    }
    // dv = np.linspace(1/float(dmax), 1/float(dmin), 384, dtype=float32): float64 ramp, endpoint pinned
    const float* cr = cams + (size_t)views[0] * 36;
    const double start = 1.0 / (double)cr[25], stop = 1.0 / (double)cr[24];
    const double step = (stop - start) / (double)(DENSE_NUM_DEPTH - 1);
    out.dv.resize(DENSE_NUM_DEPTH);
    for (int i = 0; i < DENSE_NUM_DEPTH; ++i) out.dv[i] = (float)(start + (double)i * step);
    out.dv[DENSE_NUM_DEPTH - 1] = (float)stop;
}

float fp16_to_fp32(uint16_t x) {   // bench_main.cc verbatim
    uint32_t sign = (uint32_t)(x >> 15) << 31;
    uint32_t exp = (x >> 10) & 0x1F, man = x & 0x3FF, bits;
    if (exp == 0)       bits = man ? (sign | ((127 - 15 + 1) << 23) | (man << 13)) : sign;
    else if (exp == 31) bits = sign | 0x7F800000u | (man << 13);
    else                bits = sign | ((exp - 15 + 127) << 23) | (man << 13);
    float fv; std::memcpy(&fv, &bits, 4); return fv;
}

uint16_t fp32_to_fp16(float f) {   // IEEE 754 binary16, round to nearest even (numpy half conversion semantics)
    uint32_t x; std::memcpy(&x, &f, 4);
    const uint32_t sign = (x >> 16) & 0x8000u; int32_t exp = (int32_t)((x >> 23) & 0xFF) - 127 + 15; uint32_t man = x & 0x7FFFFFu;
    if (((x >> 23) & 0xFF) == 0xFF) return (uint16_t)(sign | 0x7C00u | (man ? 0x200u : 0));   // inf / nan
    if (exp >= 31) return (uint16_t)(sign | 0x7C00u);                                             // overflow -> inf
    if (exp <= 0) {                                                                               // subnormal / zero
        if (exp < -10) return (uint16_t)sign;
        man |= 0x800000u; const int shift = 14 - exp;
        uint32_t half = man >> shift; const uint32_t rem = man & ((1u << shift) - 1), halfway = 1u << (shift - 1);
        if (rem > halfway || (rem == halfway && (half & 1))) half++;
        return (uint16_t)(sign | half);
    }
    uint32_t half = (uint32_t)(exp << 10) | (man >> 13); const uint32_t rem = man & 0x1FFFu;
    if (rem > 0x1000u || (rem == 0x1000u && (half & 1))) half++;   // may carry into exponent (correct)
    return (uint16_t)(sign | half);
}

}  // namespace aether::dense
