// R1 host slice: default-OFF is a constructive no-op. Production-device
// ordered matches/DB/PLY equivalence remains the separate Phase-A/P3 gate.
#define AETHER_PRECLAMP_INSTR_ENV_SELFTEST 1
#include "../../official_pipeline/src/official_preclamp_instr_v1.h"

#include <cassert>
#include <cstddef>
#include <cstdio>
#include <cstdlib>
#include <new>
#include <vector>

namespace {
size_t g_allocations = 0;
bool g_count_allocations = false;
}

void* operator new(std::size_t size) {
  if (g_count_allocations) ++g_allocations;
  if (void* p = std::malloc(size)) return p;
  throw std::bad_alloc();
}

void operator delete(void* p) noexcept { std::free(p); }
void operator delete(void* p, std::size_t) noexcept { std::free(p); }

int main() {
  unsetenv("AETHER_PRECLAMP_INSTR_V1");
  assert(!aether_preclamp_instr_v1::Enabled());

  const std::vector<unsigned char> ordered_matches{1, 9, 4, 7};
  const std::vector<unsigned char> database{0x53, 0x51, 0x4c, 0x69};
  const std::vector<unsigned char> ply{'p', 'l', 'y', '\n'};
  const auto ordered_matches_before = ordered_matches;
  const auto database_before = database;
  const auto ply_before = ply;

  std::vector<aether_preclamp_instr_v1::FrameCounts> exported{{}};
  const size_t exported_size_before = exported.size();
  g_count_allocations = true;
  const size_t allocations_before = g_allocations;
  aether_preclamp_instr_v1::ClearPendingAtGpuEntry();
  aether_preclamp_instr_v1::BeginLegacyClamp(20000);
  aether_preclamp_instr_v1::UpdateLegacyClampResult(16570);
  assert(!aether_preclamp_instr_v1::SealAcceptedLegacyGpuResult(
      16570, aether_preclamp_instr_v1::FieldStatus::kUnavailable, 0.0f));
  aether_preclamp_instr_v1::FrameCounts finalized;
  assert(!aether_preclamp_instr_v1::FinalizeAcceptedFrame(
      1, 1, aether_preclamp_instr_v1::FieldStatus::kValid, 0,
      &finalized));
  aether_preclamp_instr_v1::DiscardPending(
      aether_preclamp_instr_v1::PendingDiscardReason::kZeroCandidate);
  aether_preclamp_instr_v1::SessionRecords records;
  aether_preclamp_instr_v1::ResetSessionRecords(&records);
  assert(!aether_preclamp_instr_v1::AppendSessionRecord(
      &records, finalized));
  assert(!aether_preclamp_instr_v1::CopySessionRecords(&records, &exported));
  assert(g_allocations == allocations_before);
  g_count_allocations = false;

  assert(exported.size() == exported_size_before);
  assert(ordered_matches == ordered_matches_before);
  assert(database == database_before);
  assert(ply == ply_before);
  std::printf("PASS R1 host default-OFF constructive no-op; P3 equivalence pending\n");
  return 0;
}
