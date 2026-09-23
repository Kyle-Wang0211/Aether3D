// TEST-ONLY. Not part of the library, never shipped.
//
// A reader for uncompressed LAS 1.2 point format 2, just enough to feed the port
// the exact values the desktop PotreeConverter sees when it reads the same file
// through LASzip:
//   * header min/max and scale, as loadLasHeader (LasLoader.cpp:87-97) reads them
//   * coordinates = scale * X + offset, as laszip_get_coordinates
//     (laszip_dll.cpp:1137-1139) computes them
//   * rgb = the 16-bit values stored in the record
// Also a "virtual LAS" built in memory from a PLY with the rule of
// tools/pointcloud_lod/ply2las.py, so the committed fixture needs no LAS file.
#pragma once

#include <cmath>
#include <cstdint>
#include <cstring>
#include <fstream>
#include <memory>
#include <string>
#include <vector>

#include "aether/pointcloud_lod_build/build.h"

namespace pwlod_test {

using aether::pointcloud_lod_build::PointSource;

class LasSource final : public PointSource {
 public:
  std::string path;
  int64_t dataOffset = 0;
  int64_t recordLength = 0;
  int64_t count = 0;
  double scale[3] = {1, 1, 1};
  double offset[3] = {0, 0, 0};
  double lo[3] = {0, 0, 0};
  double hi[3] = {0, 0, 0};

  static std::unique_ptr<LasSource> open(const std::string& p, std::string* error) {
    std::ifstream f(p, std::ios::binary);
    unsigned char h[227];
    if (!f.read(reinterpret_cast<char*>(h), 227) || std::memcmp(h, "LASF", 4) != 0) {
      *error = "not a LAS file";
      return nullptr;
    }
    auto s = std::make_unique<LasSource>();
    s->path = p;
    uint32_t off32, n32;
    uint16_t rec;
    std::memcpy(&off32, h + 96, 4);
    std::memcpy(&rec, h + 105, 2);
    std::memcpy(&n32, h + 107, 4);
    if (h[104] != 2 || rec < 26) {
      *error = "only LAS point format 2 is supported";
      return nullptr;
    }
    s->dataOffset = off32;
    s->recordLength = rec;
    s->count = n32;
    std::memcpy(s->scale, h + 131, 24);
    std::memcpy(s->offset, h + 155, 24);
    double mm[6];
    std::memcpy(mm, h + 179, 48);  // max_x, min_x, max_y, min_y, max_z, min_z
    s->hi[0] = mm[0]; s->lo[0] = mm[1];
    s->hi[1] = mm[2]; s->lo[1] = mm[3];
    s->hi[2] = mm[4]; s->lo[2] = mm[5];
    return s;
  }

  int64_t numPoints() const override { return count; }
  void bounds(double min[3], double max[3]) const override {
    for (int i = 0; i < 3; i++) { min[i] = lo[i]; max[i] = hi[i]; }
  }
  void targetScale(double s[3]) const override {
    for (int i = 0; i < 3; i++) s[i] = scale[i];
  }
  bool read(int64_t first, int64_t n, double* xyz, uint16_t* rgb, std::string* error) const override {
    std::ifstream f(path, std::ios::binary);
    std::vector<char> raw(size_t(n * recordLength));
    f.seekg(std::streamoff(dataOffset + first * recordLength));
    if (!f.read(raw.data(), std::streamsize(raw.size()))) {
      *error = "short LAS read";
      return false;
    }
    for (int64_t i = 0; i < n; i++) {
      const char* p = raw.data() + i * recordLength;
      int32_t X[3];
      std::memcpy(X, p, 12);
      for (int a = 0; a < 3; a++) xyz[3 * i + a] = scale[a] * X[a] + offset[a];
      std::memcpy(rgb + 3 * i, p + 20, 6);
    }
    return true;
  }
};

// ply2las.py applied in memory: X = rint((double(x) - ctr) / scale), header
// min/max = float32 min/max, scale = max(extent / 2e9, 1e-9), offset = centre.
class VirtualLasFromPly final : public PointSource {
 public:
  int64_t count = 0;
  std::vector<int32_t> X;
  std::vector<uint16_t> RGB;
  double scale = 1, ctr[3] = {0, 0, 0}, lo[3] = {0, 0, 0}, hi[3] = {0, 0, 0};

  static std::unique_ptr<VirtualLasFromPly> open(const std::string& plyPath, std::string* error) {
    std::ifstream f(plyPath, std::ios::binary);
    std::string hdr;
    char c;
    while (hdr.find("end_header\n") == std::string::npos && f.get(c)) hdr.push_back(c);
    auto pos = hdr.find("element vertex ");
    if (pos == std::string::npos) {
      *error = "bad ply";
      return nullptr;
    }
    auto s = std::make_unique<VirtualLasFromPly>();
    s->count = std::atoll(hdr.c_str() + pos + 15);
    std::vector<char> raw(size_t(s->count * 15));
    if (!f.read(raw.data(), std::streamsize(raw.size()))) {
      *error = "short ply";
      return nullptr;
    }
    std::vector<float> v(size_t(3 * s->count));
    for (int64_t i = 0; i < s->count; i++) std::memcpy(&v[size_t(3 * i)], raw.data() + i * 15, 12);
    for (int a = 0; a < 3; a++) {
      float mn = v[size_t(a)], mx = v[size_t(a)];
      for (int64_t i = 0; i < s->count; i++) {
        mn = std::min(mn, v[size_t(3 * i + a)]);
        mx = std::max(mx, v[size_t(3 * i + a)]);
      }
      s->lo[a] = double(mn);
      s->hi[a] = double(mx);
      s->ctr[a] = (s->lo[a] + s->hi[a]) / 2.0;
    }
    double ext = std::max(s->hi[0] - s->lo[0], std::max(s->hi[1] - s->lo[1], s->hi[2] - s->lo[2]));
    s->scale = std::max(ext / 2.0e9, 1e-9);
    s->X.resize(size_t(3 * s->count));
    s->RGB.resize(size_t(3 * s->count));
    for (int64_t i = 0; i < s->count; i++) {
      for (int a = 0; a < 3; a++) {
        s->X[size_t(3 * i + a)] = int32_t(std::nearbyint((double(v[size_t(3 * i + a)]) - s->ctr[a]) / s->scale));
        s->RGB[size_t(3 * i + a)] = uint16_t(uint8_t(raw[size_t(i * 15 + 12 + a)]) * 257);
      }
    }
    return s;
  }

  int64_t numPoints() const override { return count; }
  void bounds(double min[3], double max[3]) const override {
    for (int i = 0; i < 3; i++) { min[i] = lo[i]; max[i] = hi[i]; }
  }
  void targetScale(double s[3]) const override { s[0] = s[1] = s[2] = scale; }
  bool read(int64_t first, int64_t n, double* xyz, uint16_t* rgb, std::string*) const override {
    for (int64_t i = 0; i < n; i++) {
      for (int a = 0; a < 3; a++) {
        xyz[3 * i + a] = scale * X[size_t(3 * (first + i) + a)] + ctr[a];
        rgb[3 * i + a] = RGB[size_t(3 * (first + i) + a)];
      }
    }
    return true;
  }
};

}  // namespace pwlod_test
