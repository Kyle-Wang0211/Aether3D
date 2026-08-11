#include "aether_sfm_c.h"
#include "official_preclamp_instr_v1.h"

#include <algorithm>
#include <atomic>
#include <cassert>
#include <cmath>
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <string>
#include <thread>
#include <utility>
#include <vector>

#include <unistd.h>
#include <sqlite3.h>

#if defined(NDEBUG)
#error "preclamp production integration requires active runtime assertions"
#endif

extern "C" void aether_preclamp_instr_force_next_gpu_fallback_for_test();

// The official session imports the product's Metal matcher weakly. Mach-O
// host executables still need concrete definitions at final link, so this
// test target supplies fail-closed platform stubs; extraction remains the real
// Dawn path and no CPU matching fallback is opened.
extern "C" int aether_gpu_match_gemm_pairs(
    const uint8_t*, int, const uint8_t*, int, double, uint32_t*, int,
    int* out_num_matches) {
  if (out_num_matches != nullptr) *out_num_matches = 0;
  return 1;
}
extern "C" int aether_gpu_match_gemm_pairs_resident(
    uint64_t, uint32_t, uint32_t, const uint8_t*, int, uint32_t, uint32_t,
    const uint8_t*, int, double, uint32_t*, int, int* out_num_matches) {
  if (out_num_matches != nullptr) *out_num_matches = 0;
  return 1;
}
extern "C" int aether_gpu_match_gemm_pairs_guided(
    const uint8_t*, int, const float*, const uint8_t*, int, const float*,
    double, const float*, const float*, int, float, uint32_t*, int,
    int* out_num_matches) {
  if (out_num_matches != nullptr) *out_num_matches = 0;
  return 1;
}
extern "C" void aether_gpu_match_descriptor_residency_invalidate(uint64_t,
                                                                  uint32_t) {}
extern "C" void aether_gpu_match_descriptor_residency_clear_session(uint64_t) {}
extern "C" int aether_gpu_match_descriptor_residency_stats(
    uint64_t, uint64_t* hits, uint64_t* misses, uint64_t* evictions,
    uint64_t* stale_replacements, uint64_t* upload_bytes,
    uint64_t* resident_bytes, uint64_t* resident_entries,
    uint64_t* allocation_failures, uint64_t* device_resets) {
  uint64_t* outputs[] = {hits, misses, evictions, stale_replacements,
                         upload_bytes, resident_bytes, resident_entries,
                         allocation_failures, device_resets};
  for (uint64_t* output : outputs) {
    if (output != nullptr) *output = 0;
  }
  return 0;
}
extern "C" int aether_gpu_match_last_error(char*, int) { return 0; }

namespace {

struct SessionFixture {
  aether_sfm_session_t* session = nullptr;
  std::string db_path;

  SessionFixture() = default;
  SessionFixture(const SessionFixture&) = delete;
  SessionFixture& operator=(const SessionFixture&) = delete;
  SessionFixture(SessionFixture&& other) noexcept
      : session(other.session), db_path(std::move(other.db_path)) {
    other.session = nullptr;
    other.db_path.clear();
  }

