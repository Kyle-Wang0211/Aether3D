// PLY input glue -- the one piece of this library that is not a port. Upstream
// PotreeConverter 2.0 reads only LAS/LAZ through its vendored LASzip (LGPL-2.1
// snapshot, deliberately not used); the product's dense cloud is a PLY.
//
// Accepted: binary_little_endian 1.0, a single `vertex` element with exactly
// float x, float y, float z, uchar red, uchar green, uchar blue (15 B/point).
//
// Choices made here, and why (see DEVIATIONS.md "Input glue"):
//  * bounds = min/max of the float32 coordinates, as doubles. This is what
//    tools/pointcloud_lod/ply2las.py writes into the LAS header the desktop
//    reference was built from.
//  * targetScale = max(extent / 2e9, 1e-9) on every axis, ply2las.py:34. Upstream
//    takes targetScale from the LAS header, so with this value the product path
//    gets exactly the scale/offset the desktop reference got through the bridge.
//  * colour: 8-bit -> 16-bit as v * 257 (0 -> 0, 255 -> 65535), ply2las.py:72-74.
#include <cmath>
#include <cstring>
#include <filesystem>
#include <fstream>
#include <limits>
#include <string>
#include <system_error>
#include <vector>

#include "aether/pointcloud_lod_build/build.h"

namespace aether::pointcloud_lod_build {
namespace {

constexpr int64_t kBytesPerPoint = 15;

class PlySource final : public PointSource {
 public:
  std::string path;
  int64_t dataOffset = 0;
  int64_t count = 0;
  double lo[3] = {0, 0, 0};
  double hi[3] = {0, 0, 0};

  int64_t numPoints() const override { return count; }

  void bounds(double min[3], double max[3]) const override {
    for (int i = 0; i < 3; i++) {
      min[i] = lo[i];
      max[i] = hi[i];
    }
  }

  void targetScale(double scale[3]) const override {
    double ext = std::max(hi[0] - lo[0], std::max(hi[1] - lo[1], hi[2] - lo[2]));
    double s = std::max(ext / 2.0e9, 1e-9);  // ply2las.py:34
    scale[0] = scale[1] = scale[2] = s;
  }

