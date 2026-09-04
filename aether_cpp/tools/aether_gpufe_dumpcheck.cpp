// Replays a device audit dump (Documents/xrslam_gpufe_dump: prev_clahe.u8, next_clahe.u8, pts.txt) on the Mac:
// Mac CPU (OpenCV 4.0.1 static, NEON) LK vs the device's recorded CPU and GPU results, and the Mac GPU library on the same inputs.
#include "pw_gpu_frontend.h"
#include <opencv2/core.hpp>
#include <opencv2/video.hpp>
#include <cstdio>
#include <fstream>
#include <sstream>
#include <string>
#include <vector>
static std::vector<uint8_t> slurpb(const std::string& p) { std::ifstream f(p, std::ios::binary); std::stringstream s; s << f.rdbuf(); auto str = s.str(); return std::vector<uint8_t>(str.begin(), str.end()); }
struct Row { float cx, cy, dcx, dcy, dgx, dgy, drx, dry, dgrx, dgry; int dcs, dgs, drs, dgrs; };
int main(int argc, char** argv) {
  if (argc < 2) { fprintf(stderr, "usage: dumpcheck <dump_dir>\n"); return 1; }
  std::string d = argv[1]; std::ifstream pf(d + "/pts.txt"); std::string line; int W = 0, H = 0; std::vector<Row> rows;
  while (std::getline(pf, line)) { if (line.empty() || line[0] == '#') continue; std::istringstream is(line); if (!W) { is >> W >> H; continue; } Row r; if (is >> r.cx >> r.cy >> r.dcx >> r.dcy >> r.dcs >> r.dgx >> r.dgy >> r.dgs >> r.drx >> r.dry >> r.drs >> r.dgrx >> r.dgry >> r.dgrs) rows.push_back(r); }
  auto pa8 = slurpb(d + "/prev_clahe.u8"), pb8 = slurpb(d + "/next_clahe.u8"); if ((int)pa8.size() != W * H || (int)pb8.size() != W * H) { fprintf(stderr, "image size mismatch (%zu vs %d)\n", pa8.size(), W * H); return 2; }
  cv::Mat A(H, W, CV_8UC1, pa8.data()), B(H, W, CV_8UC1, pb8.data());
  std::vector<cv::Mat> pa, pb; cv::buildOpticalFlowPyramid(A, pa, cv::Size(21, 21), 3, true); cv::buildOpticalFlowPyramid(B, pb, cv::Size(21, 21), 3, true);
  std::vector<cv::Point2f> c(rows.size()), n1; for (size_t i = 0; i < rows.size(); ++i) c[i] = cv::Point2f(rows[i].cx, rows[i].cy); n1 = c;
  std::vector<uchar> s1, s2; std::vector<float> e1, e2; cv::TermCriteria tc(cv::TermCriteria::COUNT + cv::TermCriteria::EPS, 30, 0.01);
  cv::calcOpticalFlowPyrLK(pa, pb, c, n1, s1, e1, cv::Size(21, 21), 3, tc, cv::OPTFLOW_USE_INITIAL_FLOW);
  std::vector<cv::Point2f> r1 = c; cv::calcOpticalFlowPyrLK(pb, pa, n1, r1, s2, e2, cv::Size(21, 21), 3, tc, cv::OPTFLOW_USE_INITIAL_FLOW);
  size_t mac_vs_devcpu = 0, mac_vs_devgpu = 0, devcpu_vs_devgpu = 0; double md1 = 0, md2 = 0;
  for (size_t i = 0; i < rows.size(); ++i) { const Row& r = rows[i];
    bool a = (s1[i] != 0) == (r.dcs != 0) && (!s1[i] || (n1[i].x == r.dcx && n1[i].y == r.dcy)); if (!a) { ++mac_vs_devcpu; md1 = std::max(md1, std::max((double)fabs(n1[i].x - r.dcx), (double)fabs(n1[i].y - r.dcy))); }
    bool b = (s1[i] != 0) == (r.dgs != 0) && (!s1[i] || (n1[i].x == r.dgx && n1[i].y == r.dgy)); if (!b) ++mac_vs_devgpu;
    bool cc = (r.dcs != 0) == (r.dgs != 0) && (!r.dcs || (r.dcx == r.dgx && r.dcy == r.dgy)); if (!cc) { ++devcpu_vs_devgpu; md2 = std::max(md2, std::max((double)fabs(r.dcx - r.dgx), (double)fabs(r.dcy - r.dgy))); } }
  printf("pts=%zu  macCPU!=devCPU: %zu (maxdiff %.3g)  macCPU!=devGPU: %zu  devCPU!=devGPU: %zu (maxdiff %.3g)\n", rows.size(), mac_vs_devcpu, md1, mac_vs_devgpu, devcpu_vs_devgpu, md2);
  std::string err; auto fe = pw::gpufe::FrontEnd::create(&err); if (!fe) { fprintf(stderr, "gpu: %s\n", err.c_str()); return 3; }
  auto FA = fe->preprocess_preclahe(pa8.data(), W, H, W), FB = fe->preprocess_preclahe(pb8.data(), W, H, W); if (!FA || !FB) { fprintf(stderr, "preprocess: %s\n", fe->take_error().c_str()); return 4; }
  std::vector<std::array<float, 2>> p0(rows.size()), g1, gr; for (size_t i = 0; i < rows.size(); ++i) p0[i] = {rows[i].cx, rows[i].cy}; g1 = p0; gr = p0; std::vector<uint8_t> gs, gsr;
  if (!fe->track_fwd_rev(*FA, *FB, p0, g1, gs, gr, gsr)) { fprintf(stderr, "track: %s\n", fe->take_error().c_str()); return 5; }
  size_t macgpu_vs_maccpu = 0, macgpu_vs_devgpu = 0; for (size_t i = 0; i < rows.size(); ++i) { const Row& r = rows[i];
    if (!((gs[i] != 0) == (s1[i] != 0) && (!s1[i] || (g1[i][0] == n1[i].x && g1[i][1] == n1[i].y)))) ++macgpu_vs_maccpu;
    if (!((gs[i] != 0) == (r.dgs != 0) && (!r.dgs || (g1[i][0] == r.dgx && g1[i][1] == r.dgy)))) ++macgpu_vs_devgpu; }
  printf("macGPU!=macCPU: %zu  macGPU!=devGPU: %zu\n", macgpu_vs_maccpu, macgpu_vs_devgpu);
  for (size_t i = 0, shown = 0; i < rows.size() && shown < 3; ++i) { const Row& r = rows[i]; if ((r.dcs && r.dgs) && (r.dcx != r.dgx || r.dcy != r.dgy)) { printf("  ex i=%zu curr=(%.4f,%.4f) devCPU=(%.7g,%.7g) devGPU=(%.7g,%.7g) macCPU=(%.7g,%.7g) macGPU=(%.7g,%.7g)\n", i, r.cx, r.cy, r.dcx, r.dcy, r.dgx, r.dgy, n1[i].x, n1[i].y, g1[i][0], g1[i][1]); ++shown; } }
  return 0;
}
