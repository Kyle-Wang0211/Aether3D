#include <fstream>
#include <iostream>
#include <sstream>
#include <string>

namespace {

std::string Read(const std::string& path) {
  std::ifstream stream(path);
  std::ostringstream contents;
  contents << stream.rdbuf();
  return contents.str();
}

int Fail(const std::string& message) {
  std::cerr << "FAIL: " << message << '\n';
  return 1;
}

bool ContainsAfter(const std::string& text,
                   const std::string& first,
                   const std::string& second,
                   std::size_t window) {
  std::size_t pos = 0;
  while ((pos = text.find(first, pos)) != std::string::npos) {
    const std::size_t second_pos = text.find(second, pos + first.size());
    if (second_pos == std::string::npos || second_pos - pos > window) {
      return false;
    }
    pos += first.size();
  }
  return true;
}

std::size_t Count(const std::string& text, const std::string& needle) {
  std::size_t count = 0;
  std::size_t pos = 0;
  while ((pos = text.find(needle, pos)) != std::string::npos) {
    ++count;
    pos += needle.size();
  }
  return count;
}

}  // namespace

int main(int argc, char** argv) {
  if (argc != 2) return Fail("expected official_pipeline directory argument");
  const std::string root = argv[1];
  const std::string bundle =
      Read(root + "/src/official_bundle_adjustment_ceres.cc");
  const std::string sfm = Read(root + "/src/official_aether_sfm_c.cc");
  const std::string pipeline =
      Read(root + "/src/official_incremental_pipeline.cc");
  const std::string policy =
      Read(root + "/src/aether_ba_solve_policy_v1.h");
  const std::string policy_test =
      Read(root + "/tests/global_ptol_policy_test.cc");
  const std::string cmake =
      Read(root + "/../third_party/glomap_vendor/CMakeLists.txt");

  if (bundle.find("std::atof(ptol)") != std::string::npos) {
    return Fail("unsafe unconditional std::atof PTOL override remains");
  }
  if (bundle.find("ResolveGlobalPtolV1(") == std::string::npos) {
    return Fail("solve path does not resolve scoped PTOL policy");
  }
  if (!ContainsAfter(bundle,
                     "ceres::Solve(",
                     "AppendAetherBaSolveReceiptV1(",
                     900)) {
    return Fail("an actual ceres::Solve lacks an immediate receipt append");
  }
  if (bundle.find("RecordBaSessionSolveReceiptV1(") == std::string::npos ||
      sfm.find("GetBaSessionAggregateSnapshotV1(") == std::string::npos) {
    return Fail("session aggregate does not count every solve across ring resets");
  }
  if (bundle.find(
          "BaSessionAggregateAccumulatorV1 g_ba_session_aggregate_v1") !=
      std::string::npos) {
    return Fail("process-global session aggregate still exists");
  }
  if (bundle.find("g_aether_ba_ring") != std::string::npos ||
      bundle.find("aether_ba_ring_get") != std::string::npos ||
      bundle.find("aether_ba_ring_reset") != std::string::npos) {
    return Fail("process-global per-Solve receipt ring still exists");
  }
  if (sfm.find("BaSessionAggregateAccumulatorV1 ba_ptol_aggregate;") ==
          std::string::npos ||
      sfm.find("BaSessionReceiptRingV1 ba_ptol_receipts;") ==
          std::string::npos ||
      sfm.find("BaSessionAggregateAccumulatorV1 batch_ptol_aggregate;") ==
          std::string::npos ||
      sfm.find("BaSessionReceiptRingV1 batch_ptol_receipts;") ==
          std::string::npos ||
      sfm.find("s->ba_ptol_aggregate.Replace(") == std::string::npos) {
    return Fail("streaming/batch sessions do not own both ledger components");
  }
  const std::size_t batch_account =
      sfm.find("BaSessionAggregateAccumulatorV1 batch_ptol_aggregate;");
  const std::size_t batch_run = sfm.find("RunIncremental(", batch_account);
  const std::size_t batch_binding =
      sfm.find("&batch_ptol_aggregate", batch_run);
  const std::size_t batch_ring_binding =
      sfm.find("&batch_ptol_receipts", batch_run);
  if (batch_account == std::string::npos || batch_run == std::string::npos ||
      batch_binding == std::string::npos || batch_binding - batch_run > 500) {
    return Fail("batch account is not established and bound before its solve");
  }
  if (batch_ring_binding == std::string::npos ||
      batch_ring_binding - batch_run > 500) {
    return Fail("batch receipt ring is not bound before its solve");
  }
  if (sfm.find("ResetBaSessionAggregateV1();") != std::string::npos) {
    return Fail("a process-wide no-argument session reset remains");
  }
  // Main capture/local BA, incremental global BA, finalize, synchronous
  // global refine, tail shadow, and async preview all need explicit owners.
  if (Count(sfm, "ScopedBaSessionAggregateBindingV1") < 7 ||
      Count(sfm, "&s->ba_ptol_aggregate") < 7 ||
      Count(sfm, "&s->ba_ptol_receipts") < 6) {
    return Fail("one or more synchronous/async BA routes lack session binding");
  }
  if (policy.find("class BaSessionReceiptRingV1") == std::string::npos ||
      policy.find("BaReceiptRingSnapshotV1 Drain()") == std::string::npos ||
      policy.find("BaReceiptRingSnapshotV1 Reset()") == std::string::npos ||
      policy.find("bool Get(std::size_t index") == std::string::npos ||
      policy.find("std::size_t Count() const") == std::string::npos) {
    return Fail("owner-specific append/reset/count/get/drain API is incomplete");
  }
  if (sfm.find("s->ba_ptol_receipts.Drain()") == std::string::npos ||
      sfm.find("const aether::official::ba::BaSolveReceiptV1& receipt") ==
          std::string::npos) {
    return Fail(
        "ba_rounds is not serialized from one immutable composite snapshot");
  }
  if (policy.find("g_unbound_ba_solve_count_v1") == std::string::npos ||
      bundle.find("unbound ceres::Solve receipt") == std::string::npos) {
    return Fail("unbound Solve receipt is not explicit and fail-closed");
  }
  if (sfm.find("ScopedGlobalBaSolveV1") == std::string::npos ||
      pipeline.find("ScopedGlobalBaSolveV1") == std::string::npos) {
    return Fail("global BA call sites are not explicitly scoped");
  }
  if (sfm.find("\\\"solve_seq\\\"") == std::string::npos ||
      sfm.find("\\\"ptol_effective\\\"") == std::string::npos ||
      sfm.find("\\\"ptol_parse_status\\\"") == std::string::npos) {
    return Fail("persisted ba_rounds telemetry lacks PTOL receipt fields");
  }
  if (sfm.find("\\\"type\\\":\\\"ba_ptol_session_v1\\\"") ==
          std::string::npos ||
      sfm.find("\\\"solve_count\\\"") == std::string::npos ||
      sfm.find("\\\"mismatch\\\"") == std::string::npos ||
      sfm.find("\\\"overflow\\\"") == std::string::npos) {
    return Fail("persistent per-scope session aggregate is incomplete");
  }
  if (sfm.find("\\\"receipt_overwrite_count\\\"") == std::string::npos ||
      sfm.find("batch_no_session") == std::string::npos ||
      sfm.find("AppendBaRingJsonl(receipt_sink.get(), -1)") ==
          std::string::npos) {
    return Fail("capacity loss or no-session batch receipts are not observable");
  }
  if (policy_test.find("session A reset erased or charged session B") ==
          std::string::npos ||
      policy_test.find("session B drain contains session A") ==
          std::string::npos ||
      policy_test.find("torn receipt fields") == std::string::npos ||
      policy_test.find("mixed-scope local eviction") == std::string::npos ||
      policy_test.find("mixed-scope global eviction") == std::string::npos) {
    return Fail("persistent test lacks interleaved owner/snapshot assertions");
  }
  if (cmake.find("add_test(NAME global_ptol_policy_test") ==
          std::string::npos ||
      cmake.find("-ffast-math") == std::string::npos ||
      cmake.find("add_test(NAME global_ptol_integration_contract_test") ==
          std::string::npos) {
    return Fail("PTOL tests are not persistent production-mode CTest targets");
  }

  std::cout << "PASS: global PTOL integration contract\n";
  return 0;
}