  ~SessionFixture() {
    if (session != nullptr) aether_sfm_free(session);
    if (!db_path.empty()) {
      std::remove(db_path.c_str());
      std::remove((db_path + "-wal").c_str());
      std::remove((db_path + "-shm").c_str());
    }
  }
};

std::vector<uint8_t> MakeSynthetic(int width, int height) {
  std::vector<uint8_t> image(static_cast<size_t>(width) * height);
  uint64_t state = 0x9e3779b97f4a7c15ull;
  for (int y = 0; y < height; ++y) {
    for (int x = 0; x < width; ++x) {
      state ^= state << 13;
      state ^= state >> 7;
      state ^= state << 17;
      const double noise = static_cast<double>(state >> 57) - 32.0;
      const double value =
          128 + 60 * std::sin(x * 0.06) * std::sin(y * 0.045) +
          45 * std::sin((x + y) * 0.19) +
          40 * std::sin(x * 0.31) * std::cos(y * 0.29) +
          30 * std::cos(x * 0.013 - y * 0.011) + noise;
      image[static_cast<size_t>(y) * width + x] =
          static_cast<uint8_t>(std::min(255.0, std::max(0.0, value)));
    }
  }
  return image;
}

SessionFixture CreateSession(const char* label, int max_features) {
  static std::atomic<uint32_t> sequence{0};
  SessionFixture fixture;
  fixture.db_path = "/private/tmp/preclamp-prod-" +
                    std::to_string(static_cast<long long>(getpid())) + "-" +
                    label + "-" + std::to_string(sequence++) + ".db";
  std::remove(fixture.db_path.c_str());
  aether_sfm_options_t options;
  aether_sfm_options_default(&options);
  options.max_features = max_features;
  options.k_neighbors = 1;
  options.use_gpu_extract = 1;
  // The host target has no production Metal matcher. Keeping this route on
  // makes missing matcher work fail closed instead of opening CPU O(N^2).
  options.use_gpu_match = 1;
  const aether_sfm_result_t rc =
      aether_sfm_create(fixture.db_path.c_str(), &options, &fixture.session);
  assert(rc == AETHER_SFM_OK);
  assert(fixture.session != nullptr);
  return fixture;
}

int AddFrame(SessionFixture* fixture, const std::vector<uint8_t>& gray,
             int width, int height, double tx = 0.0) {
  const double q[4] = {1.0, 0.0, 0.0, 0.0};
  const double t[3] = {tx, 0.0, 0.0};
  int frame_id = -1;
  const aether_sfm_result_t rc = aether_sfm_add_frame(
      fixture->session, gray.data(), width, height,
      0.8f * width, 0.8f * width, 0.5f * width, 0.5f * height,
      q, t, &frame_id);
  assert(rc == AETHER_SFM_OK);
  return frame_id;
}

std::vector<aether_preclamp_instr_v1::FrameCounts> ReadRows(
    const SessionFixture& fixture) {
  std::vector<aether_preclamp_instr_v1::FrameCounts> rows;
  assert(aether_preclamp_instr_v1::CopyOfficialSessionRecords(
      fixture.session, &rows));
  return rows;
}

int ReadFirstFeatureRows(const std::string& db_path, const char* table) {
  sqlite3* db = nullptr;
  assert(sqlite3_open_v2(db_path.c_str(), &db, SQLITE_OPEN_READONLY,
                         nullptr) == SQLITE_OK);
  const std::string sql =
      std::string("SELECT rows FROM ") + table + " ORDER BY image_id LIMIT 1";
  sqlite3_stmt* statement = nullptr;
  assert(sqlite3_prepare_v2(db, sql.c_str(), -1, &statement, nullptr) ==
         SQLITE_OK);
  assert(sqlite3_step(statement) == SQLITE_ROW);
  const int rows = sqlite3_column_int(statement, 0);
  sqlite3_finalize(statement);
  sqlite3_close(db);
  return rows;
}

void ExpectNoRows(const SessionFixture& fixture) {
  assert(ReadRows(fixture).empty());
}

int Overshoot() {
  unsetenv("OFFICIAL_AETHER_FEATURE_SELECTION_POLICY");
  const int width = 2400;
  const int height = 1800;
  const std::vector<uint8_t> gray = MakeSynthetic(width, height);
  SessionFixture fixture = CreateSession("overshoot", 8192);
  assert(AddFrame(&fixture, gray, width, height) == 0);
  const auto rows = ReadRows(fixture);
  assert(rows.size() == 1);
  assert(rows[0].frame_id == 0);
  assert(rows[0].frame_ordinal == 1);
  assert(rows[0].legacy_count == 16570);
  assert(rows[0].descriptor_rows == 16570);
  assert(rows[0].strict_shadow_count == 8192);
  assert(rows[0].overflow_group_size == 8378);
  assert(ReadFirstFeatureRows(fixture.db_path, "keypoints") == 8192);
  assert(ReadFirstFeatureRows(fixture.db_path, "descriptors") == 8192);
  std::vector<aether_preclamp_instr_v1::FrameCounts> drained;
  assert(aether_preclamp_instr_v1::DrainOfficialSessionRecords(
      fixture.session, &drained));
  assert(drained.size() == 1);
  assert(ReadRows(fixture).empty());
  std::puts("PASS actual extractor/GPU/session overshoot 16570->8192");
  return 0;
}

int Isolation() {
  unsetenv("OFFICIAL_AETHER_FEATURE_SELECTION_POLICY");
  const int width = 800;
  const int height = 600;
  const std::vector<uint8_t> gray = MakeSynthetic(width, height);

  SessionFixture first = CreateSession("sequential-a", 256);
  SessionFixture second = CreateSession("sequential-b", 256);
  assert(AddFrame(&first, gray, width, height) == 0);
  assert(AddFrame(&second, gray, width, height) == 0);
  const auto first_rows = ReadRows(first);
  const auto second_rows = ReadRows(second);
  assert(first_rows.size() == 1 && first_rows[0].frame_id == 0);
  assert(second_rows.size() == 1 && second_rows[0].frame_id == 0);

  SessionFixture shared = CreateSession("cross-thread", 256);
  int first_id = -1;
  int second_id = -1;
  std::thread worker_a([&] {
    first_id = AddFrame(&shared, gray, width, height, 0.0);
  });
  worker_a.join();
  std::thread worker_b([&] {
    second_id = AddFrame(&shared, gray, width, height, 0.05);
  });
  worker_b.join();
  assert(first_id == 0 && second_id == 1);
  auto shared_rows = ReadRows(shared);
  assert(shared_rows.size() == 2);
  std::sort(shared_rows.begin(), shared_rows.end(),
            [](const auto& lhs, const auto& rhs) {
              return lhs.frame_id < rhs.frame_id;
            });
  assert(shared_rows[0].frame_id == 0 &&
         shared_rows[0].frame_ordinal == 1);
  assert(shared_rows[1].frame_id == 1 &&
         shared_rows[1].frame_ordinal == 2);
  std::puts("PASS actual session isolation and serialized cross-thread calls");
  return 0;
}

int Fallback() {
  unsetenv("OFFICIAL_AETHER_FEATURE_SELECTION_POLICY");
  const int width = 800;
  const int height = 600;
  const std::vector<uint8_t> gray = MakeSynthetic(width, height);
  SessionFixture fixture = CreateSession("fallback", 256);
  aether_preclamp_instr_force_next_gpu_fallback_for_test();
  assert(AddFrame(&fixture, gray, width, height) == 0);
  ExpectNoRows(fixture);
  std::puts("PASS actual GPU C-entry fallback publishes no row");
  return 0;
}

int Canonical() {
  setenv("OFFICIAL_AETHER_FEATURE_SELECTION_POLICY",
         "canonical_exact_8192_v1", 1);
  const int width = 800;
  const int height = 600;
  const std::vector<uint8_t> gray = MakeSynthetic(width, height);
  SessionFixture fixture = CreateSession("canonical", 256);
  assert(AddFrame(&fixture, gray, width, height) == 0);
  ExpectNoRows(fixture);
  std::puts("PASS actual canonical route publishes no legacy row");
  return 0;
}

int Zero() {
  unsetenv("OFFICIAL_AETHER_FEATURE_SELECTION_POLICY");
  const int width = 64;
  const int height = 64;
  const std::vector<uint8_t> gray(static_cast<size_t>(width) * height, 127);
  SessionFixture fixture = CreateSession("zero", 256);
  int frame_id = -1;
  const aether_sfm_result_t rc = aether_sfm_add_frame(
      fixture.session, gray.data(), width, height, 50.0f, 50.0f, 32.0f,
      32.0f, nullptr, nullptr, &frame_id);
  assert(rc == AETHER_SFM_ERR_EXTRACT);
  assert(frame_id == -1);
  ExpectNoRows(fixture);
  std::puts("PASS actual zero-feature route publishes no row");
  return 0;
}

int Reject() {
  unsetenv("OFFICIAL_AETHER_FEATURE_SELECTION_POLICY");
  SessionFixture fixture = CreateSession("reject", 256);
  int frame_id = -1;
  const aether_sfm_result_t rc = aether_sfm_add_frame(
      fixture.session, nullptr, 800, 600, 640.0f, 640.0f, 400.0f, 300.0f,
      nullptr, nullptr, &frame_id);
  assert(rc == AETHER_SFM_ERR_INVALID_ARG);
  ExpectNoRows(fixture);
  std::puts("PASS actual rejected session call publishes no row");
  return 0;
}

}  // namespace

int main(int argc, char** argv) {
  setenv("OFFICIAL_AETHER_PRECLAMP_INSTR_V1", "1", 1);
  setenv("SED_TIMING", "1", 1);
  if (argc != 2) return 2;
  if (std::strcmp(argv[1], "overshoot") == 0) return Overshoot();
  if (std::strcmp(argv[1], "isolation") == 0) return Isolation();
  if (std::strcmp(argv[1], "fallback") == 0) return Fallback();
  if (std::strcmp(argv[1], "canonical") == 0) return Canonical();
  if (std::strcmp(argv[1], "zero") == 0) return Zero();
  if (std::strcmp(argv[1], "reject") == 0) return Reject();
  return 2;
}
