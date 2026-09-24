// PNG reading for the parity judge (stb_image, third_party/stb, v2.30). Kept in
// its own translation unit: stb is third-party C and is compiled without the
// project's strict warning set (see CMakeLists.txt).
#pragma once

#include <cstdint>
#include <string>
#include <vector>

namespace pwlod_png {

// Decodes `path` to tightly packed RGBA8 (w * h * 4). False if unreadable.
bool ReadRgba(const std::string& path, std::vector<uint8_t>* px, int* w, int* h);

}  // namespace pwlod_png
