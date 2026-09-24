// Host test for the plan-L6 C entries: pwlod_build_from_ply + pwlod_verify_octree.
//
//   test_pointcloud_lod_render_build <fixture dir | .ply> <scratch dir>
//
// A directory means <dir>/source.ply (the committed 25,000-point fixture).
//
//   L6a build: PWLOD_OK, and C1 from the report -- tree points == PLY points and
//       octree.bin == 18 B x tree points (the user's "盘上点数不少")
//   L6b verify the built tree: PWLOD_OK, C2 (0 gap bytes, 0 overlap bytes) and
//       S2 (every leaf selected with the camera in front of it)
//   N1  negative control: a truncated PLY (header intact, point data cut to 1%)
//       must be rejected with PWLOD_ERR_FORMAT
//   N2  negative control: the built tree with ONE byte of hierarchy.bin changed
//       (the low byte of a node's octree.bin offset, minus 1) must fail C2
//   N3  negative control: a missing PLY is PWLOD_ERR_IO, not a crash
#include <cstdio>
#include <cstring>
#include <filesystem>
#include <fstream>
#include <string>
#include <vector>

#include "aether/pointcloud_lod_render/pwlod_viewer.h"
#include "judges.h"

namespace fs = std::filesystem;
using pwlod_judges::Fmt;
using pwlod_judges::Report;

namespace {

std::vector<char> ReadAll(const std::string& p) {
  std::ifstream f(p, std::ios::binary | std::ios::ate);
  if (!f) return {};
  std::vector<char> b((size_t)f.tellg());
  f.seekg(0);
  f.read(b.data(), (std::streamsize)b.size());
  return b;
}

}  // namespace

