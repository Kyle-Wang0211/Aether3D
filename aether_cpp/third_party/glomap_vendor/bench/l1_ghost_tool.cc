// l1_ghost_tool.cc — [L1 2026-07-12] Mac end-to-end harness for the ghost-layer
// L1 CasDiffMVS arbitration chain. Runs the EXACT production headers
// (aether_ghost_mask.h + aether_l1_plan.h + aether_l1_arbitrate.h) over the
// cap46/47 device fixtures, so the Mac account scores the same C++ the device
// will run.
//
//   plan <sfm_sparse.ply> <host_input.bin> <out_dir> [budget_ms]
//       ComputeGhostMask over the device PLY -> ghost_mask.bin (byte-identical
//       to the parity-gated pass) + arbitration_plan.{json,bin} +
//       arbitration_points.bin via the budgeted greedy set-cover.
//       host_input.bin (written by the Python prep, LE):
//         u32 magic 'A3LH'(0x484C3341), u32 version=1,
//         u32 n_pts, f64 xyz[3*n_pts]            (track points, device frame)
//         u32 n_frames, then per frame:
//           i32 frame_id, f64 w2c[16], f64 k[4]  (model-res fx,fy,cx,cy)
//           u32 jpeg_len, jpeg bytes (absolute path; 0 = no jpeg)
//           u32 n_obs, i32 obs[n_obs]            (rows into the point array)
//   arbitrate <dir>
//       RunArbitration over <dir> (expects the plan sidecars + the
//       l1_depth_<frameId>.bin maps written by the CoreML harness); rewrites
//       ghost_mask.bin bits 5/6 and prints the stats JSON.
//
// Build: clang++ -std=c++17 -O2 -ffp-contract=off -o l1_ghost_tool \
//        l1_ghost_tool.cc   (or the l1_ghost_tool_exe CMake target)

#include <cinttypes>
#include <cstdint>
#include <cstdio>
#include <cstring>
#include <fstream>
#include <sstream>
#include <string>
#include <vector>

#include "aether_ghost_mask.h"
#include "aether_l1_arbitrate.h"
#include "aether_l1_plan.h"

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

