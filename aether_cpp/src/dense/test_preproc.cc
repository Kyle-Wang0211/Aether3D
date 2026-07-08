// Byte-exact parity test: compute the 'o' pre-proc for a fixed input, write float32
// binary. A Python reference computes the same; the bytes must be identical.
#include "dense_preproc.h"
#include <cstdio>
using namespace aether::dense;

int main() {
    // Fixed test input (realistic 896x512 intrinsics + a w2c + depth range).
    std::array<float, 9> K_npz = {  // as if baked at 504-tall (row1 will be scaled)
        712.3f, 0.0f, 447.9f,
        0.0f, 701.6f, 251.4f,
        0.0f, 0.0f, 1.0f};
    std::array<float, 16> w2c = {
        0.9975f, -0.0123f, 0.0701f, -0.1532f,
        0.0140f, 0.9994f, -0.0301f, 0.0442f,
       -0.0698f, 0.0310f, 0.9971f, 0.2087f,
        0.0f, 0.0f, 0.0f, 1.0f};
    float dmin = 0.2168f, dmax = 1.9834f;

    FILE* f = fopen("/tmp/cpp_preproc.bin", "wb");
    // (1) scaled_K
    auto Ks = scaled_K(K_npz);
    fwrite(Ks.data(), sizeof(float), 9, f);
    // (2) make_proj_stage for all 4 stages, using the SCALED K (as the pipeline does)
    for (float s : STAGE_SCALES) {
        auto p = make_proj_stage(w2c, Ks, s);
        fwrite(p.data(), sizeof(float), 32, f);
    }
    // (3) depth_values
    auto dv = depth_values(dmin, dmax);
    fwrite(dv.data(), sizeof(float), NUM_DEPTH, f);
    fclose(f);
    printf("wrote /tmp/cpp_preproc.bin\n");
    return 0;
}
