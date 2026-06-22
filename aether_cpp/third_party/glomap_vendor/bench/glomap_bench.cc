// glomap_bench.cc — on-device benchmark of GLOMAP's global-mapper core
// (rotation averaging + global positioning + global BA). Feeds a COLMAP
// database (db_50.db), runs GlobalMapper::Solve, reports per-stage + total
// wall time and reconstruction size. C ABI for Dart FFI; main() for standalone.

#include "colmap/scene/database.h"
#include "colmap/util/timer.h"

#include "glomap/controllers/global_mapper.h"
#include "glomap/io/colmap_converter.h"
#include "glomap/scene/types.h"

#include <glog/logging.h>

#include <chrono>
#include <cstdio>
#include <cstring>
#include <string>
#include <unordered_map>

namespace glomap {
// ---- stub: retriangulation is skipped on-device (needs colmap incremental
// triangulator, excluded from the iOS subset). skip_retriangulation=true means
// this is never called at runtime; the definition only satisfies the linker. ----
bool RetriangulateTracks(const TriangulatorOptions&,
                         const colmap::Database&,
                         std::unordered_map<rig_t, Rig>&,
                         std::unordered_map<camera_t, Camera>&,
                         std::unordered_map<frame_t, Frame>&,
                         std::unordered_map<image_t, Image>&,
                         std::unordered_map<track_t, Track>&) {
  LOG(WARNING) << "RetriangulateTracks stub called (should be skipped)";
  return true;
}
}  // namespace glomap

static double NowMs() {
  using namespace std::chrono;
  return duration<double, std::milli>(steady_clock::now().time_since_epoch())
      .count();
}

extern "C" int glomap_bench(const char* db_path, char* out_json, int out_cap) {
  using namespace glomap;
  try {
    const double t_load0 = NowMs();
    auto database = colmap::Database::Open(db_path);

    ViewGraph view_graph;
    std::unordered_map<rig_t, Rig> rigs;
    std::unordered_map<camera_t, Camera> cameras;
    std::unordered_map<frame_t, Frame> frames;
    std::unordered_map<image_t, Image> images;
    std::unordered_map<track_t, Track> tracks;

    ConvertDatabaseToGlomap(*database, view_graph, rigs, cameras, frames,
                            images);
    const double t_load_ms = NowMs() - t_load0;
    const size_t n_pairs = view_graph.image_pairs.size();

    if (view_graph.image_pairs.empty()) {
      std::snprintf(out_json, out_cap, "{\"error\":\"no image pairs\"}");
      return 1;
    }

    GlobalMapperOptions options;
    options.skip_retriangulation = true;  // core = RA + GP + BA only
    options.skip_pruning = true;
    GlobalMapper global_mapper(options);

    const double t_solve0 = NowMs();
    global_mapper.Solve(*database, view_graph, rigs, cameras, frames, images,
                        tracks);
    const double t_solve_ms = NowMs() - t_solve0;

    size_t n_reg = 0;
    for (const auto& [id, img] : images)
      if (img.IsRegistered()) ++n_reg;

    std::snprintf(out_json, out_cap,
                  "{\"db_load_ms\":%.1f,\"solve_ms\":%.1f,\"n_images\":%zu,"
                  "\"n_registered\":%zu,\"n_pairs\":%zu,\"n_tracks\":%zu,"
                  "\"n_cameras\":%zu}",
                  t_load_ms, t_solve_ms, images.size(), n_reg, n_pairs,
                  tracks.size(), cameras.size());
    return 0;
  } catch (const std::exception& e) {
    std::snprintf(out_json, out_cap, "{\"error\":\"%s\"}", e.what());
    return 2;
  }
}

#ifdef GLOMAP_BENCH_MAIN
int main(int argc, char** argv) {
  google::InitGoogleLogging(argv[0]);
  FLAGS_logtostderr = 1;
  FLAGS_minloglevel = 0;
  if (argc < 2) {
    std::fprintf(stderr, "usage: %s <db_path>\n", argv[0]);
    return 1;
  }
  char out[1024] = {0};
  const int rc = glomap_bench(argv[1], out, sizeof(out));
  std::printf("RESULT %s\n", out);
  return rc;
}
#endif
