// dense_pipeline.cc — see dense_pipeline.h.
#include "dense_pipeline.h"

#include <sys/stat.h>

#include <algorithm>
#include <chrono>
#include <cmath>
#include <cstdio>
#include <cstring>
#include <set>

#include "dense_images.h"
#include "dense_inputs.h"
#include "dense_runner.h"

namespace aether::dense {

namespace {
using clk = std::chrono::steady_clock;
double ms_since(clk::time_point t) { return std::chrono::duration<double, std::milli>(clk::now() - t).count(); }

bool write_rows(const std::string& path, const void* data, size_t bytes, long offset) {
    FILE* f = std::fopen(path.c_str(), "r+b"); if (!f) return false;
    std::fseek(f, offset, SEEK_SET); const bool ok = std::fwrite(data, 1, bytes, f) == bytes; std::fclose(f); return ok;
}
// One reference frame's bookkeeping while its points sit in a spill file: enough to rebuild FusePackStats in
// frame order no matter which order the frames were fused in.
struct RefRecord { bool done = false; uint64_t hs[5] = {0, 0, 0, 0, 0}; uint64_t digest = 0; double ph = 0, ge = 0, fi = 0; size_t n = 0; };

bool create_zero_file(const std::string& path, size_t bytes) {
    FILE* f = std::fopen(path.c_str(), "wb"); if (!f) return false;
    const bool ok = bytes == 0 || (std::fseek(f, (long)bytes - 1, SEEK_SET) == 0 && std::fputc(0, f) != EOF);
    std::fclose(f); return ok;
}
}  // namespace

int dense_run(const DenseJob& job, dense_progress_fn progress, dense_chunk_fn chunk, void* user, DenseStats* st) {
    DenseStats scratch; DenseStats& S = st ? *st : scratch;
    if (job.frames.empty() || job.jpeg_paths.size() != job.frames.size() || job.points.size() % 3) { S.error = "bad job inputs"; return 2; }
    const int W = job.session.W, H = job.session.H, NS = job.session.nsrc, NV = NS + 1;
    const size_t N = (size_t)W * H, n2 = (size_t)(H / 4) * (W / 4), n3 = (size_t)(H / 2) * (W / 2);
    const long NP = (long)(job.points.size() / 3);

    // 1. session table on all frames; with a selection box, keep the frames that see the box and rebuild the
    //    table on that subset (the recipe itself is unchanged: view selection + depth range over the subset).
    auto t = clk::now();
    if (progress && progress("session", 0, 1, user)) return 1;
    std::vector<SessionFrame> frames = job.frames; std::vector<std::string> jpegs = job.jpeg_paths;
    std::vector<int> orig(frames.size()); for (size_t i = 0; i < orig.size(); ++i) orig[i] = (int)i;   // subset index -> job index
    SessionTable tab; build_session_table(frames, job.points, job.session, tab);
    S.NF = (int)job.frames.size(); S.frames_selected = S.NF;
    BoxFilter box{}; const BoxFilter* boxp = nullptr;
    if (job.has_box) {
        for (int k = 0; k < 3; ++k) { box.c[k] = job.box_c[k]; box.s[k] = job.box_s[k]; }
        for (int k = 0; k < 9; ++k) box.rot[k] = job.box_rot[k];
        boxp = &box;
        std::vector<uint8_t> inside(NP, 0);
        for (long n = 0; n < NP; ++n) inside[n] = box.contains(job.points[n * 3], job.points[n * 3 + 1], job.points[n * 3 + 2]);
        std::vector<int> keep;
        for (int i = 0; i < tab.NF; ++i) {
            const uint8_t* v = &tab.vis[(size_t)i * NP];
            for (long n = 0; n < NP; ++n) if (v[n] && inside[n]) { keep.push_back(i); break; }
        }
        if ((int)keep.size() >= NV) {
            std::vector<SessionFrame> f2; std::vector<std::string> j2; std::vector<int> o2;
            for (int i : keep) { f2.push_back(frames[i]); j2.push_back(jpegs[i]); o2.push_back(orig[i]); }
            frames.swap(f2); jpegs.swap(j2); orig.swap(o2);
            SessionTable t2; build_session_table(frames, job.points, job.session, t2); tab = std::move(t2);
        } else {
            S.box_fallback = true;   // too few frames see the box for a 1+nsrc tuple: run the whole set, still crop the output
        }
        S.frames_selected = (int)frames.size();
    }
    const int NF = (int)frames.size();
    S.session_ms = ms_since(t);
    if (progress && progress("session", 1, 1, user)) return 1;

    // which views: refs = [ref_begin, ref_end] within the (possibly subset) frame list; infer_set = refs ∪ nb(refs);
    // image_set = infer_set ∪ nb(infer_set)
    const int r0 = job.ref_begin, r1 = job.ref_end < 0 ? NF - 1 : std::min(job.ref_end, NF - 1);
    if (r0 < 0 || r0 > r1) { S.error = "bad ref range"; return 2; }
    std::set<int> infer, imgs;
    for (int f = r0; f <= r1; ++f) { infer.insert(f); for (int j = 0; j < NS; ++j) infer.insert(tab.neighbors[(size_t)f * NS + j]); }
    for (int v : infer) { imgs.insert(v); for (int j = 0; j < NS; ++j) imgs.insert(tab.neighbors[(size_t)v * NS + j]); }

    // 2. images: grey f16 bank for image_set, RGB kept for the pack (colours of inferred views)
    t = clk::now();
    std::vector<std::vector<uint16_t>> bank(NF);
    std::vector<std::vector<uint8_t>> rgb(NF);
    int done = 0;
    for (int v : imgs) {
        if (progress && progress("images", done, (int)imgs.size(), user)) return 1;
        RgbImage src, rs; std::vector<uint8_t> gray;
        if (!decode_jpeg_rgb_file(jpegs[v], src)) { S.error = "jpeg decode failed: " + jpegs[v]; return 2; }
        pil_resize_bilinear_rgb(src, W, H, rs);
        pil_rgb_to_l(rs, gray); gray_to_f16(gray, bank[v]);
        if (infer.count(v)) rgb[v] = std::move(rs.rgb);
        ++done;
    }
    S.images = done; S.images_ms = ms_since(t);

    // 3. pack on disk: local index = refs first (0..nref-1), then the other inferred views
    mkdir(job.work_dir.c_str(), 0755);
    std::vector<int> local; for (int f = r0; f <= r1; ++f) local.push_back(f);
    for (int v : infer) if (v < r0 || v > r1) local.push_back(v);
    std::vector<int> lidx(NF, -1); for (size_t i = 0; i < local.size(); ++i) lidx[local[i]] = (int)i;
    const int NL = (int)local.size();
    const std::string pack = job.work_dir;
    for (const char* nm : {"depth.f32", "conf0.f32", "conf1.f32", "conf2.f32"}) if (!create_zero_file(pack + "/" + nm, (size_t)NL * N * 4)) { S.error = "cannot create pack"; return 2; }
    {
        std::vector<uint8_t> rgbpack((size_t)NL * N * 3, 0); std::vector<float> campack((size_t)NL * 36); std::vector<int32_t> nbpack((size_t)NL * NS, 0);
        for (int i = 0; i < NL; ++i) {
            const int v = local[i];
            if (!rgb[v].empty()) std::copy(rgb[v].begin(), rgb[v].end(), rgbpack.begin() + (size_t)i * N * 3);
            std::copy(tab.cams.begin() + (size_t)v * 36, tab.cams.begin() + (size_t)(v + 1) * 36, campack.begin() + (size_t)i * 36);
            for (int j = 0; j < NS; ++j) { const int s = tab.neighbors[(size_t)v * NS + j]; nbpack[(size_t)i * NS + j] = lidx[s] >= 0 ? lidx[s] : 0; }
        }
        FILE* f;
        f = std::fopen((pack + "/rgb.u8").c_str(), "wb"); std::fwrite(rgbpack.data(), 1, rgbpack.size(), f); std::fclose(f);
        f = std::fopen((pack + "/cams.f32").c_str(), "wb"); std::fwrite(campack.data(), 4, campack.size(), f); std::fclose(f);
        f = std::fopen((pack + "/neighbors.i32").c_str(), "wb"); std::fwrite(nbpack.data(), 4, nbpack.size(), f); std::fclose(f);
        f = std::fopen((pack + "/meta.txt").c_str(), "w");
        std::fprintf(f, "%d %d %d %d %d %.9g %.9g %.9g %.9g %.9g\n", NL, W, H, NS, job.fuse.geo_mask_thres, job.fuse.geo_pixel_thres, job.fuse.geo_depth_thres,
                     job.fuse.photo_thres[0], job.fuse.photo_thres[1], job.fuse.photo_thres[2]);
        std::fclose(f);
    }

    // 4. inference, one view at a time, rows written straight into the pack. With a chunk callback every
    //    reference frame is fused and delivered the moment its ref view and all NS source views are inferred
    //    (FuseScheduler), so the app sees points long before the last view is done; the points are spilled to
    //    fused_<f>.bin and assembled in frame order in step 5, which is what makes out_ply identical.
    const int nref = r1 - r0 + 1;
    auto spill_path = [&](int f) { char b[32]; std::snprintf(b, sizeof b, "/fused_%05d.bin", f); return pack + b; };
    std::vector<RefRecord> rec(nref);
    FuseScheduler sched(tab.neighbors.data(), NF, NS, r0, r1);
    std::vector<int> ready;
    int nfused = 0; double fuse_ms = 0;
    // Fuses every ref the scheduler just released, delivers its chunk and spills it. rc: 0 ok, 1 cancel, 2/4 error.
    auto drain = [&](int& rc) {
        rc = 0; sched.take_ready(ready);
        if (ready.empty()) return true;
        const auto tf = clk::now();
        FusePack pk;   // fresh mapping: only a map created after the write is guaranteed to see the new rows
        if (!pk.open(pack)) { S.error = "cannot open pack"; rc = 2; return false; }
        for (int f : ready) {
            FuseFrameResult fr;
            if (!fuse_pack_frame(pk, f - r0, boxp, fr)) { S.error = "fusion failed on pack"; rc = 4; return false; }
            RefRecord& R = rec[f - r0];
            std::memcpy(R.hs, fr.hs, sizeof R.hs); R.digest = fr.digest;
            R.ph = fr.photo_frac; R.ge = fr.geo_frac; R.fi = fr.final_frac; R.n = fr.points(); R.done = true;
            if (!fuse_spill_write(spill_path(f), fr.xyz, fr.rgb)) { S.error = "cannot spill fused frame"; rc = 2; return false; }
            ++nfused;
            if (chunk(orig[f], fr.xyz.data(), fr.rgb.data(), (int)R.n, user)) { rc = 1; return false; }
            if (progress && progress("fuse", nfused, nref, user)) { rc = 1; return false; }
        }
        fuse_ms += ms_since(tf);
        return true;
    };

    {
        DenseRunner run; std::string err;
        if (!run.init(job.model_path, job.webgpu, W, H, NV, &err, &S.ort_session_ms)) { S.error = "ort init: " + err; return 3; }
        std::vector<float> imgbuf((size_t)NV * 3 * N), depth(N), c0(N), c1(N), c2(N), nz2, nz3, ms;
        done = 0;
        for (int v : infer) {
            if (progress && progress("infer", done, (int)infer.size(), user)) return 1;
            std::vector<int32_t> views{v}; for (int j = 0; j < NS; ++j) views.push_back(tab.neighbors[(size_t)v * NS + j]);
            for (int k = 0; k < NV; ++k) {
                const std::vector<uint16_t>& g = bank[views[k]];
                for (size_t i = 0; i < N; ++i) { const float fv = fp16_to_fp32(g[i]); for (int c = 0; c < 3; ++c) imgbuf[((size_t)k * 3 + c) * N + i] = fv; }
            }
            FrameInputs in; build_frame_inputs(tab.cams.data(), views, in);
            const float *p2, *p3;
            if (job.ext_noise) { p2 = job.ext_noise + (size_t)orig[v] * (n2 + n3); p3 = p2 + n2; }   // hooks are laid out per job frame
            else { make_noise(job.noise_seed, (int)frames[v].frame_id, n2, n3, nz2, nz3); p2 = nz2.data(); p3 = nz3.data(); }
            double dt = 0;
            if (!run.run(imgbuf.data(), in, p2, p3, depth.data(), c0.data(), c1.data(), c2.data(), &dt, &err)) { S.error = "ort run: " + err; return 3; }
            if (done > 0) ms.push_back(dt); S.infer_ms_total += dt;   // first view carries shader compile / warm-up
            const long off = (long)((size_t)lidx[v] * N * 4);
            if (!write_rows(pack + "/depth.f32", depth.data(), N * 4, off) || !write_rows(pack + "/conf0.f32", c0.data(), N * 4, off) ||
                !write_rows(pack + "/conf1.f32", c1.data(), N * 4, off) || !write_rows(pack + "/conf2.f32", c2.data(), N * 4, off)) { S.error = "pack write"; return 2; }
            if (job.ref_depth) {
                const float* rd = job.ref_depth + (size_t)orig[v] * N;
                for (size_t i = 0; i < N; ++i) {
                    if (!std::isfinite(depth[i])) { ++S.parity_nonfinite; continue; }
                    const double r = std::fabs(depth[i] - rd[i]) / std::max(rd[i], 1e-6f);
                    if (r > 0.01) ++S.parity_bad1;
                    S.parity_worst_rel = std::max(S.parity_worst_rel, r); ++S.parity_pixels;
                }
            }
            ++done;
            if (chunk) { sched.mark_inferred(v); int rc = 0; if (!drain(rc)) return rc; }
        }
        S.inferred = done;
        std::sort(ms.begin(), ms.end()); S.infer_ms_median = ms.empty() ? 0 : ms[ms.size() / 2];
        run.release();   // free the ~1.3 GB session before fusion touches the pack
    }
    if (progress && progress("infer", (int)infer.size(), (int)infer.size(), user)) return 1;

    // 5. fusion from the pack (refs are local 0..nref-1); the box crops the delivered points
    t = clk::now();
    if (!chunk) {   // pre-Stage-3 path, untouched
        const int rc = fuse_pack(pack, 0, r1 - r0, job.out_ply, progress, user, &S.fuse, boxp);
        S.fuse_ms = ms_since(t);
        if (rc == 1) return 1;
        if (rc != 0) { S.error = "fusion failed on pack"; return 4; }
        if (progress) progress("done", 1, 1, user);
        return 0;
    }
    { int rc = 0; if (!drain(rc)) return rc; }        // refs left over (a ref whose own view is its last dependency)
    for (int i = 0; i < nref; ++i) if (!rec[i].done) { S.error = "reference frame never became fusable"; return 4; }
    // assemble in FRAME order: the PLY bytes, the FNV fold and the frac sums are then exactly fuse_pack's
    FusePlyWriter ply;
    if (!ply.begin(job.out_ply)) { S.error = "cannot write ply"; return 4; }
    double ph = 0, ge = 0, fi = 0; uint64_t hall = 1469598103934665603ULL;
    S.fuse.frame_digest.clear();
    for (int f = r0; f <= r1; ++f) {
        const RefRecord& R = rec[f - r0];
        hall = fnv1a64(R.hs, sizeof R.hs, hall);
        S.fuse.frame_digest.push_back(R.digest);
        if (!fuse_spill_append(spill_path(f), ply)) { S.error = "cannot read spilled frame"; return 4; }
        std::remove(spill_path(f).c_str());
        ph += R.ph; ge += R.ge; fi += R.fi;
    }
    if (!ply.finish()) { S.error = "cannot write ply"; return 4; }
    S.fuse.frames = nref; S.fuse.points = ply.points();
    S.fuse.photo_frac = ph / nref; S.fuse.geo_frac = ge / nref; S.fuse.final_frac = fi / nref; S.fuse.digest = hall;
    S.fuse_ms = fuse_ms + ms_since(t);
    if (progress) progress("done", 1, 1, user);
    return 0;
}

}  // namespace aether::dense
