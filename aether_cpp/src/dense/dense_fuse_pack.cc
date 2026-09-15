// dense_fuse_pack.cc — see dense_fuse_pack.h. The per-frame loop is the one test_fuse.cc gates (bit-identical to
// the official Python on fixture97, host and iPhone 14 Pro, 2026-09-15).
#include "dense_fuse_pack.h"

#include <fcntl.h>
#include <sys/mman.h>
#include <sys/stat.h>
#include <unistd.h>

#include <cstdio>
#include <cstring>

namespace aether::dense {

uint64_t fnv1a64(const void* data, size_t n, uint64_t h) {
    const uint8_t* p = (const uint8_t*)data;
    for (size_t i = 0; i < n; ++i) { h ^= p[i]; h *= 1099511628211ULL; }
    return h;
}

namespace {
struct Map {
    const void* p = nullptr; size_t n = 0;
    bool open(const std::string& path, size_t expect) {
        int fd = ::open(path.c_str(), O_RDONLY); if (fd < 0) return false;
        struct stat st; if (fstat(fd, &st) != 0 || (size_t)st.st_size != expect) { ::close(fd); return false; }
        p = mmap(nullptr, expect, PROT_READ, MAP_PRIVATE, fd, 0); ::close(fd);
        if (p == MAP_FAILED) { p = nullptr; return false; }
        n = expect; return true;
    }
    ~Map() { if (p) munmap((void*)p, n); }
};
template <class T> uint64_t hv(const std::vector<T>& v) { return fnv1a64(v.data(), v.size() * sizeof(T)); }
}  // namespace

int fuse_pack(const std::string& pack, int f0, int f1, const std::string& out_ply,
              dense_progress_fn progress, void* user, FusePackStats* st, const BoxFilter* box) {
    int NF, W, H, NS; FuseParams prm;
    {
        FILE* f = std::fopen((pack + "/meta.txt").c_str(), "r"); if (!f) return 2;
        const int k = std::fscanf(f, "%d %d %d %d %d %f %f %f %f %f", &NF, &W, &H, &NS, &prm.geo_mask_thres, &prm.geo_pixel_thres,
                                  &prm.geo_depth_thres, &prm.photo_thres[0], &prm.photo_thres[1], &prm.photo_thres[2]);
        std::fclose(f); if (k != 10) return 2;
    }
    const size_t N = (size_t)W * H;
    Map md, mc[3], mr, mk, mn;
    if (!md.open(pack + "/depth.f32", (size_t)NF * N * 4) || !mc[0].open(pack + "/conf0.f32", (size_t)NF * N * 4) ||
        !mc[1].open(pack + "/conf1.f32", (size_t)NF * N * 4) || !mc[2].open(pack + "/conf2.f32", (size_t)NF * N * 4) ||
        !mr.open(pack + "/rgb.u8", (size_t)NF * N * 3) || !mk.open(pack + "/cams.f32", (size_t)NF * 36 * 4) ||
        !mn.open(pack + "/neighbors.i32", (size_t)NF * NS * 4)) return 2;
    const float* depth = (const float*)md.p; const float* conf[3] = {(const float*)mc[0].p, (const float*)mc[1].p, (const float*)mc[2].p};
    const uint8_t* rgb = (const uint8_t*)mr.p; const float* cams = (const float*)mk.p; const int32_t* nb = (const int32_t*)mn.p;

    std::vector<FuseCamera> cam(NF);
    for (int f = 0; f < NF; ++f) {
        const float* c = cams + (size_t)f * 36;
        for (int k = 0; k < 9; ++k) cam[f].K[k] = (double)c[k];
        double* E = cam[f].E;
        for (int r = 0; r < 3; ++r) { for (int k = 0; k < 3; ++k) E[r * 4 + k] = (double)c[9 + r * 3 + k]; E[r * 4 + 3] = (double)c[18 + r]; }
        E[12] = 0; E[13] = 0; E[14] = 0; E[15] = 1;
        cam[f].depth_min = c[24]; cam[f].depth_max = c[25];
        if (!fuse_camera_finalize(cam[f])) return 2;
    }
    if (f1 < 0) f1 = NF - 1;
    FILE* ply = nullptr; size_t total = 0;
    if (!out_ply.empty()) { ply = std::fopen(out_ply.c_str(), "wb"); if (!ply) return 2; std::fprintf(ply, "%*s", 200, ""); }   // header placeholder
    double ph = 0, ge = 0, fi = 0; uint64_t hall = 1469598103934665603ULL;
    if (st) { st->frame_digest.clear(); st->frames = 0; }
    for (int f = f0; f <= f1; ++f) {
        if (progress && progress("fuse", f - f0, f1 - f0 + 1, user)) { if (ply) std::fclose(ply); return 1; }
        std::vector<const float*> ds; std::vector<const FuseCamera*> cs;
        for (int j = 0; j < NS; ++j) { const int s = nb[(size_t)f * NS + j]; ds.push_back(depth + (size_t)s * N); cs.push_back(&cam[s]); }
        const float* cf[3] = {conf[0] + (size_t)f * N, conf[1] + (size_t)f * N, conf[2] + (size_t)f * N};
        FrameFusion fr;
        fuse_frame(W, H, depth + (size_t)f * N, cf, rgb + (size_t)f * N * 3, cam[f], ds, cs, prm, fr);
        if (box) {   // selection: deliver only points inside the box (SelectionBox.contains on the float32 world point)
            std::vector<float> kx; std::vector<uint8_t> kc; const size_t n = fr.xyz.size() / 3; kx.reserve(fr.xyz.size()); kc.reserve(fr.rgb.size());
            for (size_t i = 0; i < n; ++i)
                if (box->contains(fr.xyz[i * 3], fr.xyz[i * 3 + 1], fr.xyz[i * 3 + 2])) {
                    kx.insert(kx.end(), fr.xyz.begin() + i * 3, fr.xyz.begin() + i * 3 + 3); kc.insert(kc.end(), fr.rgb.begin() + i * 3, fr.rgb.begin() + i * 3 + 3);
                }
            fr.xyz.swap(kx); fr.rgb.swap(kc);
        }
        const uint64_t hs[5] = {hv(fr.final_mask), hv(fr.geo_sum), hv(fr.d_avg), hv(fr.xyz), hv(fr.rgb)};
        const uint64_t hf = fnv1a64(hs, sizeof hs); hall = fnv1a64(hs, sizeof hs, hall);
        if (st) st->frame_digest.push_back(hf);
        if (ply) { const size_t n = fr.xyz.size() / 3; for (size_t i = 0; i < n; ++i) { std::fwrite(&fr.xyz[i * 3], 4, 3, ply); std::fwrite(&fr.rgb[i * 3], 1, 3, ply); } }
        total += fr.xyz.size() / 3; ph += fr.photo_frac; ge += fr.geo_frac; fi += fr.final_frac;
    }
    if (ply) {   // write the real header into the placeholder (fuse_official.py / sparse_ply.dart layout, header < 4096 B)
        char hdr[256];
        const int len = std::snprintf(hdr, sizeof hdr, "ply\nformat binary_little_endian 1.0\nelement vertex %zu\nproperty float x\nproperty float y\nproperty float z\n"
                                                        "property uchar red\nproperty uchar green\nproperty uchar blue\nend_header\n", total);
        std::fseek(ply, 0, SEEK_SET); std::fwrite(hdr, 1, (size_t)len, ply); std::fclose(ply);
        // the placeholder was 200 bytes of spaces: shift payload if the header is not exactly 200 bytes
        if (len != 200) {
            FILE* in = std::fopen(out_ply.c_str(), "rb"); std::string tmp = out_ply + ".tmp"; FILE* out = std::fopen(tmp.c_str(), "wb");
            if (!in || !out) { if (in) std::fclose(in); if (out) std::fclose(out); return 2; }
            std::fwrite(hdr, 1, (size_t)len, out); std::fseek(in, 200, SEEK_SET);
            std::vector<char> buf(1 << 20); size_t r;
            while ((r = std::fread(buf.data(), 1, buf.size(), in)) > 0) std::fwrite(buf.data(), 1, r, out);
            std::fclose(in); std::fclose(out); std::rename(tmp.c_str(), out_ply.c_str());
        }
    }
    const int nfr = f1 - f0 + 1;
    if (st) { st->frames = nfr; st->points = total; st->photo_frac = ph / nfr; st->geo_frac = ge / nfr; st->final_frac = fi / nfr; st->digest = hall; }
    return 0;
}

}  // namespace aether::dense
