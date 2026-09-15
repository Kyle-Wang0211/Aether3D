// dense_fuse_pack.cc — see dense_fuse_pack.h. The per-frame body is the one test_fuse.cc gates (bit-identical
// to the official Python on fixture97, host and iPhone 14 Pro, 2026-09-15); the 2026-09-15 Stage-3 split moved
// it into fuse_pack_frame() without touching a single arithmetic statement.
#include "dense_fuse_pack.h"

#include <fcntl.h>
#include <sys/mman.h>
#include <sys/stat.h>
#include <unistd.h>

#include <cstring>

namespace aether::dense {

uint64_t fnv1a64(const void* data, size_t n, uint64_t h) {
    const uint8_t* p = (const uint8_t*)data;
    for (size_t i = 0; i < n; ++i) { h ^= p[i]; h *= 1099511628211ULL; }
    return h;
}

namespace {
template <class T> uint64_t hv(const std::vector<T>& v) { return fnv1a64(v.data(), v.size() * sizeof(T)); }
constexpr size_t kPlyHeaderSlot = 200;   // placeholder reserved by FusePlyWriter::begin
}  // namespace

// ---- FuseMap / FusePack ------------------------------------------------------------------------------------
bool FuseMap::open(const std::string& path, size_t expect) {
    close();
    int fd = ::open(path.c_str(), O_RDONLY); if (fd < 0) return false;
    struct stat st; if (fstat(fd, &st) != 0 || (size_t)st.st_size != expect) { ::close(fd); return false; }
    p = mmap(nullptr, expect, PROT_READ, MAP_PRIVATE, fd, 0); ::close(fd);
    if (p == MAP_FAILED) { p = nullptr; return false; }
    n = expect; return true;
}
void FuseMap::close() { if (p) munmap((void*)p, n); p = nullptr; n = 0; }

bool FusePack::open(const std::string& pack) {
    {
        FILE* f = std::fopen((pack + "/meta.txt").c_str(), "r"); if (!f) return false;
        const int k = std::fscanf(f, "%d %d %d %d %d %f %f %f %f %f", &NF, &W, &H, &NS, &prm.geo_mask_thres, &prm.geo_pixel_thres,
                                  &prm.geo_depth_thres, &prm.photo_thres[0], &prm.photo_thres[1], &prm.photo_thres[2]);
        std::fclose(f); if (k != 10) return false;
    }
    N = (size_t)W * H;
    if (!md_.open(pack + "/depth.f32", (size_t)NF * N * 4) || !mc_[0].open(pack + "/conf0.f32", (size_t)NF * N * 4) ||
        !mc_[1].open(pack + "/conf1.f32", (size_t)NF * N * 4) || !mc_[2].open(pack + "/conf2.f32", (size_t)NF * N * 4) ||
        !mr_.open(pack + "/rgb.u8", (size_t)NF * N * 3) || !mk_.open(pack + "/cams.f32", (size_t)NF * 36 * 4) ||
        !mn_.open(pack + "/neighbors.i32", (size_t)NF * NS * 4)) return false;
    depth = (const float*)md_.p; for (int k = 0; k < 3; ++k) conf[k] = (const float*)mc_[k].p;
    rgb = (const uint8_t*)mr_.p; nb = (const int32_t*)mn_.p;
    const float* cams = (const float*)mk_.p;

    cam.assign(NF, FuseCamera{});
    for (int f = 0; f < NF; ++f) {
        const float* c = cams + (size_t)f * 36;
        for (int k = 0; k < 9; ++k) cam[f].K[k] = (double)c[k];
        double* E = cam[f].E;
        for (int r = 0; r < 3; ++r) { for (int k = 0; k < 3; ++k) E[r * 4 + k] = (double)c[9 + r * 3 + k]; E[r * 4 + 3] = (double)c[18 + r]; }
        E[12] = 0; E[13] = 0; E[14] = 0; E[15] = 1;
        cam[f].depth_min = c[24]; cam[f].depth_max = c[25];
        if (!fuse_camera_finalize(cam[f])) return false;
    }
    return true;
}

// ---- one reference frame -----------------------------------------------------------------------------------
bool fuse_pack_frame(const FusePack& pk, int f, const BoxFilter* box, FuseFrameResult& out) {
    if (f < 0 || f >= pk.NF) return false;
    const size_t N = pk.N;
    std::vector<const float*> ds; std::vector<const FuseCamera*> cs;
    for (int j = 0; j < pk.NS; ++j) { const int s = pk.nb[(size_t)f * pk.NS + j]; ds.push_back(pk.depth + (size_t)s * N); cs.push_back(&pk.cam[s]); }
    const float* cf[3] = {pk.conf[0] + (size_t)f * N, pk.conf[1] + (size_t)f * N, pk.conf[2] + (size_t)f * N};
    FrameFusion fr;
    fuse_frame(pk.W, pk.H, pk.depth + (size_t)f * N, cf, pk.rgb + (size_t)f * N * 3, pk.cam[f], ds, cs, pk.prm, fr);
    if (box) {   // selection: deliver only points inside the box (SelectionBox.contains on the float32 world point)
        std::vector<float> kx; std::vector<uint8_t> kc; const size_t n = fr.xyz.size() / 3; kx.reserve(fr.xyz.size()); kc.reserve(fr.rgb.size());
        for (size_t i = 0; i < n; ++i)
            if (box->contains(fr.xyz[i * 3], fr.xyz[i * 3 + 1], fr.xyz[i * 3 + 2])) {
                kx.insert(kx.end(), fr.xyz.begin() + i * 3, fr.xyz.begin() + i * 3 + 3); kc.insert(kc.end(), fr.rgb.begin() + i * 3, fr.rgb.begin() + i * 3 + 3);
            }
        fr.xyz.swap(kx); fr.rgb.swap(kc);
    }
    out.frame = f;
    out.hs[0] = hv(fr.final_mask); out.hs[1] = hv(fr.geo_sum); out.hs[2] = hv(fr.d_avg); out.hs[3] = hv(fr.xyz); out.hs[4] = hv(fr.rgb);
    out.digest = fnv1a64(out.hs, sizeof out.hs);
    out.photo_frac = fr.photo_frac; out.geo_frac = fr.geo_frac; out.final_frac = fr.final_frac;
    out.xyz.swap(fr.xyz); out.rgb.swap(fr.rgb);
    return true;
}

// ---- writer --------------------------------------------------------------------------------------------------
bool FusePlyWriter::begin(const std::string& path) {
    abort(); path_ = path; total_ = 0;
    if (path.empty()) return true;
    f_ = std::fopen(path.c_str(), "wb"); if (!f_) return false;
    std::fprintf(f_, "%*s", (int)kPlyHeaderSlot, "");   // header placeholder
    return true;
}
void FusePlyWriter::append(const float* xyz, const uint8_t* rgb, size_t n) {
    if (f_) for (size_t i = 0; i < n; ++i) { std::fwrite(&xyz[i * 3], 4, 3, f_); std::fwrite(&rgb[i * 3], 1, 3, f_); }
    total_ += n;
}
void FusePlyWriter::abort() { if (f_) std::fclose(f_); f_ = nullptr; }
bool FusePlyWriter::finish() {
    if (!f_) { path_.clear(); return true; }
    char hdr[256];
    const int len = std::snprintf(hdr, sizeof hdr, "ply\nformat binary_little_endian 1.0\nelement vertex %zu\nproperty float x\nproperty float y\nproperty float z\n"
                                                   "property uchar red\nproperty uchar green\nproperty uchar blue\nend_header\n", total_);
    std::fseek(f_, 0, SEEK_SET); std::fwrite(hdr, 1, (size_t)len, f_); std::fclose(f_); f_ = nullptr;
    if ((size_t)len != kPlyHeaderSlot) {   // the placeholder was 200 bytes of spaces: shift the payload
        FILE* in = std::fopen(path_.c_str(), "rb"); const std::string tmp = path_ + ".tmp"; FILE* out = std::fopen(tmp.c_str(), "wb");
        if (!in || !out) { if (in) std::fclose(in); if (out) std::fclose(out); return false; }
        std::fwrite(hdr, 1, (size_t)len, out); std::fseek(in, (long)kPlyHeaderSlot, SEEK_SET);
        std::vector<char> buf(1 << 20); size_t r;
        while ((r = std::fread(buf.data(), 1, buf.size(), in)) > 0) std::fwrite(buf.data(), 1, r, out);
        std::fclose(in); std::fclose(out); std::rename(tmp.c_str(), path_.c_str());
    }
    path_.clear(); return true;
}

// ---- scheduler -----------------------------------------------------------------------------------------------
FuseScheduler::FuseScheduler(const int32_t* neighbors, int NF, int NS, int ref_begin, int ref_end)
    : nb_(neighbors), NF_(NF), NS_(NS), r0_(ref_begin), r1_(ref_end), inferred_(NF, 0), handed_(NF, 0) {}
void FuseScheduler::mark_inferred(int view) { if (view >= 0 && view < NF_) inferred_[view] = 1; }
bool FuseScheduler::inferred(int view) const { return view >= 0 && view < NF_ && inferred_[view]; }
void FuseScheduler::take_ready(std::vector<int>& out) {
    out.clear();
    for (int f = r0_; f <= r1_; ++f) {
        if (handed_[f] || !inferred_[f]) continue;
        bool ok = true;
        for (int j = 0; j < NS_ && ok; ++j) ok = inferred_[nb_[(size_t)f * NS_ + j]] != 0;
        if (ok) { handed_[f] = 1; out.push_back(f); }
    }
}
int FuseScheduler::remaining() const { int n = 0; for (int f = r0_; f <= r1_; ++f) n += !handed_[f]; return n; }

// ---- spill ---------------------------------------------------------------------------------------------------
bool fuse_spill_write(const std::string& path, const std::vector<float>& xyz, const std::vector<uint8_t>& rgb) {
    FILE* f = std::fopen(path.c_str(), "wb"); if (!f) return false;
    const uint64_t n = xyz.size() / 3;
    bool ok = std::fwrite(&n, sizeof n, 1, f) == 1;
    if (ok && n) ok = std::fwrite(xyz.data(), 4, xyz.size(), f) == xyz.size() && std::fwrite(rgb.data(), 1, rgb.size(), f) == rgb.size();
    std::fclose(f); return ok;
}
bool fuse_spill_append(const std::string& path, FusePlyWriter& w) {
    FILE* f = std::fopen(path.c_str(), "rb"); if (!f) return false;
    uint64_t n = 0; bool ok = std::fread(&n, sizeof n, 1, f) == 1;
    std::vector<float> xyz; std::vector<uint8_t> rgb;
    if (ok && n) {
        xyz.resize((size_t)n * 3); rgb.resize((size_t)n * 3);
        ok = std::fread(xyz.data(), 4, xyz.size(), f) == xyz.size() && std::fread(rgb.data(), 1, rgb.size(), f) == rgb.size();
    }
    std::fclose(f);
    if (ok) w.append(xyz.data(), rgb.data(), (size_t)n);
    return ok;
}

// ---- legacy entry point ----------------------------------------------------------------------------------------
int fuse_pack(const std::string& pack, int f0, int f1, const std::string& out_ply,
              dense_progress_fn progress, void* user, FusePackStats* st, const BoxFilter* box) {
    FusePack pk;
    if (!pk.open(pack)) return 2;
    if (f1 < 0) f1 = pk.NF - 1;
    FusePlyWriter ply;
    if (!ply.begin(out_ply)) return 2;
    double ph = 0, ge = 0, fi = 0; uint64_t hall = 1469598103934665603ULL;
    if (st) { st->frame_digest.clear(); st->frames = 0; }
    for (int f = f0; f <= f1; ++f) {
        if (progress && progress("fuse", f - f0, f1 - f0 + 1, user)) { ply.abort(); return 1; }
        FuseFrameResult fr;
        if (!fuse_pack_frame(pk, f, box, fr)) { ply.abort(); return 2; }
        hall = fnv1a64(fr.hs, sizeof fr.hs, hall);
        if (st) st->frame_digest.push_back(fr.digest);
        ply.append(fr.xyz.data(), fr.rgb.data(), fr.points());
        ph += fr.photo_frac; ge += fr.geo_frac; fi += fr.final_frac;
    }
    if (!ply.finish()) return 2;
    const int nfr = f1 - f0 + 1;
    if (st) { st->frames = nfr; st->points = ply.points(); st->photo_frac = ph / nfr; st->geo_frac = ge / nfr; st->final_frac = fi / nfr; st->digest = hall; }
    return 0;
}

}  // namespace aether::dense