  bool read(int64_t first, int64_t n, double* xyz, uint16_t* rgb, std::string* error) const override {
    if (first < 0 || n < 0 || first + n > count) {
      *error = "read out of range";
      return false;
    }
    std::ifstream f(path, std::ios::binary);
    if (!f) {
      *error = "cannot open " + path;
      return false;
    }
    std::vector<char> raw(size_t(n * kBytesPerPoint));
    f.seekg(std::streamoff(dataOffset + first * kBytesPerPoint));
    if (!f.read(raw.data(), std::streamsize(raw.size()))) {
      *error = "short read from " + path;
      return false;
    }
    for (int64_t i = 0; i < n; i++) {
      const char* p = raw.data() + i * kBytesPerPoint;
      float v[3];
      std::memcpy(v, p, 12);
      xyz[3 * i + 0] = double(v[0]);
      xyz[3 * i + 1] = double(v[1]);
      xyz[3 * i + 2] = double(v[2]);
      for (int c = 0; c < 3; c++) {
        uint8_t u = uint8_t(p[12 + c]);
        rgb[3 * i + c] = uint16_t(u * 257);  // ply2las.py:72-74
      }
    }
    return true;
  }
};

bool readLine(std::ifstream& f, std::string* line, int64_t* consumed) {
  line->clear();
  char c;
  while (f.get(c)) {
    (*consumed)++;
    if (*consumed > 64 * 1024) return false;  // no sane header is this long
    if (c == '\n') return true;
    line->push_back(c);
  }
  return false;
}

}  // namespace

bool openPly(const std::string& path, std::unique_ptr<PointSource>* out, std::string* error) {
  std::ifstream f(path, std::ios::binary);
  if (!f) {
    *error = "cannot open " + path;
    return false;
  }

  int64_t consumed = 0;
  std::string line;
  if (!readLine(f, &line, &consumed) || line != "ply") {
    *error = "not a PLY file (first line is not 'ply')";
    return false;
  }

  bool formatOk = false;
  int64_t vertices = -1;
  int elements = 0;
  std::vector<std::string> props;
  while (true) {
    if (!readLine(f, &line, &consumed)) {
      *error = "PLY header is truncated or has no end_header";
      return false;
    }
    if (!line.empty() && line.back() == '\r') line.pop_back();
    if (line == "end_header") break;
    if (line.rfind("comment", 0) == 0 || line.rfind("obj_info", 0) == 0) continue;
    if (line == "format binary_little_endian 1.0") {
      formatOk = true;
    } else if (line.rfind("format ", 0) == 0) {
      *error = "unsupported PLY format: " + line;
      return false;
    } else if (line.rfind("element ", 0) == 0) {
      elements++;
      const std::string prefix = "element vertex ";
      if (line.rfind(prefix, 0) != 0 || elements != 1) {
        *error = "unsupported PLY element: " + line;
        return false;
      }
      const std::string num = line.substr(prefix.size());
      if (num.empty() || num.size() > 18 || num.find_first_not_of("0123456789") != std::string::npos) {
        *error = "bad vertex count: " + line;
        return false;
      }
      vertices = std::stoll(num);
    } else if (line.rfind("property ", 0) == 0) {
      props.push_back(line);
    } else {
      *error = "unexpected PLY header line: " + line;
      return false;
    }
  }
  const std::vector<std::string> expected = {
      "property float x",        "property float y",          "property float z",
      "property uchar red",      "property uchar green",       "property uchar blue"};
  if (!formatOk) {
    *error = "PLY is not binary_little_endian 1.0";
    return false;
  }
  if (vertices < 0) {
    *error = "PLY has no vertex element";
    return false;
  }
  if (props != expected) {
    *error = "PLY vertex layout is not float x,y,z + uchar red,green,blue";
    return false;
  }
  if (vertices == 0) {
    *error = "PLY has 0 points";
    return false;
  }

  std::error_code ec;
  const auto fileSize = std::filesystem::file_size(path, ec);
  if (ec) {
    *error = "cannot stat " + path;
    return false;
  }
  if (vertices > (std::numeric_limits<int64_t>::max() - consumed) / kBytesPerPoint ||
      int64_t(fileSize) < consumed + vertices * kBytesPerPoint) {
    *error = "PLY is truncated: header promises " + std::to_string(vertices) + " points, file has room for " +
             std::to_string((int64_t(fileSize) - consumed) / kBytesPerPoint);
    return false;
  }

  auto src = std::make_unique<PlySource>();
  src->path = path;
  src->dataOffset = consumed;
  src->count = vertices;

  // One pass for the bounds (upstream reads them from the LAS header); also
  // rejects NaN/Inf, which upstream's int32_t((x - offset) / scale) would turn
  // into undefined behaviour.
  for (int i = 0; i < 3; i++) {
    src->lo[i] = std::numeric_limits<double>::infinity();
    src->hi[i] = -std::numeric_limits<double>::infinity();
  }
  constexpr int64_t kScan = 1 << 20;
  std::vector<char> raw(size_t(std::min(vertices, kScan) * kBytesPerPoint));
  f.seekg(std::streamoff(consumed));
  for (int64_t s = 0; s < vertices; s += kScan) {
    const int64_t n = std::min(kScan, vertices - s);
    if (!f.read(raw.data(), std::streamsize(n * kBytesPerPoint))) {
      *error = "short read while scanning " + path;
      return false;
    }
    for (int64_t i = 0; i < n; i++) {
      float v[3];
      std::memcpy(v, raw.data() + i * kBytesPerPoint, 12);
      for (int a = 0; a < 3; a++) {
        if (!std::isfinite(v[a])) {
          *error = "non-finite coordinate at point " + std::to_string(s + i);
          return false;
        }
        src->lo[a] = std::min(src->lo[a], double(v[a]));
        src->hi[a] = std::max(src->hi[a], double(v[a]));
      }
    }
  }

  *out = std::move(src);
  return true;
}

BuildResult buildFromPly(const std::string& plyPath, const BuildOptions& options) {
  std::unique_ptr<PointSource> src;
  std::string error;
  if (!openPly(plyPath, &src, &error)) {
    BuildResult r;
    r.error = error;
    return r;
  }
  BuildOptions o = options;
  if (o.name.empty()) o.name = std::filesystem::path(plyPath).stem().string();  // main.cpp:195-197
  return build(*src, o);
}

}  // namespace aether::pointcloud_lod_build
