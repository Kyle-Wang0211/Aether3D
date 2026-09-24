// test_images.cc — gate for dense_images: decode + Pillow-verbatim resize + L + f16 for every photo of a capture,
// writing images_cpp.f16 (NF×H×W u16, fixture layout) and rgb_cpp.u8 (first n_rgb frames, H×W×3) for `cmp`.
//   test_images <photos_dir> <names.txt> <W> <H> <out_dir> [n_rgb]
//
// [2026-09-16 lossless-speedup v1] Second mode — the NV12 positive/negative control for load_frame_rgb:
//   test_images --nv12-roundtrip <matrix> <photos_dir> <names.txt> <W> <H> <out_dir>
// Per photo it runs the JPEG path (decode -> pil_resize) AND the archived-photo path
// (decode -> libyuv RGB->NV12 with <matrix> -> .nv12 file -> load_frame_rgb(Nv12) -> pil_resize) and reports the
// max/mean |diff| of the two W×H RGB images. Positive control = same matrix both ways (expected small: the only
// loss is 8-bit YUV rounding + 4:2:0 chroma subsampling, most of which the downsample averages away).
// Negative control = decode with the OTHER matrix (expected clearly larger).
#include "dense_images.h"

// libyuv (BSD-3, aether_cpp/third_party/libyuv) is used ONLY in this test's encoder, to build the .nv12 fixture.
// It is the exact inverse of the decoder dense_images.cc uses:
//   encode: RAWToARGB            third_party/libyuv/source/convert_argb.cc:3734       (R,G,B -> ARGB = b,g,r,a)
//           ARGBToNV12Matrix     third_party/libyuv/source/convert_from_argb.cc:406   (ARGB -> Y + interleaved UV)
//           with kArgbJPEGConstants (BT.601 full range, row_common.cc:1512-1524 MAKEARGBCONSTANTS(JPEG,...)) or
//                kArgbF709Constants (BT.709 full range, row_common.cc:1540-1552 MAKEARGBCONSTANTS(F709,...)).
//           "kArgb*" is the family for ARGB-little-endian input, i.e. b,g,r,a in memory — convert_from_argb.h:23-26.
//   decode: NV21ToRGB24Matrix + kYvu{JPEG,F709}Constants == libyuv's own NV12ToRAWMatrix macro
//           (convert_argb.h:57-58); see dense_images.cc.
#include "libyuv/convert_argb.h"
#include "libyuv/convert_from_argb.h"
#include "libyuv/cpu_id.h"

#include <cmath>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <fstream>
#include <string>
#include <vector>
using namespace aether::dense;

