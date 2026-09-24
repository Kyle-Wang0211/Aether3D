// See png_read.h.
#define STB_IMAGE_IMPLEMENTATION
#define STBI_ONLY_PNG
#include "stb_image.h"

#include "png_read.h"

namespace pwlod_png {

bool ReadRgba(const std::string& path, std::vector<uint8_t>* px, int* w, int* h) {
  int n = 0;
  unsigned char* data = stbi_load(path.c_str(), w, h, &n, 4);
  if (!data) return false;
  px->assign(data, data + (size_t)(*w) * (size_t)(*h) * 4);
  stbi_image_free(data);
  return true;
}

}  // namespace pwlod_png