// Minimal reader for the device PLY format (verbatim ghost_mask_parity.cc).
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
      if (what != "vertex") return false;
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
    } else {
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

bool ReadAllFile(const std::string& path, std::vector<uint8_t>* out) {
  FILE* f = std::fopen(path.c_str(), "rb");
  if (!f) return false;
  std::fseek(f, 0, SEEK_END);
  const long sz = std::ftell(f);
  std::fseek(f, 0, SEEK_SET);
  out->resize(static_cast<size_t>(sz));
  const size_t r = std::fread(out->data(), 1, out->size(), f);
  std::fclose(f);
  return r == out->size();
}

template <typename T>
bool Pull(const std::vector<uint8_t>& b, size_t* off, T* out,
          size_t count = 1) {
  const size_t bytes = sizeof(T) * count;
  if (*off + bytes > b.size()) return false;
  std::memcpy(out, b.data() + *off, bytes);
  *off += bytes;
  return true;
}

int RunPlan(int argc, char** argv) {
  if (argc < 5) {
    std::fprintf(stderr,
                 "usage: l1_ghost_tool plan <sfm_sparse.ply> <host_input.bin> "
                 "<out_dir> [budget_ms]\n");
    return 2;
  }
  std::vector<double> cloud;
  size_t n_cloud = 0;
  if (!LoadPlyXyz(argv[2], &cloud, &n_cloud)) {
    std::fprintf(stderr, "FAIL: cannot load %s\n", argv[2]);
    return 1;
  }
  std::vector<uint8_t> flags;
  aether_ghost::GhostMaskStats st;
  aether_ghost::GhostMaskIntermediates inter;
  if (!aether_ghost::ComputeGhostMask(cloud.data(), n_cloud, &flags, &st,
                                      &inter)) {
    std::fprintf(stderr, "FAIL: ComputeGhostMask\n");
    return 1;
  }

  std::vector<uint8_t> hb;
  if (!ReadAllFile(argv[3], &hb)) {
    std::fprintf(stderr, "FAIL: cannot read %s\n", argv[3]);
    return 1;
  }
  size_t off = 0;
  uint32_t magic = 0, ver = 0, n_pts = 0, n_frames = 0;
  if (!Pull(hb, &off, &magic) || magic != 0x484C3341u ||
      !Pull(hb, &off, &ver) || ver != 1u || !Pull(hb, &off, &n_pts)) {
    std::fprintf(stderr, "FAIL: host_input header\n");
    return 1;
  }
  std::vector<double> pts(static_cast<size_t>(n_pts) * 3);
  if (!Pull(hb, &off, pts.data(), pts.size()) || !Pull(hb, &off, &n_frames)) {
    std::fprintf(stderr, "FAIL: host_input points\n");
    return 1;
  }
  std::vector<aether_l1::L1Frame> frames(n_frames);
  for (uint32_t f = 0; f < n_frames; ++f) {
    aether_l1::L1Frame& fr = frames[f];
    uint32_t jlen = 0, n_obs = 0;
    if (!Pull(hb, &off, &fr.frame_id) || !Pull(hb, &off, fr.w2c, 16) ||
        !Pull(hb, &off, fr.k, 4) || !Pull(hb, &off, &jlen)) {
      std::fprintf(stderr, "FAIL: host_input frame %u\n", f);
      return 1;
    }
    if (jlen > 0) {
      fr.jpeg.resize(jlen);
      if (!Pull(hb, &off, fr.jpeg.data(), jlen)) return 1;
    }
    if (!Pull(hb, &off, &n_obs)) return 1;
    fr.obs.resize(n_obs);
    if (n_obs > 0 && !Pull(hb, &off, fr.obs.data(), n_obs)) return 1;
  }

  int budget_ms = aether_l1::kDefaultBudgetMs;
  if (argc > 5) budget_ms = std::atoi(argv[5]);
  aether_l1::L1Plan plan;
  if (!aether_l1::BuildL1Plan(cloud.data(), flags.data(), n_cloud, st.plane_n,
                              st.plane_d, pts.data(), n_pts, frames, budget_ms,
                              &plan)) {
    std::fprintf(stderr, "FAIL: BuildL1Plan\n");
    return 1;
  }
  const std::string out_dir = argv[4];
  {
    std::ofstream mf(out_dir + "/ghost_mask.bin", std::ios::binary);
    mf.write(reinterpret_cast<const char*>(flags.data()),
             static_cast<std::streamsize>(flags.size()));
  }
  const bool ok =
      aether_l1::WriteL1PlanJson(out_dir + "/arbitration_plan.json", plan,
                                 frames) &&
      aether_l1::WriteL1PlanBin(out_dir + "/arbitration_plan.bin", plan,
                                frames) &&
      aether_l1::WriteL1PointsSidecar(out_dir + "/arbitration_points.bin",
                                      cloud.data(), flags.data(), n_cloud,
                                      inter.sd, inter.local_off);
  std::printf(
      "{\"n_cloud\":%zu,\"n_band15\":%" PRId64
      ",\"n_marked_cells\":%d,\"budget_refs\":%d,\"refs\":%zu,"
      "\"cov2\":%d,\"cov1\":%d,\"cov0\":%d,\"dropped_srcs\":%d,"
      "\"write_ok\":%d}\n",
      n_cloud, st.n_band15, plan.n_marked_cells, plan.budget_refs,
      plan.refs.size(), plan.n_cells_cov2, plan.n_cells_cov1,
      plan.n_cells_cov0, plan.n_refs_dropped_srcs, ok ? 1 : 0);
  return ok ? 0 : 1;
}

int RunArbitrateMode(int argc, char** argv) {
  if (argc < 3) {
    std::fprintf(stderr, "usage: l1_ghost_tool arbitrate <dir>\n");
    return 2;
  }
  aether_l1::ArbStats st;
  std::string err;
  if (!aether_l1::RunArbitration(argv[2], &st, &err)) {
    std::fprintf(stderr, "FAIL: %s\n", err.c_str());
    return 1;
  }
  // the full stats JSON is in <dir>/ghost_arbitration.json; echo it
  std::vector<uint8_t> j;
  if (ReadAllFile(std::string(argv[2]) + "/ghost_arbitration.json", &j))
    std::fwrite(j.data(), 1, j.size(), stdout);
  return 0;
}

}  // namespace

int main(int argc, char** argv) {
  if (argc < 2) {
    std::fprintf(stderr, "usage: l1_ghost_tool plan|arbitrate ...\n");
    return 2;
  }
  if (std::strcmp(argv[1], "plan") == 0) return RunPlan(argc, argv);
  if (std::strcmp(argv[1], "arbitrate") == 0)
    return RunArbitrateMode(argc, argv);
  std::fprintf(stderr, "unknown mode %s\n", argv[1]);
  return 2;
}
