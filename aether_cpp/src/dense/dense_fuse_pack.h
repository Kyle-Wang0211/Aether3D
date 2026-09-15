// dense_fuse_pack.h — run the certified fusion (dense_fuse) over an on-disk depth pack with mmap, so the
// fusion never holds all depth maps and the ORT session in memory at once (18 GB host rule / phone jetsam).
// Pack layout = fuse_ref_dump.py pack/: depth.f32, conf0..2.f32 (NF×H×W), rgb.u8 (NF×H×W×3), cams.f32 (NF×36),
// neighbors.i32 (NF×NS), meta.txt "NF W H NS geo_mask_thres geo_pixel_thres geo_depth_thres p0 p1 p2".
#pragma once
#include <cmath>
#include <cstdint>
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

// Fuses reference frames [f0, f1] (f1 < 0 -> NF-1) and writes out_ply (empty -> no file). Returns 0 on success,
// 1 cancelled, 2 pack error.
// box: when given, only fused points inside the box are delivered (PLY, digests, point counts).
int fuse_pack(const std::string& pack_dir, int f0, int f1, const std::string& out_ply,
              dense_progress_fn progress, void* user, FusePackStats* stats, const BoxFilter* box = nullptr);

}  // namespace aether::dense
