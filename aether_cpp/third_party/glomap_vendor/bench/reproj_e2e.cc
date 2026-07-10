// reproj_e2e.cc — dual-track end-to-end reprojection gate (M2-3 final).
//
// The authoritative M2 gate. Builds TWO COLMAP databases from the SAME 50-frame
// real capture trajectory — one with GPU-pipeline features (fo=0), one with the
// CPU _threaded(fo=0) baseline — runs exhaustive matching + geometric
// verification + incremental SfM on each, and compares registered frames + mean
// reprojection error.
//
// Fixture: the curated 50-frame set in db50_4224_8192_nodesc.db (cameras / rigs /
// frames / image list already wired for COLMAP 4.0.4). We COPY that db's
// structure, CLEAR its keypoints/descriptors/matches/two-view-geometries, then
// re-populate from each track's extraction. The source frames live in
// cap_1779949415373229/photos_highres (all 50 present).
//
// Gate: GPU track registered ≈ CPU baseline (ideally all 50) AND GPU reproj
// comparable to CPU (≤~0.933 magnitude). Divergence → attribution, not hand-wave.
//
// Build: reproj_e2e_exe. Run: <template.db> <image_dir> <work_dir>

#include <algorithm>
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <filesystem>
#include <string>
#include <vector>

#define STB_IMAGE_IMPLEMENTATION
#include "stb_image.h"

#include "colmap/controllers/incremental_pipeline.h"
#include "colmap/estimators/two_view_geometry.h"
#include "colmap/feature/matcher.h"
#include "colmap/feature/sift.h"
#include "colmap/feature/types.h"
#include "colmap/scene/camera.h"
#include "colmap/scene/database.h"
#include "colmap/scene/reconstruction.h"
#include "colmap/scene/reconstruction_manager.h"
#include "colmap/scene/two_view_geometry.h"
#include "colmap/util/types.h"

#include <glog/logging.h>

extern "C" {
int aether_dsp_sift_extract_gpu(const uint8_t*, int, int, int, int, float*,
                                uint8_t*, int, int*);
int aether_dsp_sift_extract_threaded_fo(const uint8_t*, int, int, int, int, int,
                                        float*, uint8_t*, int, int*);
}

namespace fs = std::filesystem;

