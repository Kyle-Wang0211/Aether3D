// test_box.cc — gate for the selection path: (1) BoxFilter.contains vs the app's SelectionBox.contains bits
// (box_ref.dart), (2) the frames that see the box on the fixture session (compared to a numpy expectation).
//   test_box <box_dir> <session_pack_dir> [--nsrc 9]
#include "dense_fuse_pack.h"
#include "dense_session.h"
#include <cstdio>
#include <cstdlib>
#include <string>
#include <vector>
using namespace aether::dense;

template <class T> static std::vector<T> rd(const std::string& p) {
    FILE* f = std::fopen(p.c_str(), "rb"); if (!f) { std::fprintf(stderr, "MISSING %s\n", p.c_str()); std::exit(2); }
    std::vector<T> v; T x; while (std::fread(&x, sizeof(T), 1, f) == 1) v.push_back(x); std::fclose(f); return v;
}
int main(int argc, char** argv) {
    if (argc < 3) { std::fprintf(stderr, "usage: test_box <box_dir> <session_pack_dir> [--nsrc N]\n"); return 1; }
    const std::string B = argv[1], SP = argv[2]; SessionParams prm;
    for (int i = 3; i < argc; ++i) { std::string a = argv[i]; if (a == "--nsrc" && i + 1 < argc) prm.nsrc = std::atoi(argv[++i]); }
    BoxFilter box{};
    { FILE* f = std::fopen((B + "/box.txt").c_str(), "r"); if (!f) return 2;
      double v[15]; for (int k = 0; k < 15; ++k) if (std::fscanf(f, "%lf", &v[k]) != 1) return 2; std::fclose(f);
      for (int k = 0; k < 3; ++k) { box.c[k] = v[k]; box.s[k] = v[3 + k]; } for (int k = 0; k < 9; ++k) box.rot[k] = v[6 + k]; }
    // (1) contains parity
    auto pts = rd<double>(B + "/pts.f64"); auto bits = rd<uint8_t>(B + "/bits.u8");
    size_t mism = 0, inside = 0;
    for (size_t i = 0; i < bits.size(); ++i) { const bool c = box.contains(pts[i * 3], pts[i * 3 + 1], pts[i * 3 + 2]); inside += c; mism += (c != (bits[i] != 0)); }
    std::printf("contains parity: %zu points, inside %zu, mismatches %zu %s\n", bits.size(), inside, mism, mism == 0 ? "✅" : "🔴");
    // (2) frames seeing the box on the fixture session
    auto F = rd<double>(SP + "/frames.f64"); auto P = rd<float>(SP + "/points.f32");
    std::vector<SessionFrame> fr(F.size() / 14);
    for (size_t i = 0; i < fr.size(); ++i) { const double* r = &F[i * 14]; SessionFrame& s = fr[i]; s.frame_id = r[0]; s.fx = r[1]; s.fy = r[2]; s.cx = r[3]; s.cy = r[4]; s.image_w = r[5]; s.image_h = r[6]; for (int k = 0; k < 4; ++k) s.q[k] = r[7 + k]; for (int k = 0; k < 3; ++k) s.t[k] = r[11 + k]; }
    SessionTable T; build_session_table(fr, P, prm, T);
    const long NP = T.NP; std::vector<uint8_t> in(NP, 0); long nin = 0;
    for (long n = 0; n < NP; ++n) { in[n] = box.contains(P[n * 3], P[n * 3 + 1], P[n * 3 + 2]); nin += in[n]; }
    std::printf("sparse points inside box: %ld / %ld\nframes seeing box:", nin, NP);
    int cnt = 0;
    for (int i = 0; i < T.NF; ++i) { const uint8_t* v = &T.vis[(size_t)i * NP]; bool sees = false; for (long n = 0; n < NP; ++n) if (v[n] && in[n]) { sees = true; break; } if (sees) { std::printf(" %d", i); ++cnt; } }
    std::printf("\ncount %d / %d\n", cnt, T.NF);
    return mism == 0 ? 0 : 1;
}