namespace {

std::vector<std::string> read_names(const char* path) {
    std::vector<std::string> names; std::ifstream f(path); std::string l;
    while (std::getline(f, l)) if (!l.empty()) names.push_back(l);
    return names;
}

int run_default(const std::string& photos, const char* names_path, int W, int H, const std::string& out, int n_rgb) {
    std::vector<std::string> names = read_names(names_path);
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

// ---------------------------------------------------------------- NV12 round-trip control
// RGB (R,G,B) -> FULL-RANGE NV12 planes with libyuv, `matrix` as in FrameSource::nv12_matrix.
bool rgb_to_nv12(const RgbImage& in, int matrix, std::vector<uint8_t>& nv12) {
    if (in.w <= 0 || in.h <= 0 || (in.w & 1) || (in.h & 1)) return false;
    std::vector<uint8_t> argb((size_t)in.w * in.h * 4);
    if (libyuv::RAWToARGB(in.rgb.data(), in.w * 3, argb.data(), in.w * 4, in.w, in.h) != 0) return false;
    const struct libyuv::ArgbConstants* k = matrix == 1 ? &libyuv::kArgbF709Constants : &libyuv::kArgbJPEGConstants;
    const size_t y_bytes = (size_t)in.w * in.h;
    nv12.assign(y_bytes + (size_t)(in.h / 2) * in.w, 0);
    return libyuv::ARGBToNV12Matrix(argb.data(), in.w * 4, nv12.data(), in.w, nv12.data() + y_bytes, in.w,
                                    k, in.w, in.h) == 0;
}

struct Diff { double mean = 0; int max = 0; };
Diff diff_rgb(const RgbImage& a, const RgbImage& b) {
    Diff d;
    if (a.w != b.w || a.h != b.h || a.rgb.size() != b.rgb.size()) { d.max = -1; return d; }
    double sum = 0;
    for (size_t i = 0; i < a.rgb.size(); ++i) { const int e = std::abs((int)a.rgb[i] - (int)b.rgb[i]); sum += e; if (e > d.max) d.max = e; }
    d.mean = a.rgb.empty() ? 0.0 : sum / (double)a.rgb.size();
    return d;
}

int run_nv12_roundtrip(int matrix, const std::string& photos, const char* names_path, int W, int H, const std::string& out) {
    if (matrix != 0 && matrix != 1) { std::fprintf(stderr, "matrix must be 0 (BT.601 full) or 1 (BT.709 full)\n"); return 1; }
    libyuv::InitCpuFlags();
    std::vector<std::string> names = read_names(names_path);
    const int other = 1 - matrix;
    size_t n_sep = 0;
    double worst_pos_mean = 0; int worst_pos_max = 0; double best_neg_mean = 1e9; int best_neg_max = 1 << 30;
    std::printf("nv12 roundtrip: encode matrix=%d, %zu photos, model %dx%d\n", matrix, names.size(), W, H);
    std::printf("  pos = same matrix (positive control), neg = matrix %d (negative control)\n", other);
    std::printf("  full = at capture resolution, model = after the %dx%d Pillow resize (what the net sees)\n", W, H);
    std::printf("%-26s %9s %8s %9s %8s | %9s %8s %9s %8s\n", "photo",
                "pos_mean", "pos_max", "neg_mean", "neg_max", "posF_mean", "posF_max", "negF_mean", "negF_max");
    for (size_t i = 0; i < names.size(); ++i) {
        RgbImage src, ref;
        if (!decode_jpeg_rgb_file(photos + "/" + names[i], src)) { std::fprintf(stderr, "decode failed: %s\n", names[i].c_str()); return 3; }
        pil_resize_bilinear_rgb(src, W, H, ref);                       // A: the JPEG path, unchanged

        std::vector<uint8_t> nv12;
        if (!rgb_to_nv12(src, matrix, nv12)) { std::fprintf(stderr, "nv12 encode failed: %s\n", names[i].c_str()); return 4; }
        const std::string nv12_path = out + "/" + names[i] + ".nv12";
        { FILE* f = std::fopen(nv12_path.c_str(), "wb");
          if (!f) { std::fprintf(stderr, "cannot write %s\n", nv12_path.c_str()); return 2; }
          const bool ok = std::fwrite(nv12.data(), 1, nv12.size(), f) == nv12.size(); std::fclose(f);
          if (!ok) { std::fprintf(stderr, "short write %s\n", nv12_path.c_str()); return 2; } }

        FrameSource fs; fs.kind = FrameSourceKind::Nv12; fs.path = nv12_path; fs.width = src.w; fs.height = src.h;
        RgbImage pos_full, neg_full, pos, neg; std::string err;
        fs.nv12_matrix = matrix;
        if (!load_frame_rgb(fs, pos_full, &err)) { std::fprintf(stderr, "load_frame_rgb(pos) failed: %s\n", err.c_str()); return 5; }
        fs.nv12_matrix = other;                                        // NEGATIVE control: the wrong matrix
        if (!load_frame_rgb(fs, neg_full, &err)) { std::fprintf(stderr, "load_frame_rgb(neg) failed: %s\n", err.c_str()); return 5; }
        const Diff dpf = diff_rgb(src, pos_full), dnf = diff_rgb(src, neg_full);   // at capture resolution
        pil_resize_bilinear_rgb(pos_full, W, H, pos);
        pil_resize_bilinear_rgb(neg_full, W, H, neg);

        const Diff dp = diff_rgb(ref, pos), dn = diff_rgb(ref, neg);
        if (dp.mean > worst_pos_mean) worst_pos_mean = dp.mean;
        if (dp.max > worst_pos_max) worst_pos_max = dp.max;
        if (dn.mean < best_neg_mean) best_neg_mean = dn.mean;
        if (dn.max < best_neg_max) best_neg_max = dn.max;
        // per-photo separation: the wrong matrix must be worse on BOTH statistics, and clearly so on max.
        if (dn.mean > dp.mean && dn.max >= 2 * dp.max) ++n_sep;
        std::printf("%-26s %9.4f %8d %9.4f %8d | %9.4f %8d %9.4f %8d\n", names[i].c_str(),
                    dp.mean, dp.max, dn.mean, dn.max, dpf.mean, dpf.max, dnf.mean, dnf.max);
        std::fflush(stdout);
    }
    std::printf("\nPOSITIVE control (same matrix): worst mean %.4f, worst max %d\n", worst_pos_mean, worst_pos_max);
    std::printf("NEGATIVE control (matrix %d):  best  mean %.4f, best  max %d\n", other, best_neg_mean, best_neg_max);
    std::printf("separation (neg worse on mean AND >=2x on max): %zu/%zu photos -> %s\n",
                n_sep, names.size(), n_sep == names.size() ? "OK" : "WEAK - inspect");
    return n_sep == names.size() ? 0 : 6;
}

}  // namespace

int main(int argc, char** argv) {
    if (argc > 1 && std::strcmp(argv[1], "--nv12-roundtrip") == 0) {
        if (argc < 8) { std::fprintf(stderr, "usage: test_images --nv12-roundtrip <matrix> <photos_dir> <names.txt> <W> <H> <out_dir>\n"); return 1; }
        return run_nv12_roundtrip(std::atoi(argv[2]), argv[3], argv[4], std::atoi(argv[5]), std::atoi(argv[6]), argv[7]);
    }
    if (argc < 6) { std::fprintf(stderr, "usage: test_images <photos_dir> <names.txt> <W> <H> <out_dir> [n_rgb]\n"); return 1; }
    return run_default(argv[1], argv[2], std::atoi(argv[3]), std::atoi(argv[4]), argv[5], argc > 6 ? std::atoi(argv[6]) : 8);
}
