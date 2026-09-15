// dense_images.cc — see dense_images.h. "Resample.c:N" = Pillow 11.3.0 src/libImaging/Resample.c line.
#include "dense_images.h"
#include "dense_inputs.h"   // fp32_to_fp16

#include <csetjmp>
#include <cmath>
#include <cstdio>
#include <cstring>

extern "C" {
#include <jpeglib.h>
}

namespace aether::dense {

// ------------------------------------------------------------------ JPEG (libjpeg-turbo, defaults)
namespace {
struct JpegErr { jpeg_error_mgr mgr; std::jmp_buf jb; };
void jpeg_err_exit(j_common_ptr c) { std::longjmp(reinterpret_cast<JpegErr*>(c->err)->jb, 1); }
void jpeg_no_msg(j_common_ptr) {}
}  // namespace

bool decode_jpeg_rgb_mem(const uint8_t* bytes, size_t n, RgbImage& out) {
    jpeg_decompress_struct d{}; JpegErr err{};
    d.err = jpeg_std_error(&err.mgr); err.mgr.error_exit = jpeg_err_exit; err.mgr.output_message = jpeg_no_msg;
    volatile bool created = false;
    if (setjmp(err.jb) != 0) { if (created) jpeg_destroy_decompress(&d); out = RgbImage{}; return false; }
    jpeg_create_decompress(&d); created = true;
    jpeg_mem_src(&d, bytes, (unsigned long)n);
    if (jpeg_read_header(&d, TRUE) != JPEG_HEADER_OK) { jpeg_destroy_decompress(&d); return false; }
    d.out_color_space = JCS_RGB;           // dct_method / do_fancy_upsampling left at libjpeg defaults (= Pillow)
    if (jpeg_start_decompress(&d) == FALSE || d.output_components != 3) { jpeg_destroy_decompress(&d); return false; }
    out.w = (int)d.output_width; out.h = (int)d.output_height; out.rgb.resize((size_t)out.w * out.h * 3);
    const size_t row_bytes = (size_t)out.w * 3;
    while (d.output_scanline < d.output_height) {
        JSAMPROW row = out.rgb.data() + (size_t)d.output_scanline * row_bytes;
        if (jpeg_read_scanlines(&d, &row, 1) != 1) { jpeg_destroy_decompress(&d); out = RgbImage{}; return false; }
    }
    if (jpeg_finish_decompress(&d) == FALSE) { jpeg_destroy_decompress(&d); out = RgbImage{}; return false; }
    jpeg_destroy_decompress(&d); created = false;
    return true;
}

bool decode_jpeg_rgb_file(const std::string& path, RgbImage& out) {
    FILE* f = std::fopen(path.c_str(), "rb"); if (!f) return false;
    std::fseek(f, 0, SEEK_END); const long n = std::ftell(f); std::fseek(f, 0, SEEK_SET);
    std::vector<uint8_t> buf((size_t)n);
    const bool ok = std::fread(buf.data(), 1, (size_t)n, f) == (size_t)n; std::fclose(f);
    return ok && decode_jpeg_rgb_mem(buf.data(), buf.size(), out);
}

// ------------------------------------------------------------------ Pillow Resample.c (verbatim port)
namespace {
constexpr int PRECISION_BITS = 32 - 8 - 2;                       // Resample.c:92

inline double bilinear_filter(double x) {                        // Resample.c:21-29
    if (x < 0.0) x = -x;
    if (x < 1.0) return 1.0 - x;
    return 0.0;
}
inline uint8_t clip8(int in) {                                   // Resample.c:177 (lookup == clamp to [0,255])
    const int v = in >> PRECISION_BITS;
    return (uint8_t)(v < 0 ? 0 : (v > 255 ? 255 : v));
}

// Resample.c:182-268, filter = BILINEAR (support 1.0)
int precompute_coeffs(int inSize, float in0, float in1, int outSize, std::vector<int>& bounds, std::vector<double>& kk) {
    double support, scale, filterscale, center, ww, ss;
    int xx, x, ksize, xmin, xmax;
    filterscale = scale = (double)(in1 - in0) / outSize;
    if (filterscale < 1.0) filterscale = 1.0;
    support = 1.0 * filterscale;
    ksize = (int)std::ceil(support) * 2 + 1;
    kk.assign((size_t)outSize * ksize, 0.0); bounds.assign((size_t)outSize * 2, 0);
    for (xx = 0; xx < outSize; xx++) {
        center = in0 + (xx + 0.5) * scale;
        ww = 0.0;
        ss = 1.0 / filterscale;
        xmin = (int)(center - support + 0.5); if (xmin < 0) xmin = 0;
        xmax = (int)(center + support + 0.5); if (xmax > inSize) xmax = inSize;
        xmax -= xmin;
        double* k = &kk[(size_t)xx * ksize];
        for (x = 0; x < xmax; x++) { const double w = bilinear_filter((x + xmin - center + 0.5) * ss); k[x] = w; ww += w; }
        for (x = 0; x < xmax; x++) { if (ww != 0.0) k[x] /= ww; }
        for (; x < ksize; x++) k[x] = 0;
        bounds[(size_t)xx * 2 + 0] = xmin; bounds[(size_t)xx * 2 + 1] = xmax;
    }
    return ksize;
}
// Resample.c:270-285 (in place: doubles reinterpreted as INT32 in the same buffer)
void normalize_coeffs_8bpc(int outSize, int ksize, std::vector<double>& prekk, std::vector<int32_t>& kk) {
    kk.resize((size_t)outSize * ksize);
    for (int x = 0; x < outSize * ksize; x++) {
        if (prekk[x] < 0) kk[x] = (int)(-0.5 + prekk[x] * (1 << PRECISION_BITS));
        else              kk[x] = (int)(0.5 + prekk[x] * (1 << PRECISION_BITS));
    }
}
// Resample.c:287-352 3-band branch. in rows [offset, offset+out.h) of `in` are consumed.
void resample_horizontal_8bpc_rgb(RgbImage& out, const RgbImage& in, int offset, int ksize, const std::vector<int>& bounds, std::vector<double>& prekk) {
    std::vector<int32_t> kk; normalize_coeffs_8bpc(out.w, ksize, prekk, kk);
    for (int yy = 0; yy < out.h; yy++) {
        const uint8_t* line = &in.rgb[(size_t)(yy + offset) * in.w * 3];
        for (int xx = 0; xx < out.w; xx++) {
            const int xmin = bounds[(size_t)xx * 2 + 0], xmax = bounds[(size_t)xx * 2 + 1];
            const int32_t* k = &kk[(size_t)xx * ksize];
            int ss0, ss1, ss2; ss0 = ss1 = ss2 = 1 << (PRECISION_BITS - 1);
            for (int x = 0; x < xmax; x++) {
                ss0 += ((uint8_t)line[(x + xmin) * 3 + 0]) * k[x];
                ss1 += ((uint8_t)line[(x + xmin) * 3 + 1]) * k[x];
                ss2 += ((uint8_t)line[(x + xmin) * 3 + 2]) * k[x];
            }
            uint8_t* o = &out.rgb[((size_t)yy * out.w + xx) * 3];
            o[0] = clip8(ss0); o[1] = clip8(ss1); o[2] = clip8(ss2);
        }
    }
}
// Resample.c:380-440 3-band branch
void resample_vertical_8bpc_rgb(RgbImage& out, const RgbImage& in, int ksize, const std::vector<int>& bounds, std::vector<double>& prekk) {
    std::vector<int32_t> kk; normalize_coeffs_8bpc(out.h, ksize, prekk, kk);
    for (int yy = 0; yy < out.h; yy++) {
        const int32_t* k = &kk[(size_t)yy * ksize];
        const int ymin = bounds[(size_t)yy * 2 + 0], ymax = bounds[(size_t)yy * 2 + 1];
        for (int xx = 0; xx < out.w; xx++) {
            int ss0, ss1, ss2; ss0 = ss1 = ss2 = 1 << (PRECISION_BITS - 1);
            for (int y = 0; y < ymax; y++) {
                const uint8_t* p = &in.rgb[((size_t)(y + ymin) * in.w + xx) * 3];
                ss0 += ((uint8_t)p[0]) * k[y]; ss1 += ((uint8_t)p[1]) * k[y]; ss2 += ((uint8_t)p[2]) * k[y];
            }
            uint8_t* o = &out.rgb[((size_t)yy * out.w + xx) * 3];
            o[0] = clip8(ss0); o[1] = clip8(ss1); o[2] = clip8(ss2);
        }
    }
}
}  // namespace

// Resample.c:708-804 ImagingResampleInner with box = (0, 0, in.w, in.h)
void pil_resize_bilinear_rgb(const RgbImage& in, int xsize, int ysize, RgbImage& out) {
    const float box[4] = {0.f, 0.f, (float)in.w, (float)in.h};
    const bool need_horizontal = xsize != in.w || box[0] != 0.f || box[2] != (float)xsize;
    const bool need_vertical = ysize != in.h || box[1] != 0.f || box[3] != (float)ysize;
    std::vector<int> bounds_horiz, bounds_vert; std::vector<double> kk_horiz, kk_vert;
    const int ksize_horiz = precompute_coeffs(in.w, box[0], box[2], xsize, bounds_horiz, kk_horiz);
    const int ksize_vert = precompute_coeffs(in.h, box[1], box[3], ysize, bounds_vert, kk_vert);
    const int ybox_first = bounds_vert[0];
    const int ybox_last = bounds_vert[(size_t)ysize * 2 - 2] + bounds_vert[(size_t)ysize * 2 - 1];
    RgbImage temp; const RgbImage* cur = &in;
    if (need_horizontal) {
        for (int i = 0; i < ysize; i++) bounds_vert[(size_t)i * 2] -= ybox_first;
        temp.w = xsize; temp.h = ybox_last - ybox_first; temp.rgb.resize((size_t)temp.w * temp.h * 3);
        resample_horizontal_8bpc_rgb(temp, in, ybox_first, ksize_horiz, bounds_horiz, kk_horiz);
        cur = &temp;
    }
    if (need_vertical) {
        out.w = cur->w; out.h = ysize; out.rgb.resize((size_t)out.w * out.h * 3);
        resample_vertical_8bpc_rgb(out, *cur, ksize_vert, bounds_vert, kk_vert);
    } else {
        out = *cur;
    }
}

// Convert.c:44,226-231
void pil_rgb_to_l(const RgbImage& rgb, std::vector<uint8_t>& gray) {
    const size_t n = (size_t)rgb.w * rgb.h; gray.resize(n);
    for (size_t i = 0; i < n; ++i) {
        const uint8_t* p = &rgb.rgb[i * 3];
        gray[i] = (uint8_t)(((int)p[0] * 19595 + (int)p[1] * 38470 + (int)p[2] * 7471 + 0x8000) >> 16);
    }
}

void gray_to_f16(const std::vector<uint8_t>& gray, std::vector<uint16_t>& f16) {
    f16.resize(gray.size());
    for (size_t i = 0; i < gray.size(); ++i) f16[i] = fp32_to_fp16((float)gray[i] / 255.0f);
}

}  // namespace aether::dense
