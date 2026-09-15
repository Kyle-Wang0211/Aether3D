// dense_fuse_pack.h — run the certified fusion (dense_fuse) over an on-disk depth pack with mmap, so the
// fusion never holds all depth maps and the ORT session in memory at once (18 GB host rule / phone jetsam).
// Pack layout = fuse_ref_dump.py pack/: depth.f32, conf0..2.f32 (NF×H×W), rgb.u8 (NF×H×W×3), cams.f32 (NF×36),
// neighbors.i32 (NF×NS), meta.txt "NF W H NS geo_mask_thres geo_pixel_thres geo_depth_thres p0 p1 p2".
//
// [2026-09-15 Stage 3] Split into a per-frame function (FusePack + fuse_pack_frame) plus a writer
// (FusePlyWriter) so the pipeline can fuse a reference frame the moment its views are inferred and hand the
// points to the app while inference is still running. fuse_pack() below is unchanged from the caller's side
// and is now just "open, loop f0..f1, write" over those pieces — the numerics are the same fuse_frame call on
// the same mmap'd rows, gated byte-for-byte by test_progressive.cc.
#pragma once
#include <cmath>
#include <cstdint>
#include <cstdio>
#include <string>
#include <vector>
#include "dense_fuse.h"

namespace aether::dense {

typedef int (*dense_progress_fn)(const char* phase, int done, int total, void* user);   // non-zero -> cancel

struct FusePackStats {
    int frames = 0;
    size_t points = 0;
    double photo_frac = 0, geo_frac = 0, final_frac = 0;
    uint64_t digest = 1469598103934665603ULL;   // FNV-1a over per-frame (masks, geosum, davg, xyz, col) digests
    std::vector<uint64_t> frame_digest;         // per frame: digest of the five artifacts
};

uint64_t fnv1a64(const void* data, size_t n, uint64_t h = 1469598103934665603ULL);

// The app's SelectionBox (pocketworld lib/official_capture/selection_box.dart): world-space oriented box with
// centre c, FULL side lengths s and row-major local->world rotation rot. contains() is that class's contains()
// copied verbatim: local = rot^T (p - c); inside iff |l_k| <= s_k / 2 on every axis.
struct BoxFilter {
    double c[3], s[3], rot[9];
    bool contains(double wx, double wy, double wz) const {
        const double px = wx - c[0], py = wy - c[1], pz = wz - c[2];
        const double lx = rot[0] * px + rot[3] * py + rot[6] * pz;
        const double ly = rot[1] * px + rot[4] * py + rot[7] * pz;
        const double lz = rot[2] * px + rot[5] * py + rot[8] * pz;
        return std::fabs(lx) <= s[0] / 2 && std::fabs(ly) <= s[1] / 2 && std::fabs(lz) <= s[2] / 2;
    }
};

// ---- pack ------------------------------------------------------------------------------------------------
// One read-only whole-file mapping. Move-only; unmaps on destruction.
struct FuseMap {
    const void* p = nullptr; size_t n = 0;
    FuseMap() = default;
    FuseMap(const FuseMap&) = delete;
    FuseMap& operator=(const FuseMap&) = delete;
    ~FuseMap() { close(); }
    bool open(const std::string& path, size_t expect);   // false unless the file exists AND is exactly `expect` bytes
    void close();
};

// An opened depth pack: meta + mmap'd rows + finalised cameras. open() is the front half of the old
// fuse_pack() verbatim and returns false exactly where that returned 2 (pack error).
// NOTE the progressive caller re-opens a FusePack after each batch of new rows: POSIX leaves it unspecified
// whether a MAP_PRIVATE mapping observes writes made to the file after the mapping was created, so the only
// portable guarantee is a mapping created after the write. Re-opening is ~6 mmap calls and NF 3x3/4x4
// inverses, i.e. free next to one fuse_frame.
struct FusePack {
    int NF = 0, W = 0, H = 0, NS = 0;
    size_t N = 0;                       // W*H
    FuseParams prm;
    const float* depth = nullptr;
    const float* conf[3] = {nullptr, nullptr, nullptr};
    const uint8_t* rgb = nullptr;
    const int32_t* nb = nullptr;
    std::vector<FuseCamera> cam;
    bool open(const std::string& pack_dir);
private:
    FuseMap md_, mc_[3], mr_, mk_, mn_;
};

// Everything one reference frame contributes. xyz/rgb are already box-filtered, i.e. exactly the bytes that
// frame writes into out_ply and exactly the buffers handed to pwdense_chunk_fn.
// hs[] are the five artifact digests in the order fuse_pack folds them, kept so a caller that fuses OUT of
// frame order can still reproduce FusePackStats::digest by folding hs in frame order at the end.
struct FuseFrameResult {
    int frame = -1;
    std::vector<float> xyz;
    std::vector<uint8_t> rgb;
    uint64_t hs[5] = {0, 0, 0, 0, 0};   // final_mask, geo_sum, d_avg, xyz, rgb
    uint64_t digest = 0;                // fnv1a64(hs, sizeof hs) == FusePackStats::frame_digest[frame - f0]
    double photo_frac = 0, geo_frac = 0, final_frac = 0;
    size_t points() const { return xyz.size() / 3; }
};

// Fuses reference frame f (pack-local index) — the body of the old fuse_pack loop, unchanged. False = the
// pack is inconsistent (f out of range). Per-frame results are independent, so the order in which frames are
// fused cannot change any of them.
bool fuse_pack_frame(const FusePack& pk, int f, const BoxFilter* box, FuseFrameResult& out);

// ---- writer ----------------------------------------------------------------------------------------------
// PLY writer of fuse_official.py / sparse_ply.dart layout: binary_little_endian, per point 3 float32 + 3 u8,
// interleaved. The element count is only known at the end, so begin() reserves a 200-byte header placeholder
// and finish() patches the real header in (shifting the payload if it is not exactly 200 bytes).
// Both the legacy loop and the progressive assembler go through this one class, so their bytes cannot drift.
class FusePlyWriter {
public:
    FusePlyWriter() = default;
    FusePlyWriter(const FusePlyWriter&) = delete;
    FusePlyWriter& operator=(const FusePlyWriter&) = delete;
    ~FusePlyWriter() { abort(); }
    bool begin(const std::string& path);   // empty path -> counts only, writes nothing. false -> cannot create
    void append(const float* xyz, const uint8_t* rgb, size_t n);
    bool finish();                         // patch the header; false on I/O error
    void abort();                          // cancel: close and leave the partial file (legacy behaviour)
    size_t points() const { return total_; }
private:
    FILE* f_ = nullptr;
    std::string path_;
    size_t total_ = 0;
};

// ---- progressive schedule --------------------------------------------------------------------------------
// Views are inferred in an arbitrary order; a reference frame becomes fusable the moment its own view AND all
// NS of its source views have been inferred. The index space is the caller's — session-frame indices with
// SessionTable::neighbors in dense_pipeline, pack-local indices with neighbors.i32 in test_progressive — so
// neighbors must be NF*NS laid out in that same space.
class FuseScheduler {
public:
    FuseScheduler(const int32_t* neighbors, int NF, int NS, int ref_begin, int ref_end);
    void mark_inferred(int view);
    bool inferred(int view) const;
    void take_ready(std::vector<int>& out);   // refs that became fusable, ascending; each handed out once
    int remaining() const;                    // refs not handed out yet (0 after the last view is marked)
private:
    const int32_t* nb_; int NF_, NS_, r0_, r1_;
    std::vector<uint8_t> inferred_, handed_;
};

// ---- spill -----------------------------------------------------------------------------------------------
// One fused frame's delivered points on disk, so the assembler can write the PLY in frame order without
// holding every frame in RAM (fixture97 = 22 M points = 330 MB of xyz+rgb).
// Layout: uint64 n, n*3 float32 xyz, n*3 uint8 rgb.
bool fuse_spill_write(const std::string& path, const std::vector<float>& xyz, const std::vector<uint8_t>& rgb);
bool fuse_spill_append(const std::string& path, FusePlyWriter& w);   // read back and append; false on error

// ---- legacy entry point ----------------------------------------------------------------------------------
// Fuses reference frames [f0, f1] (f1 < 0 -> NF-1) and writes out_ply (empty -> no file). Returns 0 on success,
// 1 cancelled, 2 pack error.
// box: when given, only fused points inside the box are delivered (PLY, digests, point counts).
int fuse_pack(const std::string& pack_dir, int f0, int f1, const std::string& out_ply,
              dense_progress_fn progress, void* user, FusePackStats* stats, const BoxFilter* box = nullptr);

}  // namespace aether::dense
