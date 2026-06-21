// aether_bitmap_shim.h — definition of colmap's forward-declared FIBITMAP for
// the iOS build. colmap::Bitmap is backed by FreeImage's opaque FIBITMAP; on
// device we replace FreeImage with this trivial pixel container (image decoding
// happens platform-side via CGImage). Keeps colmap::Bitmap's interface — and all
// of feature/sift.cc + VLFeat — UNMODIFIED; only the IO backing changes.
#pragma once
#include <cstdint>
#include <vector>

// Pixels are stored ROW-MAJOR, TOP-DOWN, interleaved by channel (gray: 1 ch).
// The C ABI fills `data` from a platform-decoded buffer; colmap::Bitmap's
// ConvertToRowMajorArray (reimplemented in colmap_ios_stubs.cc) reads it back.
struct FIBITMAP {
  int width = 0;
  int height = 0;
  int channels = 1;
  std::vector<uint8_t> data;
};
