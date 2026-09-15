// test_session.cc — gate for dense_session: reads the math-free session pack (frames.f64 NF×14, points.f32 N×3)
// and writes cams.f32 / neighbors.i32 in the fixture layout; the verdict is `cmp` against fx_official.
//   test_session <pack_dir> <out_dir> [--nsrc 9]
#include "dense_session.h"
#include <algorithm>
#include <cstdio>
#include <cstdlib>
#include <string>
#include <vector>
using namespace aether::dense;

static std::vector<double> read_f64(const std::string& p) {
    FILE* f = std::fopen(p.c_str(), "rb"); if (!f) { std::fprintf(stderr, "MISSING %s\n", p.c_str()); std::exit(2); }
    std::vector<double> v; double x; while (std::fread(&x, 8, 1, f) == 1) v.push_back(x); std::fclose(f); return v;
}
static std::vector<float> read_f32(const std::string& p) {
    FILE* f = std::fopen(p.c_str(), "rb"); if (!f) { std::fprintf(stderr, "MISSING %s\n", p.c_str()); std::exit(2); }
    std::vector<float> v; float x; while (std::fread(&x, 4, 1, f) == 1) v.push_back(x); std::fclose(f); return v;
}
int main(int argc, char** argv) {
    if (argc < 3) { std::fprintf(stderr, "usage: test_session <pack_dir> <out_dir> [--nsrc N]\n"); return 1; }
    std::string pack = argv[1], out = argv[2]; SessionParams prm;
    for (int i = 3; i < argc; ++i) { std::string a = argv[i]; if (a == "--nsrc" && i + 1 < argc) prm.nsrc = std::atoi(argv[++i]); }
    auto F = read_f64(pack + "/frames.f64"); auto P = read_f32(pack + "/points.f32");
    if (F.size() % 14) { std::fprintf(stderr, "frames.f64 not NF*14\n"); return 2; }
    std::vector<SessionFrame> fr(F.size() / 14);
    for (size_t i = 0; i < fr.size(); ++i) {
        const double* r = &F[i * 14]; SessionFrame& s = fr[i];
        s.frame_id = r[0]; s.fx = r[1]; s.fy = r[2]; s.cx = r[3]; s.cy = r[4]; s.image_w = r[5]; s.image_h = r[6];
        for (int k = 0; k < 4; ++k) s.q[k] = r[7 + k]; for (int k = 0; k < 3; ++k) s.t[k] = r[11 + k];
    }
    SessionTable T; build_session_table(fr, P, prm, T);
    FILE* fc = std::fopen((out + "/cams.f32").c_str(), "wb"); std::fwrite(T.cams.data(), 4, T.cams.size(), fc); std::fclose(fc);
    FILE* fn = std::fopen((out + "/neighbors.i32").c_str(), "wb"); std::fwrite(T.neighbors.data(), 4, T.neighbors.size(), fn); std::fclose(fn);
    std::vector<double> ma = T.med_angle; std::sort(ma.begin(), ma.end());
    double lo = 0, hi = 0; std::vector<float> l, h;
    for (int i = 0; i < T.NF; ++i) { l.push_back(T.cams[i * 36 + 24]); h.push_back(T.cams[i * 36 + 25]); }
    std::sort(l.begin(), l.end()); std::sort(h.begin(), h.end()); lo = l[l.size() / 2]; hi = h[h.size() / 2];
    std::printf("frames %d points %zu nsrc %d  中位三角化角 %.2f°  深度范围中位 lo=%.2f hi=%.2f\n", T.NF, P.size() / 3, prm.nsrc, ma[ma.size() / 2], lo, hi);
    return 0;
}