namespace {

// Load a JPEG as grayscale (row-major), matching the extractor's input contract.
bool load_gray(const std::string& path, std::vector<uint8_t>& gray, int& w,
               int& h) {
    int ch = 0;
    uint8_t* d = stbi_load(path.c_str(), &w, &h, &ch, 1);
    if (!d) return false;
    gray.assign(d, d + static_cast<size_t>(w) * h);
    stbi_image_free(d);
    return true;
}

// One image's extracted features (kept in memory for matching).
struct ImgFeat {
    colmap::image_t image_id;
    colmap::camera_t camera_id;
    std::vector<Eigen::Vector2d> points;  // x,y
    std::shared_ptr<colmap::FeatureDescriptors> desc;  // u8, SIFT type
};

// Extract every image's features into `db` (keypoints+descriptors) AND return
// them in memory for the matching step. gpu=1 → GPU pipeline, else CPU fo=0.
long populate_features(colmap::Database& db, const std::string& image_dir, int gpu,
                       int max_features, std::vector<ImgFeat>* feats) {
    db.ClearTwoViewGeometries();
    db.ClearMatches();
    db.ClearDescriptors();
    db.ClearKeypoints();

    const std::vector<colmap::Image> images = db.ReadAllImages();
    const int cap = max_features;
    std::vector<float> xy(static_cast<size_t>(2) * cap);
    std::vector<uint8_t> desc(static_cast<size_t>(128) * cap);
    long total = 0;
    feats->clear();
    feats->reserve(images.size());

    for (const colmap::Image& img : images) {
        const std::string path = (fs::path(image_dir) / img.Name()).string();
        std::vector<uint8_t> gray;
        int w = 0, h = 0;
        if (!load_gray(path, gray, w, h)) {
            std::fprintf(stderr, "[reproj_e2e] cannot load %s\n", path.c_str());
            return -1;
        }
        int n = 0;
        int r = gpu ? aether_dsp_sift_extract_gpu(gray.data(), w, h, max_features,
                                                  0, xy.data(), desc.data(), cap, &n)
                    : aether_dsp_sift_extract_threaded_fo(gray.data(), w, h,
                                                          max_features, 0, 0,
                                                          xy.data(), desc.data(),
                                                          cap, &n);
        if (r != 0) {
            std::fprintf(stderr, "[reproj_e2e] extract failed (%d) on %s\n", r,
                         img.Name().c_str());
            return -1;
        }

        colmap::FeatureKeypoints kps(n);
        ImgFeat f;
        f.image_id = img.ImageId();
        f.camera_id = img.CameraId();
        f.points.resize(n);
        for (int i = 0; i < n; ++i) {
            kps[i] = colmap::FeatureKeypoint(xy[2 * i], xy[2 * i + 1]);
            f.points[i] = Eigen::Vector2d(xy[2 * i], xy[2 * i + 1]);
        }
        f.desc = std::make_shared<colmap::FeatureDescriptors>();
        f.desc->type = colmap::FeatureExtractorType::SIFT;
        f.desc->data.resize(n, 128);
        std::memcpy(f.desc->data.data(), desc.data(),
                    static_cast<size_t>(n) * 128);

        db.WriteKeypoints(img.ImageId(), kps);
        db.WriteDescriptors(img.ImageId(), *f.desc);
        feats->push_back(std::move(f));
        total += n;
    }
    return total;
}

// Re-match only the `pairs` (the template's established verified pairs — the
// curated trajectory's overlap graph) with this track's descriptors, writing
// matches + two-view geometry. Uses colmap's CPU SIFT brute-force matcher (same
// as aether_sift_match) + EstimateTwoViewGeometry (F/E/H RANSAC, defaults). This
// holds the OVERLAP GRAPH fixed across the GPU/CPU tracks (apples-to-apples:
// only the features differ), which is exactly what we want to compare.
int run_matching(colmap::Database& db, const std::vector<ImgFeat>& feats,
                 const std::vector<std::pair<colmap::image_t, colmap::image_t>>& pairs) {
    colmap::FeatureMatchingOptions mopts(colmap::FeatureMatcherType::SIFT_BRUTEFORCE);
    mopts.sift = std::make_shared<colmap::SiftMatchingOptions>();
    mopts.sift->cpu_brute_force_matcher = true;
    mopts.use_gpu = false;
    std::unique_ptr<colmap::FeatureMatcher> matcher =
        colmap::CreateSiftFeatureMatcher(mopts);
    colmap::TwoViewGeometryOptions gopts;

    // index features by image_id.
    std::vector<const ImgFeat*> by_id(feats.size() ? 0 : 0);
    std::vector<const ImgFeat*> id_map;
    colmap::image_t max_id = 0;
    for (const auto& f : feats) max_id = std::max(max_id, f.image_id);
    id_map.assign(max_id + 1, nullptr);
    for (const auto& f : feats) id_map[f.image_id] = &f;

    int written = 0;
    for (const auto& pr : pairs) {
        const ImgFeat* a = (pr.first <= max_id) ? id_map[pr.first] : nullptr;
        const ImgFeat* b = (pr.second <= max_id) ? id_map[pr.second] : nullptr;
        if (!a || !b) continue;
        colmap::FeatureMatcher::Image mi, mj;
        mi.image_id = a->image_id; mi.descriptors = a->desc;
        mj.image_id = b->image_id; mj.descriptors = b->desc;
        colmap::FeatureMatches matches;
        matcher->Match(mi, mj, &matches);
        if (matches.size() < 15) continue;
        const colmap::Camera cam_i = db.ReadCamera(a->camera_id);
        const colmap::Camera cam_j = db.ReadCamera(b->camera_id);
        colmap::TwoViewGeometry tvg = colmap::EstimateTwoViewGeometry(
            cam_i, a->points, cam_j, b->points, matches, gopts);
        if (tvg.inlier_matches.size() < 15) continue;
        db.WriteMatches(a->image_id, b->image_id, matches);
        db.WriteTwoViewGeometry(a->image_id, b->image_id, tvg);
        ++written;
    }
    return written;
}

// Run incremental SfM, return (registered, reproj) of the largest model.
void run_sfm(const std::string& db_path, const std::string& image_dir,
             int* out_reg, double* out_reproj, int* out_models, int* out_pts) {
    auto options = std::make_shared<colmap::IncrementalPipelineOptions>();
    options->min_num_matches = 15;
    options->image_path = image_dir;
    auto mgr = std::make_shared<colmap::ReconstructionManager>();
    colmap::IncrementalPipeline pipeline(options, colmap::Database::Open(db_path),
                                         mgr);
    pipeline.Run();
    size_t best_reg = 0, best_pts = 0;
    double best_reproj = 0.0;
    for (size_t i = 0; i < mgr->Size(); ++i) {
        const auto& r = mgr->Get(i);
        if (r->NumRegImages() > best_reg) {
            best_reg = r->NumRegImages();
            best_pts = r->NumPoints3D();
            best_reproj = r->ComputeMeanReprojectionError();
        }
    }
    *out_reg = static_cast<int>(best_reg);
    *out_reproj = best_reproj;
    *out_models = static_cast<int>(mgr->Size());
    *out_pts = static_cast<int>(best_pts);
}

// Build a track's db from the template, then matching + SfM. Returns true on ok.
bool run_track(const std::string& tmpl_db, const std::string& image_dir,
               const std::string& work_db, int gpu, int max_features,
               int* reg, double* reproj, int* models, int* pts, long* kps) {
    // The template must be a self-contained (checkpointed, journal_mode=DELETE)
    // db so the copy isn't a mid-WAL malformed image. Remove stale work sidecars.
    for (const char* ext : {"-wal", "-shm"}) {
        std::error_code ec;
        fs::remove(fs::path(work_db + std::string(ext)), ec);
    }
    fs::copy_file(tmpl_db, work_db, fs::copy_options::overwrite_existing);
    {
        std::shared_ptr<colmap::Database> db = colmap::Database::Open(work_db);
        // capture the template's verified overlap graph BEFORE clearing.
        std::vector<std::pair<colmap::image_t, colmap::image_t>> pairs;
        for (const auto& tv : db->ReadTwoViewGeometries())
            pairs.push_back(colmap::PairIdToImagePair(tv.first));
        std::vector<ImgFeat> feats;
        *kps = populate_features(*db, image_dir, gpu, max_features, &feats);
        if (*kps < 0) return false;
        int nm = run_matching(*db, feats, pairs);
        std::printf("[reproj_e2e]   re-matched %d / %zu template pairs\n", nm, pairs.size());
    }  // close db before the SfM pipeline reopens it
    run_sfm(work_db, image_dir, reg, reproj, models, pts);
    return true;
}

}  // namespace

