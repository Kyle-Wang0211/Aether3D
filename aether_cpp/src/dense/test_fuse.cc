// test_fuse.cc — host gate for dense_fuse: runs the C++ fusion over the packed fixture97 inputs
// written by fuse_ref_dump.py (pack/) and writes the same per-frame artifacts the Python
// reference wrote (masks/, geosum/, davg/, xyz/, col/), so a byte comparison is the verdict.
//
//   test_fuse <pack_dir> <out_dir> [--inv-from <pack/inv.f64>] [--mode N] [--probe <dir> [--probe-nsrc K]]
//             [--frames a-b] [--ply <path>] [--hash] [--no-dump]
//
// --hash    : print an FNV-1a 64-bit digest of every per-frame artifact (device runs pull digests, not arrays).
// --no-dump : compute and hash only (no per-frame files) — for the on-device run.
//
// --inv-from : inject numpy.linalg.inv results (isolation arm: proves everything downstream of the
//              inverse is bit-exact; the inverse itself is judged by the arm without injection).
// --mode     : matmul accumulation pattern (dense_fuse.h g_fuse_matmul_mode), default 0.
// --probe    : additionally dump frame-0 stage intermediates for the first K sources (probe/s{j}_*.f32).
#include "dense_fuse.h"

#include <fcntl.h>
#include <sys/mman.h>
#include <sys/stat.h>
#include <unistd.h>

#include <chrono>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <string>
#include <vector>
using namespace aether::dense;

static const void* map_file(const std::string& p, size_t expect_bytes) {
    int fd = open(p.c_str(), O_RDONLY);
    if (fd < 0) { std::fprintf(stderr, "MISSING %s\n", p.c_str()); std::exit(2); }
    struct stat st; fstat(fd, &st);
    if ((size_t)st.st_size != expect_bytes) { std::fprintf(stderr, "SIZE %s: %lld != %zu\n", p.c_str(), (long long)st.st_size, expect_bytes); std::exit(2); }
    void* m = mmap(nullptr, expect_bytes, PROT_READ, MAP_PRIVATE, fd, 0);
    close(fd);
    if (m == MAP_FAILED) { std::fprintf(stderr, "MMAP %s\n", p.c_str()); std::exit(2); }
    return m;
}
static uint64_t fnv1a(const void* data, size_t n, uint64_t h = 1469598103934665603ULL) {
    const uint8_t* p = (const uint8_t*)data;
    for (size_t i = 0; i < n; ++i) { h ^= p[i]; h *= 1099511628211ULL; }
    return h;
}
template <class T> static uint64_t hv(const std::vector<T>& v) { return fnv1a(v.data(), v.size() * sizeof(T)); }
static bool g_dump = true;
template <class T> static void dump(const std::string& p, const std::vector<T>& v) {
    if (!g_dump) return;
    FILE* f = std::fopen(p.c_str(), "wb"); if (!f) { std::fprintf(stderr, "CANNOT WRITE %s\n", p.c_str()); std::exit(2); }
    std::fwrite(v.data(), sizeof(T), v.size(), f); std::fclose(f);
}

