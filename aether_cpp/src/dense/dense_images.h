// dense_images.h — photo -> model image for the on-device dense runner (Stage 1, input side).
//
// The certified fixture (prep_phone_fixture.py:206-213) does, per photo:
//   Image.open(jpg).convert("RGB").resize((W, H), Image.BILINEAR)      -> RGB 768x576
//   np.asarray(im.convert("L"), np.float32) / 255.0  -> astype(np.float16)  -> images.f16
// Nothing is re-invented here:
//   * JPEG decode = libjpeg-turbo 3.1.3 (the submodule aether_cpp already pins for exactly this reason:
//     CMakeLists.txt:57-63 "bit-identical to the Pillow/libjpeg-turbo research oracle"), defaults
//     (JDCT_ISLOW, fancy upsampling), JCS_RGB — the same calls Pillow's JpegDecode makes.
//   * resize = Pillow 11.3.0 src/libImaging/Resample.c ported VERBATIM (precompute_coeffs,
//     normalize_coeffs_8bpc, ImagingResampleHorizontal/Vertical_8bpc 3-band branches,
//     ImagingResampleInner two-pass order), BILINEAR filter {1-|x|, support 1.0}, PRECISION_BITS 22.
//   * RGB -> L = Pillow Convert.c:44 L24: (R*19595 + G*38470 + B*7471 + 0x8000) >> 16.
//   * /255.0 in float32 (numpy weak scalar), float16 round-to-nearest-even (dense_inputs::fp32_to_fp16).
// Gate: images.f16 of fx_official byte-identical (97 photos), resized RGB byte-identical to Pillow.
#pragma once
#include <cstdint>
#include <string>
#include <vector>

namespace aether::dense {

struct RgbImage {
    int w = 0, h = 0;
    std::vector<uint8_t> rgb;   // h*w*3, row-major
};

// libjpeg-turbo decode of a JPEG file to 8-bit RGB. Returns false on any decoder error.
bool decode_jpeg_rgb_file(const std::string& path, RgbImage& out);
bool decode_jpeg_rgb_mem(const uint8_t* bytes, size_t n, RgbImage& out);

// Pillow Image.resize((W,H), Image.BILINEAR) on an RGB image, box = full image.
void pil_resize_bilinear_rgb(const RgbImage& in, int W, int H, RgbImage& out);

// Pillow Image.convert("L") on RGB (Convert.c rgb2l).
void pil_rgb_to_l(const RgbImage& rgb, std::vector<uint8_t>& gray);

// float32(L)/255.0f -> float16 bits (numpy: np.asarray(L, np.float32)/255.0 -> astype(np.float16)).
void gray_to_f16(const std::vector<uint8_t>& gray, std::vector<uint16_t>& f16);

}  // namespace aether::dense
