// ghost_mask_parity.cc — parity harness for aether_ghost_mask.h (①).
//
// Loads a device sparse PLY (binary_little_endian, float x/y/z + uchar rgb —
// the exact file the app delivers), runs aether_ghost::ComputeGhostMask over
// the float32 coordinates widened to float64 (identical to the Python
// reference load_ply_xyz), and writes the per-point flag bytes to a file.
// Gate: `cmp` against ghost_l1/gen_ref_flags.py output must be IDENTICAL.
//
// Build (standalone, no deps):
//   clang++ -std=c++17 -O2 -ffp-contract=off -o ghost_mask_parity \
//       ghost_mask_parity.cc
// Run: ghost_mask_parity <sfm_sparse.ply> <out_flags.bin>

#include <cinttypes>
#include <cstdint>
#include <cstdio>
#include <cstring>
#include <fstream>
#include <sstream>
#include <string>
#include <vector>

#include "aether_ghost_mask.h"

namespace {

struct Prop {
  std::string type;
  std::string name;
};

int TypeSize(const std::string& t) {
  if (t == "float") return 4;
  if (t == "double") return 8;
  if (t == "uchar") return 1;
  if (t == "int" || t == "uint") return 4;
  return -1;
}

// Minimal reader for the device PLY format (mirrors ghost_lib.load_ply_xyz).
bool LoadPlyXyz(const char* path, std::vector<double>* out, size_t* n_out) {
  std::ifstream f(path, std::ios::binary);
  if (!f) return false;
  std::string line;
  size_t n = 0;
  std::vector<Prop> props;
  bool binary_le = false;
  while (std::getline(f, line)) {
    if (!line.empty() && line.back() == '\r') line.pop_back();
    std::istringstream ss(line);
    std::string tok;
    ss >> tok;
    if (tok == "format") {
      std::string fmt;
      ss >> fmt;
      binary_le = fmt == "binary_little_endian";
    } else if (tok == "element") {
      std::string what;
      ss >> what >> n;
      if (what != "vertex") return false;  // device PLY has vertices only
    } else if (tok == "property") {
      Prop p;
      ss >> p.type >> p.name;
      props.push_back(p);
    } else if (tok == "end_header") {
      break;
    }
  }
  if (!binary_le || n == 0) return false;
  int stride = 0, xoff = -1, yoff = -1, zoff = -1;
  std::string xtype;
  for (const Prop& p : props) {
    const int sz = TypeSize(p.type);
    if (sz < 0) return false;
    if (p.name == "x") {
      xoff = stride;
      xtype = p.type;
    } else if (p.name == "y") {
      yoff = stride;
    } else if (p.name == "z") {
      zoff = stride;
    }
    stride += sz;
  }
  if (xoff < 0 || yoff < 0 || zoff < 0) return false;
  std::vector<char> buf(n * static_cast<size_t>(stride));
  f.read(buf.data(), static_cast<std::streamsize>(buf.size()));
  if (static_cast<size_t>(f.gcount()) != buf.size()) return false;
  out->resize(n * 3);
  for (size_t i = 0; i < n; ++i) {
    const char* rec = buf.data() + i * static_cast<size_t>(stride);
    if (xtype == "float") {
      float x, y, z;
      std::memcpy(&x, rec + xoff, 4);
      std::memcpy(&y, rec + yoff, 4);
      std::memcpy(&z, rec + zoff, 4);
      (*out)[i * 3 + 0] = static_cast<double>(x);
      (*out)[i * 3 + 1] = static_cast<double>(y);
      (*out)[i * 3 + 2] = static_cast<double>(z);
    } else {  // double
      double x, y, z;
      std::memcpy(&x, rec + xoff, 8);
      std::memcpy(&y, rec + yoff, 8);
      std::memcpy(&z, rec + zoff, 8);
      (*out)[i * 3 + 0] = x;
      (*out)[i * 3 + 1] = y;
      (*out)[i * 3 + 2] = z;
    }
  }
  *n_out = n;
  return true;
}

}  // namespace

int main(int argc, char** argv) {
  if (argc < 3) {
    std::fprintf(stderr, "usage: %s <sfm_sparse.ply> <out_flags.bin>\n",
                 argv[0]);
    return 2;
  }
  std::vector<double> xyz;
  size_t n = 0;
  if (!LoadPlyXyz(argv[1], &xyz, &n)) {
    std::fprintf(stderr, "FAIL: cannot load %s\n", argv[1]);
    return 1;
  }
  std::vector<uint8_t> flags;
  aether_ghost::GhostMaskStats st;
  if (!aether_ghost::ComputeGhostMask(xyz.data(), n, &flags, &st)) {
    std::fprintf(stderr, "FAIL: ComputeGhostMask returned false\n");
    return 1;
  }
  std::ofstream of(argv[2], std::ios::binary);
  of.write(reinterpret_cast<const char*>(flags.data()),
           static_cast<std::streamsize>(flags.size()));
  of.close();
  std::printf(
      "{\"n\":%" PRId64 ",\"n_region\":%" PRId64 ",\"n_band15\":%" PRId64
      ",\"n_band10\":%" PRId64 ",\"n_cell_ghost\":%" PRId64
      ",\"n_clean\":%" PRId64 ",\"n_bim_cells\":%" PRId64
      ",\"n_floor_cells\":%" PRId64
      ",\"plane_n\":[%.17g,%.17g,%.17g],\"plane_d\":%.17g}\n",
      st.n_points, st.n_region, st.n_band15, st.n_band10, st.n_cell_ghost,
      st.n_clean, st.n_bim_cells, st.n_floor_cells, st.plane_n[0],
      st.plane_n[1], st.plane_n[2], st.plane_d);
  return 0;
}
