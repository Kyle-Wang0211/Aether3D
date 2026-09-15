// test_images.cc — gate for dense_images: decode + Pillow-verbatim resize + L + f16 for every photo of a capture,
// writing images_cpp.f16 (NF×H×W u16, fixture layout) and rgb_cpp.u8 (first n_rgb frames, H×W×3) for `cmp`.
//   test_images <photos_dir> <names.txt> <W> <H> <out_dir> [n_rgb]
#include "dense_images.h"
#include <cstdio>
#include <cstdlib>
#include <fstream>
#include <string>
#include <vector>
using namespace aether::dense;

int main(int argc, char** argv) {
    if (argc < 6) { std::fprintf(stderr, "usage: test_images <photos_dir> <names.txt> <W> <H> <out_dir> [n_rgb]\n"); return 1; }
    const std::string photos = argv[1], out = argv[5]; const int W = std::atoi(argv[3]), H = std::atoi(argv[4]);
    const int n_rgb = argc > 6 ? std::atoi(argv[6]) : 8;
    std::vector<std::string> names; { std::ifstream f(argv[2]); std::string l; while (std::getline(f, l)) if (!l.empty()) names.push_back(l); }
    FILE* ff = std::fopen((out + "/images_cpp.f16").c_str(), "wb"); FILE* fr = std::fopen((out + "/rgb_cpp.u8").c_str(), "wb");
    if (!ff || !fr) { std::fprintf(stderr, "cannot write outputs\n"); return 2; }
    for (size_t i = 0; i < names.size(); ++i) {
        RgbImage src, rs; std::vector<uint8_t> gray; std::vector<uint16_t> f16;
        if (!decode_jpeg_rgb_file(photos + "/" + names[i], src)) { std::fprintf(stderr, "decode failed: %s\n", names[i].c_str()); return 3; }
        pil_resize_bilinear_rgb(src, W, H, rs);
        pil_rgb_to_l(rs, gray); gray_to_f16(gray, f16);
        std::fwrite(f16.data(), 2, f16.size(), ff);
        if ((int)i < n_rgb) std::fwrite(rs.rgb.data(), 1, rs.rgb.size(), fr);
        if (i % 25 == 0) { std::printf("  %zu/%zu %s %dx%d -> %dx%d\n", i, names.size(), names[i].c_str(), src.w, src.h, rs.w, rs.h); std::fflush(stdout); }
    }
    std::fclose(ff); std::fclose(fr);
    std::printf("done %zu photos -> %s\n", names.size(), out.c_str());
    return 0;
}