int main(int argc, char** argv) {
  if (argc < 3) { std::fprintf(stderr, "usage: %s <fixture dir | ply> <scratch dir>\n", argv[0]); return 2; }
  std::error_code ec;
  const std::string ply = fs::is_directory(argv[1], ec) ? std::string(argv[1]) + "/source.ply" : argv[1];
  const std::string scratch = argv[2];
  fs::remove_all(scratch, ec);
  fs::create_directories(scratch, ec);
  const std::string tree = scratch + "/tree", chunks = scratch + "/chunks";
  Report rep;
  char err[512];

  // L6a
  pwlod_build_report br{};
  const pwlod_status bs = pwlod_build_from_ply(ply.c_str(), tree.c_str(), chunks.c_str(), 0, 0, &br,
                                               err, sizeof err);
  std::printf("build: status %d, %llu PLY points -> %llu tree points, %d nodes, octree.bin %llu B, %.0f ms %s\n",
              (int)bs, (unsigned long long)br.ply_points, (unsigned long long)br.tree_points, br.nodes,
              (unsigned long long)br.octree_bin_bytes, br.elapsed_ms, err);
  rep.check("L6a build OK; C1 tree points == PLY points == octree.bin / 18",
            bs == PWLOD_OK && br.ply_points > 0 && br.tree_points == br.ply_points &&
                br.octree_bin_bytes == 18ull * br.tree_points,
            Fmt("%llu == %llu, %llu == 18 x %llu", (unsigned long long)br.tree_points,
                (unsigned long long)br.ply_points, (unsigned long long)br.octree_bin_bytes,
                (unsigned long long)br.tree_points));
  fs::remove_all(chunks, ec);

  // L6b
  pwlod_verify_report vr{};
  const pwlod_status vs = pwlod_verify_octree(tree.c_str(), &vr);
  rep.check("L6b verify OK; C2 no gap / no overlap; S2 every leaf selected",
            vs == PWLOD_OK && vr.byte_gaps == 0 && vr.byte_overlaps == 0 && vr.leaves > 0 &&
                vr.leaves_selected == vr.leaves && vr.tree_points == br.tree_points,
            Fmt("status %d, %d nodes, gaps %lld B, overlaps %lld B, leaves %d / %d", (int)vs, vr.nodes,
                (long long)vr.byte_gaps, (long long)vr.byte_overlaps, vr.leaves_selected, vr.leaves));

  std::printf("\nnegative controls (each must be rejected):\n");
  // N1 truncated PLY: the header, then 1% of the point data
  {
    const std::string cut = scratch + "/truncated.ply";
    std::ifstream in(ply, std::ios::binary);
    std::string header, line;
    while (std::getline(in, line)) {
      header += line + "\n";
      if (line.rfind("end_header", 0) == 0) break;
    }
    const uint64_t dataBytes = 15ull * br.ply_points;
    std::vector<char> data((size_t)(dataBytes / 100));
    in.read(data.data(), (std::streamsize)data.size());
    std::ofstream out(cut, std::ios::binary);
    out.write(header.data(), (std::streamsize)header.size());
    out.write(data.data(), in.gcount());
    out.close();
    pwlod_build_report nb{};
    const pwlod_status s = pwlod_build_from_ply(cut.c_str(), (scratch + "/tree_trunc").c_str(),
                                                (scratch + "/chunks_trunc").c_str(), 0, 0, &nb, err, sizeof err);
    rep.check("N1 truncated PLY rejected as PWLOD_ERR_FORMAT", s == PWLOD_ERR_FORMAT,
              Fmt("status %d: %s", (int)s, err));
    fs::remove(cut, ec);
  }
  // N2 one byte of hierarchy.bin
  {
    const std::string bad = scratch + "/tree_tampered";
    fs::create_directories(bad, ec);
    fs::copy_file(tree + "/metadata.json", bad + "/metadata.json", ec);
    fs::create_hard_link(tree + "/octree.bin", bad + "/octree.bin", ec);   // unchanged; no copy
    if (ec) fs::copy_file(tree + "/octree.bin", bad + "/octree.bin", ec);
    std::vector<char> h = ReadAll(tree + "/hierarchy.bin");
    // 22-byte records (OctreeLoader.js:151-232): type u8, childMask u8, numPoints u32,
    // byteOffset i64 @6, byteSize i64 @14. Take the first non-proxy record with
    // data whose offset's low byte is not 0, and lower that byte by one.
    long at = -1;
    for (size_t r = 0; r + 22 <= h.size(); r += 22) {
      int64_t size = 0;
      std::memcpy(&size, h.data() + r + 14, 8);
      if ((uint8_t)h[r] != 2 && size > 0 && (uint8_t)h[r + 6] != 0) { at = (long)(r + 6); break; }
    }
    if (at < 0) {
      rep.skipped("N2 one hierarchy.bin byte changed -> C2 reports it", "no suitable record");
    } else {
      h[(size_t)at] = (char)((uint8_t)h[(size_t)at] - 1);
      std::ofstream o(bad + "/hierarchy.bin", std::ios::binary);
      o.write(h.data(), (std::streamsize)h.size());
      o.close();
      pwlod_verify_report tr{};
      const pwlod_status s = pwlod_verify_octree(bad.c_str(), &tr);
      rep.check("N2 one hierarchy.bin byte changed -> C2 reports it",
                s == PWLOD_ERR_FORMAT && (tr.byte_gaps > 0 || tr.byte_overlaps > 0),
                Fmt("status %d, byte %ld: gaps %lld B, overlaps %lld B", (int)s, at,
                    (long long)tr.byte_gaps, (long long)tr.byte_overlaps));
    }
  }
  // N3 missing PLY
  {
    const pwlod_status s = pwlod_build_from_ply((scratch + "/nope.ply").c_str(), (scratch + "/t3").c_str(),
                                                nullptr, 0, 0, nullptr, err, sizeof err);
    rep.check("N3 missing PLY -> PWLOD_ERR_IO", s == PWLOD_ERR_IO, Fmt("status %d", (int)s));
  }
  fs::remove_all(scratch, ec);
  return rep.finish();
}
