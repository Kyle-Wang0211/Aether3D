// test_progressive.cc — host gate for Stage-3 progressive delivery (dense_fuse_pack.h).
//
//   test_progressive <pack_dir> <out_dir> [--refs a-b] [--seed N] [--expect-sha HEX]
//                    [--box cx cy cz sx sy sz] [--neg-delivery-order]
//
// Three arms over the SAME certified pack, all of them writing a PLY:
//   legacy      fuse_pack()                      — the pre-Stage-3 entry point, still the product's chunk-less path
//   perframe    FusePack + fuse_pack_frame()     — the split, driven in frame order
//   progressive FuseScheduler + spill + assemble — the split, driven by a synthetic inference order
//               (ascending = what dense_pipeline's `for (int v : infer)` really does, then reverse, then a
//                seeded shuffle; fusion order therefore varies while the PLY may not)
// Verdict: all PLYs byte-identical (sha256) and all FusePackStats identical, or the harness exits non-zero.
//
// The progressive arm additionally asserts the scheduling contract that pwdense_chunk_fn promises:
//   (a) every reference frame is fused exactly once,
//   (b) a frame is delivered only after its own view AND all NS source views were marked inferred,
//   (c) the delivered point counts sum to the PLY's vertex count.
// (b) is checked against an independent `inferred` bitmap owned by this file, not the scheduler's.
//
// --neg-delivery-order is the NEGATIVE CONTROL: it assembles the progressive arm in DELIVERY order instead of
// frame order, and then demands the PLY and the stats DIFFER from legacy. Without it a gate that compared two
// things which happen to be equal for an unrelated reason (e.g. a pack whose fusion order is frame order
// anyway) would pass vacuously.
#include "dense_fuse_pack.h"

#include <CommonCrypto/CommonDigest.h>
#include <sys/stat.h>

#include <algorithm>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <random>
#include <string>
#include <vector>
using namespace aether::dense;

static int g_fail = 0;
#define CHECK(cond, ...) do { if (!(cond)) { std::printf("🔴 "); std::printf(__VA_ARGS__); std::printf("\n"); ++g_fail; } } while (0)

static std::string sha256_file(const std::string& path) {
    FILE* f = std::fopen(path.c_str(), "rb"); if (!f) return "<missing>";
    CC_SHA256_CTX c; CC_SHA256_Init(&c);
    std::vector<unsigned char> buf(1 << 20); size_t r;
    while ((r = std::fread(buf.data(), 1, buf.size(), f)) > 0) CC_SHA256_Update(&c, buf.data(), (CC_LONG)r);
    std::fclose(f);
    unsigned char d[CC_SHA256_DIGEST_LENGTH]; CC_SHA256_Final(d, &c);
    char hex[2 * CC_SHA256_DIGEST_LENGTH + 1];
    for (int i = 0; i < CC_SHA256_DIGEST_LENGTH; ++i) std::snprintf(hex + 2 * i, 3, "%02x", d[i]);
    return hex;
}
// "element vertex N" out of the PLY header, so the point total is read back from the file, not trusted.
static size_t ply_vertex_count(const std::string& path) {
    FILE* f = std::fopen(path.c_str(), "rb"); if (!f) return (size_t)-1;
    char hdr[512] = {0}; const size_t n = std::fread(hdr, 1, sizeof hdr - 1, f); std::fclose(f); (void)n;
    const char* p = std::strstr(hdr, "element vertex "); if (!p) return (size_t)-1;
    return (size_t)std::strtoull(p + 15, nullptr, 10);
}
static void show(const char* name, const FusePackStats& s, const std::string& sha) {
    std::printf("%-12s frames %d points %-9zu photo %.17g geo %.17g final %.17g digest %016llx sha %s\n",
                name, s.frames, s.points, s.photo_frac, s.geo_frac, s.final_frac, (unsigned long long)s.digest, sha.c_str());
}
// Bit-exact: the fracs are float64 sums whose ORDER must not have changed, so compare the bits, not a tolerance.
static bool same_stats(const FusePackStats& a, const FusePackStats& b) {
    return a.frames == b.frames && a.points == b.points && a.digest == b.digest &&
           std::memcmp(&a.photo_frac, &b.photo_frac, 8) == 0 && std::memcmp(&a.geo_frac, &b.geo_frac, 8) == 0 &&
           std::memcmp(&a.final_frac, &b.final_frac, 8) == 0 && a.frame_digest == b.frame_digest;
}