int main(int argc, char** argv) {
    setvbuf(stdout, nullptr, _IOLBF, 0);  // line-buffer so progress is visible
    google::InitGoogleLogging(argv[0]);
    if (argc < 4) {
        std::fprintf(stderr, "usage: %s <template.db> <image_dir> <work_dir> [max_features]\n",
                     argv[0]);
        return 2;
    }
    const std::string tmpl = argv[1];
    const std::string image_dir = argv[2];
    const std::string work_dir = argv[3];
    const int max_features = argc > 4 ? std::atoi(argv[4]) : 8192;
    fs::create_directories(work_dir);

    const int n_images =
        static_cast<int>(colmap::Database::Open(tmpl)->ReadAllImages().size());
    std::printf("[reproj_e2e] template=%s  images=%d  max_features=%d\n",
                tmpl.c_str(), n_images, max_features);

    // ── CPU baseline track (fo=0) ──
    int c_reg = 0, c_models = 0, c_pts = 0; double c_reproj = 0; long c_kps = 0;
    std::printf("[reproj_e2e] === CPU track (fo=0) ===\n");
    if (!run_track(tmpl, image_dir, (fs::path(work_dir) / "cpu.db").string(), 0,
                   max_features, &c_reg, &c_reproj, &c_models, &c_pts, &c_kps)) {
        std::printf("FAIL CPU track\n");
        return 1;
    }
    std::printf("[reproj_e2e] CPU: kps=%ld  models=%d  registered=%d/%d  pts=%d  reproj=%.4f\n",
                c_kps, c_models, c_reg, n_images, c_pts, c_reproj);

    // ── GPU pipeline track (fo=0) ──
    int g_reg = 0, g_models = 0, g_pts = 0; double g_reproj = 0; long g_kps = 0;
    std::printf("[reproj_e2e] === GPU track (fo=0) ===\n");
    if (!run_track(tmpl, image_dir, (fs::path(work_dir) / "gpu.db").string(), 1,
                   max_features, &g_reg, &g_reproj, &g_models, &g_pts, &g_kps)) {
        std::printf("FAIL GPU track\n");
        return 1;
    }
    std::printf("[reproj_e2e] GPU: kps=%ld  models=%d  registered=%d/%d  pts=%d  reproj=%.4f\n",
                g_kps, g_models, g_reg, n_images, g_pts, g_reproj);

    // ── compare ──
    std::printf("\n[reproj_e2e] ===== RESULT =====\n");
    std::printf("  track   registered   reproj_px   pts3d\n");
    std::printf("  CPU     %d/%d        %.4f      %d\n", c_reg, n_images, c_reproj, c_pts);
    std::printf("  GPU     %d/%d        %.4f      %d\n", g_reg, n_images, g_reproj, g_pts);

    // Gate: GPU registers ≈ CPU (within 1 frame) AND reproj within 10% (or both
    // under a generous absolute floor). The CPU track IS the apples-to-apples
    // reference (same fo, same SfM config), so "comparable to CPU" is the bar.
    const bool reg_ok = g_reg >= c_reg - 1 && g_reg >= n_images - 1;
    const bool reproj_ok =
        g_reproj <= c_reproj * 1.10 + 0.05 || g_reproj <= 1.0;
    const bool pass = reg_ok && reproj_ok;
    std::printf("%s M2-3 dual-track reproj (reg_ok=%d reproj_ok=%d)\n",
                pass ? "PASS" : "FAIL", reg_ok, reproj_ok);
    return pass ? 0 : 1;
}
