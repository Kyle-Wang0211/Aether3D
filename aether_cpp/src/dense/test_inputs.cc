// test_inputs.cc — gate for dense_inputs against inputs8.bin (pack_inputs.py output for fx_official frames 0..n-1).
//   test_inputs <fixture_dir> <n_frames> <out.bin>
// Writes, per frame: pm1 pm2 pm3 (n_view*32 f32 each) then dv (384 f32) — the same block order as inputs8.bin
// minus view_idx/noise/ref_depth, which a math-free Python script extracts from inputs8.bin for `cmp`.
// Also self-checks fp32->fp16->fp32 round trips on the fixture's image bank (images.f16).
#include "dense_inputs.h"
#include <cstdio>
#include <cstdlib>
#include <string>
#include <vector>
using namespace aether::dense;

int main(int argc, char** argv) {
    if (argc < 4) { std::fprintf(stderr, "usage: test_inputs <fixture_dir> <n_frames> <out.bin>\n"); return 1; }
    const std::string fx = argv[1]; const int n = std::atoi(argv[2]);
    FILE* fc = std::fopen((fx + "/cams.f32").c_str(), "rb"); FILE* fn = std::fopen((fx + "/neighbors.i32").c_str(), "rb");
    if (!fc || !fn) { std::fprintf(stderr, "MISSING cams/neighbors\n"); return 2; }
    std::vector<float> cams; float x; while (std::fread(&x, 4, 1, fc) == 1) cams.push_back(x); std::fclose(fc);
    std::vector<int32_t> nb; int32_t y; while (std::fread(&y, 4, 1, fn) == 1) nb.push_back(y); std::fclose(fn);
    const int NF = (int)(cams.size() / 36), NS = (int)(nb.size() / NF);
    FILE* fo = std::fopen(argv[3], "wb");
    for (int f = 0; f < n; ++f) {
        std::vector<int32_t> views{f}; for (int j = 0; j < NS; ++j) views.push_back(nb[(size_t)f * NS + j]);
        FrameInputs in; build_frame_inputs(cams.data(), views, in);
        for (int s = 0; s < 3; ++s) std::fwrite(in.pm[s].data(), 4, in.pm[s].size(), fo);
        std::fwrite(in.dv.data(), 4, in.dv.size(), fo);
    }
    std::fclose(fo);
    // fp16 round-trip self-check on images.f16
    FILE* fi = std::fopen((fx + "/images.f16").c_str(), "rb"); size_t bad = 0, tot = 0;
    if (fi) { uint16_t h; while (std::fread(&h, 2, 1, fi) == 1) { tot++; if (fp32_to_fp16(fp16_to_fp32(h)) != h) bad++; if (tot >= 4000000) break; } std::fclose(fi); }
    std::printf("frames %d (NF %d, %d src) -> %s ; fp16 round-trip mismatches %zu / %zu\n", n, NF, NS, argv[3], bad, tot);
    return 0;
}