int main(int argc, char** argv) {
    if (argc < 3) { std::fprintf(stderr, "usage: test_progressive <pack_dir> <out_dir> [--refs a-b] [--seed N] [--expect-sha HEX] [--box cx cy cz sx sy sz]\n"); return 1; }
    const std::string pack = argv[1], out = argv[2];
    int f0 = 0, f1 = -1; unsigned seed = 12345; std::string expect; bool neg = false;
    BoxFilter box{}; const BoxFilter* boxp = nullptr;
    for (int i = 3; i < argc; ++i) {
        const std::string a = argv[i];
        if (a == "--refs" && i + 1 < argc) { if (std::sscanf(argv[++i], "%d-%d", &f0, &f1) != 2) { std::fprintf(stderr, "bad --refs\n"); return 1; } }
        else if (a == "--seed" && i + 1 < argc) seed = (unsigned)std::strtoul(argv[++i], nullptr, 10);
        else if (a == "--expect-sha" && i + 1 < argc) expect = argv[++i];
        else if (a == "--neg-delivery-order") neg = true;
        else if (a == "--box" && i + 6 < argc) {
            for (int k = 0; k < 3; ++k) box.c[k] = std::atof(argv[++i]);
            for (int k = 0; k < 3; ++k) box.s[k] = std::atof(argv[++i]);
            for (int k = 0; k < 9; ++k) box.rot[k] = (k % 4 == 0) ? 1 : 0;
            boxp = &box;
        } else { std::fprintf(stderr, "unknown arg %s\n", a.c_str()); return 1; }
    }
    mkdir(out.c_str(), 0755);

    FusePack pk;
    if (!pk.open(pack)) { std::fprintf(stderr, "cannot open pack %s\n", pack.c_str()); return 2; }
    if (f1 < 0) f1 = pk.NF - 1;
    const int nref = f1 - f0 + 1;
    std::printf("pack %s: NF=%d W=%d H=%d NS=%d  refs %d-%d (%d)  box=%s  seed=%u\n",
                pack.c_str(), pk.NF, pk.W, pk.H, pk.NS, f0, f1, nref, boxp ? "yes" : "no", seed);

    // ---- arm 1: legacy fuse_pack -------------------------------------------------------------------------
    FusePackStats sA; const std::string plyA = out + "/legacy.ply";
    CHECK(fuse_pack(pack, f0, f1, plyA, nullptr, nullptr, &sA, boxp) == 0, "legacy fuse_pack failed");
    const std::string shaA = sha256_file(plyA);
    show("legacy", sA, shaA);

    // ---- arm 2: the split, driven in frame order ----------------------------------------------------------
    FusePackStats sB; const std::string plyB = out + "/perframe.ply";
    {
        FusePlyWriter w; CHECK(w.begin(plyB), "cannot open %s", plyB.c_str());
        double ph = 0, ge = 0, fi = 0; uint64_t hall = 1469598103934665603ULL;
        for (int f = f0; f <= f1; ++f) {
            FuseFrameResult r;
            CHECK(fuse_pack_frame(pk, f, boxp, r), "fuse_pack_frame(%d) failed", f);
            hall = fnv1a64(r.hs, sizeof r.hs, hall); sB.frame_digest.push_back(r.digest);
            w.append(r.xyz.data(), r.rgb.data(), r.points());
            ph += r.photo_frac; ge += r.geo_frac; fi += r.final_frac;
        }
        CHECK(w.finish(), "cannot finish %s", plyB.c_str());
        sB.frames = nref; sB.points = w.points(); sB.photo_frac = ph / nref; sB.geo_frac = ge / nref; sB.final_frac = fi / nref; sB.digest = hall;
    }
    const std::string shaB = sha256_file(plyB);
    show("perframe", sB, shaB);
    CHECK(shaB == shaA, "perframe PLY differs from legacy");
    CHECK(same_stats(sB, sA), "perframe stats differ from legacy");

    // ---- arm 3: the split, driven by a synthetic inference order ------------------------------------------
    // Every view the refs depend on has to be inferred; that union is exactly what dense_pipeline builds.
    std::vector<int> views;
    {
        std::vector<uint8_t> want(pk.NF, 0);
        for (int f = f0; f <= f1; ++f) { want[f] = 1; for (int j = 0; j < pk.NS; ++j) want[pk.nb[(size_t)f * pk.NS + j]] = 1; }
        for (int v = 0; v < pk.NF; ++v) if (want[v]) views.push_back(v);
    }
    const char* order_names[3] = {"ascending", "reverse", "shuffled"};
    for (int oi = 0; oi < 3; ++oi) {
        std::vector<int> ord = views;                                  // ascending == dense_pipeline's std::set order
        if (oi == 1) std::reverse(ord.begin(), ord.end());
        if (oi == 2) { std::mt19937 g(seed); std::shuffle(ord.begin(), ord.end(), g); }

        FuseScheduler sched(pk.nb, pk.NF, pk.NS, f0, f1);
        std::vector<uint8_t> inferred(pk.NF, 0);                       // independent of the scheduler's own bitmap
        std::vector<int> fused_count(nref, 0), delivery;
        std::vector<uint64_t> hs(nref * 5); std::vector<uint64_t> fd(nref);
        std::vector<double> ph(nref), ge(nref), fi(nref); std::vector<size_t> npt(nref);
        size_t chunk_total = 0;
        std::vector<int> ready;
        for (int v : ord) {
            inferred[v] = 1; sched.mark_inferred(v);
            sched.take_ready(ready);
            for (int f : ready) {
                // (b) the dependency contract, checked before we look at the data
                CHECK(inferred[f], "[%s] ref %d delivered before its own view was inferred", order_names[oi], f);
                for (int j = 0; j < pk.NS; ++j)
                    CHECK(inferred[pk.nb[(size_t)f * pk.NS + j]], "[%s] ref %d delivered before source view %d was inferred",
                          order_names[oi], f, pk.nb[(size_t)f * pk.NS + j]);
                FuseFrameResult r;
                CHECK(fuse_pack_frame(pk, f, boxp, r), "[%s] fuse_pack_frame(%d) failed", order_names[oi], f);
                const int i = f - f0;
                ++fused_count[i]; delivery.push_back(f);
                std::memcpy(&hs[(size_t)i * 5], r.hs, sizeof r.hs); fd[i] = r.digest;
                ph[i] = r.photo_frac; ge[i] = r.geo_frac; fi[i] = r.final_frac; npt[i] = r.points();
                chunk_total += r.points();                             // what the chunk callback would have seen
                char b[32]; std::snprintf(b, sizeof b, "/fused_%05d.bin", f);
                CHECK(fuse_spill_write(out + b, r.xyz, r.rgb), "[%s] spill of ref %d failed", order_names[oi], f);
            }
        }
        CHECK(sched.remaining() == 0, "[%s] %d refs never became fusable", order_names[oi], sched.remaining());
        for (int i = 0; i < nref; ++i) CHECK(fused_count[i] == 1, "[%s] ref %d fused %d times (want 1)", order_names[oi], f0 + i, fused_count[i]);

        // assemble in FRAME order out of the spill files
        FusePackStats sC; const std::string plyC = out + "/progressive_" + order_names[oi] + ".ply";
        FusePlyWriter w; CHECK(w.begin(plyC), "cannot open %s", plyC.c_str());
        double aph = 0, age = 0, afi = 0; uint64_t hall = 1469598103934665603ULL;
        std::vector<int> assembly; for (int f = f0; f <= f1; ++f) assembly.push_back(f);
        if (neg) assembly = delivery;                       // negative control: assemble as delivered
        for (int f : assembly) {
            const int i = f - f0;
            hall = fnv1a64(&hs[(size_t)i * 5], 5 * sizeof(uint64_t), hall); sC.frame_digest.push_back(fd[i]);
            char b[32]; std::snprintf(b, sizeof b, "/fused_%05d.bin", f);
            CHECK(fuse_spill_append(out + b, w), "[%s] cannot read spill of ref %d", order_names[oi], f);
            std::remove((out + b).c_str());
            aph += ph[i]; age += ge[i]; afi += fi[i];
        }
        CHECK(w.finish(), "cannot finish %s", plyC.c_str());
        sC.frames = nref; sC.points = w.points(); sC.photo_frac = aph / nref; sC.geo_frac = age / nref; sC.final_frac = afi / nref; sC.digest = hall;

        const std::string shaC = sha256_file(plyC);
        char nm[32]; std::snprintf(nm, sizeof nm, "prog/%s", order_names[oi]);
        show(nm, sC, shaC);
        std::vector<int> frame_order(delivery); std::sort(frame_order.begin(), frame_order.end());
        if (neg) {   // negative control: assembling as delivered MUST break the identity, or the gate is blind
            if (delivery == frame_order) std::printf("             [neg] delivery order == frame order, control not applicable\n");
            else {
                CHECK(shaC != shaA, "[%s] NEGATIVE CONTROL FAILED: delivery-order assembly still matches legacy", order_names[oi]);
                CHECK(!same_stats(sC, sA), "[%s] NEGATIVE CONTROL FAILED: delivery-order stats still match legacy", order_names[oi]);
            }
        } else {
            CHECK(shaC == shaA, "[%s] progressive PLY differs from legacy", order_names[oi]);
            CHECK(same_stats(sC, sA), "[%s] progressive stats differ from legacy", order_names[oi]);
        }
        // (c) delivered points add up to what the file says
        CHECK(chunk_total == ply_vertex_count(plyC), "[%s] chunk totals %zu != PLY vertex count %zu",
              order_names[oi], chunk_total, ply_vertex_count(plyC));
        // fusion order really was different from frame order (otherwise the arm proves nothing)
        std::printf("             delivery order %s frame order; first delivered %d, last %d; chunk points %zu\n",
                    delivery == frame_order ? "==" : "!=", delivery.empty() ? -1 : delivery.front(),
                    delivery.empty() ? -1 : delivery.back(), chunk_total);
    }

    if (!expect.empty()) CHECK(shaA == expect, "sha256 %s != expected %s", shaA.c_str(), expect.c_str());
    if (g_fail) std::printf("🔴 test_progressive: %d failure(s)\n", g_fail);
    else if (neg) std::printf("✅ test_progressive negative control: delivery-order assembly broke the identity, as it must\n");
    else std::printf("✅ test_progressive: all arms byte-identical\n");
    return g_fail ? 1 : 0;
}