int main(int argc, char** argv) {
    if (argc < 3) { std::fprintf(stderr, "usage: test_fuse <pack_dir> <out_dir> [--inv-from f] [--mode N] [--probe dir] [--probe-nsrc K] [--frames a-b] [--ply p]\n"); return 1; }
    std::string pack = argv[1], out = argv[2], inv_from, probe_dir, ply_path;
    int probe_nsrc = 3, f0 = 0, f1 = -1, x64_0 = 0, x64_1 = -1;   // --xyz64 a-b: dump float64 world points for frames a..b
    bool do_hash = false;
    for (int i = 3; i < argc; ++i) {
        std::string a = argv[i];
        if (a == "--inv-from" && i + 1 < argc) inv_from = argv[++i];
        else if (a == "--mode" && i + 1 < argc) g_fuse_matmul_mode = std::atoi(argv[++i]);
        else if (a == "--probe" && i + 1 < argc) probe_dir = argv[++i];
        else if (a == "--probe-nsrc" && i + 1 < argc) probe_nsrc = std::atoi(argv[++i]);
        else if (a == "--frames" && i + 1 < argc) { if (std::sscanf(argv[++i], "%d-%d", &f0, &f1) != 2) { std::fprintf(stderr, "bad --frames\n"); return 1; } }
        else if (a == "--ply" && i + 1 < argc) ply_path = argv[++i];
        else if (a == "--hash") do_hash = true;
        else if (a == "--no-dump") g_dump = false;
        else if (a == "--xyz64" && i + 1 < argc) { if (std::sscanf(argv[++i], "%d-%d", &x64_0, &x64_1) != 2) { std::fprintf(stderr, "bad --xyz64\n"); return 1; } }
        else { std::fprintf(stderr, "unknown arg %s\n", a.c_str()); return 1; }
    }
    // meta.txt: NF W H num_src geo_mask_thres geo_pixel_thres geo_depth_thres p0 p1 p2
    int NF, W, H, NS; FuseParams prm;
    {
        FILE* f = std::fopen((pack + "/meta.txt").c_str(), "r"); if (!f) { std::fprintf(stderr, "MISSING meta.txt\n"); return 2; }
        if (std::fscanf(f, "%d %d %d %d %d %f %f %f %f %f", &NF, &W, &H, &NS, &prm.geo_mask_thres, &prm.geo_pixel_thres, &prm.geo_depth_thres,
                        &prm.photo_thres[0], &prm.photo_thres[1], &prm.photo_thres[2]) != 10) { std::fprintf(stderr, "bad meta.txt\n"); return 2; }
        std::fclose(f);
    }
    const size_t N = (size_t)W * H;
    const float* depth = (const float*)map_file(pack + "/depth.f32", (size_t)NF * N * 4);
    const float* conf[3] = {(const float*)map_file(pack + "/conf0.f32", (size_t)NF * N * 4),
                            (const float*)map_file(pack + "/conf1.f32", (size_t)NF * N * 4),
                            (const float*)map_file(pack + "/conf2.f32", (size_t)NF * N * 4)};
    const uint8_t* rgb = (const uint8_t*)map_file(pack + "/rgb.u8", (size_t)NF * N * 3);
    const float* cams = (const float*)map_file(pack + "/cams.f32", (size_t)NF * 36 * 4);
    const int32_t* nb = (const int32_t*)map_file(pack + "/neighbors.i32", (size_t)NF * NS * 4);
    std::printf("pack: NF=%d W=%d H=%d num_src=%d geo_mask_thres=%d geo_pixel_thres=%g geo_depth_thres=%.9g photo=%.9g/%.9g/%.9g mode=%d inv=%s\n",
                NF, W, H, NS, prm.geo_mask_thres, prm.geo_pixel_thres, prm.geo_depth_thres, prm.photo_thres[0], prm.photo_thres[1], prm.photo_thres[2],
                g_fuse_matmul_mode, inv_from.empty() ? "lapack_inv(C++)" : "injected(numpy)");

    std::vector<FuseCamera> cam(NF);
    for (int f = 0; f < NF; ++f) {
        const float* c = cams + (size_t)f * 36;
        for (int k = 0; k < 9; ++k) cam[f].K[k] = (double)c[k];
        double* E = cam[f].E;
        for (int r = 0; r < 3; ++r) { for (int k = 0; k < 3; ++k) E[r * 4 + k] = (double)c[9 + r * 3 + k]; E[r * 4 + 3] = (double)c[18 + r]; }
        E[12] = 0; E[13] = 0; E[14] = 0; E[15] = 1;
        cam[f].depth_min = c[24]; cam[f].depth_max = c[25];
        if (!fuse_camera_finalize(cam[f])) { std::fprintf(stderr, "singular camera %d\n", f); return 3; }
    }
    if (!inv_from.empty()) {
        const double* inv = (const double*)map_file(inv_from, (size_t)NF * 25 * 8);
        for (int f = 0; f < NF; ++f) { std::memcpy(cam[f].invK, inv + (size_t)f * 25, 9 * 8); std::memcpy(cam[f].invE, inv + (size_t)f * 25 + 9, 16 * 8); }
    }
    if (g_dump) { mkdir(out.c_str(), 0755); for (const char* sub : {"masks", "geosum", "davg", "xyz", "col", "xyz64"}) { std::string d = out + "/" + sub; mkdir(d.c_str(), 0755); } }

    if (!probe_dir.empty()) {
        mkdir(probe_dir.c_str(), 0755);
        for (int j = 0; j < probe_nsrc && j < NS; ++j) {
            const int s = nb[j];
            GeoProbe pr; std::vector<uint8_t> m; std::vector<float> dr;
            check_geometric_consistency(W, H, depth, cam[0], depth + (size_t)s * N, cam[s], prm.geo_pixel_thres, prm.geo_depth_thres, m, dr, &pr);
            char b[64];
            std::snprintf(b, sizeof b, "/s%d_", j); std::string pfx = probe_dir + b;
            dump(pfx + "x_src.f32", pr.x_src); dump(pfx + "y_src.f32", pr.y_src); dump(pfx + "sampled.f32", pr.sampled);
            dump(pfx + "depth_reproj.f32", pr.depth_reproj_raw); dump(pfx + "x_reproj.f32", pr.x_reproj); dump(pfx + "y_reproj.f32", pr.y_reproj);
            dump(pfx + "mask.u8", m); dump(pfx + "x_src64.f64", pr.x_src64); dump(pfx + "y_src64.f64", pr.y_src64);
        }
        std::printf("probe: frame 0, %d sources -> %s\n", probe_nsrc, probe_dir.c_str());
    }

    if (f1 < 0) f1 = NF - 1;
    std::vector<float> all_xyz; std::vector<uint8_t> all_rgb;
    size_t total = 0; double ph = 0, ge = 0, fi = 0; uint64_t hall = 1469598103934665603ULL;
    auto t0 = std::chrono::steady_clock::now();
    for (int f = f0; f <= f1; ++f) {
        std::vector<const float*> ds; std::vector<const FuseCamera*> cs;
        for (int j = 0; j < NS; ++j) { const int s = nb[(size_t)f * NS + j]; ds.push_back(depth + (size_t)s * N); cs.push_back(&cam[s]); }
        const float* cf[3] = {conf[0] + (size_t)f * N, conf[1] + (size_t)f * N, conf[2] + (size_t)f * N};
        FrameFusion fr;
        fuse_frame(W, H, depth + (size_t)f * N, cf, rgb + (size_t)f * N * 3, cam[f], ds, cs, prm, fr);
        char b[32]; std::snprintf(b, sizeof b, "/%04d", f);
        dump(out + "/masks" + b + ".u8", fr.final_mask); dump(out + "/geosum" + b + ".i32", fr.geo_sum); dump(out + "/davg" + b + ".f64", fr.d_avg);
        dump(out + "/xyz" + b + ".f32", fr.xyz); dump(out + "/col" + b + ".u8", fr.rgb);
        if (x64_1 >= 0 && f >= x64_0 && f <= x64_1) dump(out + "/xyz64" + b + ".f64", fr.xyz64);
        if (do_hash) {
            const uint64_t hm = hv(fr.final_mask), hg = hv(fr.geo_sum), hd = hv(fr.d_avg), hx = hv(fr.xyz), hc = hv(fr.rgb);
            std::printf("H %04d masks %016llx geosum %016llx davg %016llx xyz %016llx col %016llx n %zu\n", f, (unsigned long long)hm, (unsigned long long)hg, (unsigned long long)hd, (unsigned long long)hx, (unsigned long long)hc, fr.xyz.size() / 3);
            const uint64_t hs[5] = {hm, hg, hd, hx, hc}; hall = fnv1a(hs, sizeof hs, hall);
        }
        total += fr.xyz.size() / 3; ph += fr.photo_frac; ge += fr.geo_frac; fi += fr.final_frac;
        if (!ply_path.empty()) { all_xyz.insert(all_xyz.end(), fr.xyz.begin(), fr.xyz.end()); all_rgb.insert(all_rgb.end(), fr.rgb.begin(), fr.rgb.end()); }
        if (f % 10 == 0 || f == f1) {
            const double el = std::chrono::duration<double>(std::chrono::steady_clock::now() - t0).count();
            std::printf("  帧%3d/%d final %.3f  points so far %zu  %.1fs\n", f, NF, fr.final_frac, total, el); std::fflush(stdout);
        }
    }
    const int nfr = f1 - f0 + 1;
    std::printf("存活 photo %.2f%% geo %.2f%% final %.2f%%   点数 %zu\n", 100 * ph / nfr, 100 * ge / nfr, 100 * fi / nfr, total);
    if (do_hash) std::printf("HALL %016llx frames %d-%d mode %d\n", (unsigned long long)hall, f0, f1, g_fuse_matmul_mode);
    if (!ply_path.empty()) { write_ply(ply_path.c_str(), all_xyz, all_rgb); std::printf("ply %s (%zu pts)\n", ply_path.c_str(), all_xyz.size() / 3); }
    return 0;
}
