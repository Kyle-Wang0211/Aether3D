#include <cmath>
#include <cstdlib>
#include <atomic>
#include <iostream>
#include <string>
#include <thread>

#if __has_include("aether_ba_solve_policy_v1.h")
#include "aether_ba_solve_policy_v1.h"
#define AETHER_HAS_BA_SOLVE_POLICY_V1 1
#else
#define AETHER_HAS_BA_SOLVE_POLICY_V1 0
#endif

namespace {

int Fail(const std::string& message) {
  std::cerr << "FAIL: " << message << '\n';
  return 1;
}

}  // namespace

int main() {
#if !AETHER_HAS_BA_SOLVE_POLICY_V1
  return Fail("aether_ba_solve_policy_v1.h is missing");
#else
  using aether::official::ba::PtolParseStatusV1;
  using aether::official::ba::PtolSourceV1;
  using aether::official::ba::ResolveGlobalPtolV1;
  using aether::official::ba::ScopedGlobalBaSolveV1;
  using aether::official::ba::SolveScopeV1;

  constexpr double kBase = 0.0;

  const auto local = ResolveGlobalPtolV1(
      "1e-3", SolveScopeV1::kLocal, kBase);
  if (local.parse_status != PtolParseStatusV1::kValid ||
      local.requested != 1e-3 || local.base != kBase ||
      local.effective != kBase ||
      local.source != PtolSourceV1::kBaseLocalScope) {
    return Fail("valid global PTOL leaked into local BA");
  }

  const auto global = ResolveGlobalPtolV1(
      "1e-3", SolveScopeV1::kGlobal, kBase);
  if (global.parse_status != PtolParseStatusV1::kValid ||
      global.requested != 1e-3 || global.base != kBase ||
      global.effective != 1e-3 ||
      global.source != PtolSourceV1::kGlobalEnv) {
    return Fail("valid global PTOL was not applied to global BA");
  }

  struct InvalidCase {
    const char* raw;
    PtolParseStatusV1 expected_status;
  };
  const InvalidCase invalid_cases[] = {
      {nullptr, PtolParseStatusV1::kMissing},
      {"", PtolParseStatusV1::kEmpty},
      {"garbage", PtolParseStatusV1::kGarbage},
      {"1e-3junk", PtolParseStatusV1::kGarbage},
      {"0", PtolParseStatusV1::kNonPositive},
      {"-0.5", PtolParseStatusV1::kNonPositive},
      {"nan", PtolParseStatusV1::kNonFinite},
      {"inf", PtolParseStatusV1::kNonFinite},
      {"-inf", PtolParseStatusV1::kNonFinite},
      {"1e999", PtolParseStatusV1::kNonFinite},
  };
  for (const InvalidCase& test : invalid_cases) {
    const auto result =
        ResolveGlobalPtolV1(test.raw, SolveScopeV1::kGlobal, kBase);
    if (result.parse_status != test.expected_status ||
        result.effective != kBase ||
        result.source != PtolSourceV1::kBaseFallback) {
      return Fail(std::string("invalid PTOL did not fall back: ") +
                  (test.raw == nullptr ? "<missing>" : test.raw));
    }
  }

  if (aether::official::ba::CurrentBaSolveScopeV1() !=
      SolveScopeV1::kLocal) {
    return Fail("default BA scope is not local");
  }
  {
    ScopedGlobalBaSolveV1 outer;
    if (aether::official::ba::CurrentBaSolveScopeV1() !=
        SolveScopeV1::kGlobal) {
      return Fail("global scope guard did not mark the solve");
    }
    {
      ScopedGlobalBaSolveV1 nested;
      if (aether::official::ba::CurrentBaSolveScopeV1() !=
          SolveScopeV1::kGlobal) {
        return Fail("nested global scope guard lost the mark");
      }
    }
    if (aether::official::ba::CurrentBaSolveScopeV1() !=
        SolveScopeV1::kGlobal) {
      return Fail("nested guard teardown cleared the outer mark");
    }
  }
  if (aether::official::ba::CurrentBaSolveScopeV1() !=
      SolveScopeV1::kLocal) {
    return Fail("global scope guard leaked after teardown");
  }

#if !defined(AETHER_BA_SESSION_AGGREGATE_ACCUMULATOR_V1)
  return Fail("session aggregate accumulator is missing");
#else
  aether::official::ba::BaSessionAggregateAccumulatorV1 aggregate;
  aggregate.Record(SolveScopeV1::kLocal, local, /*gpu_fallback=*/false,
                   /*receipt_overflow=*/false);
  aggregate.Record(SolveScopeV1::kGlobal, global, /*gpu_fallback=*/true,
                   /*receipt_overflow=*/true);
  auto leaked_local = local;
  leaked_local.effective = leaked_local.requested;
  leaked_local.source = PtolSourceV1::kGlobalEnv;
  aggregate.Record(SolveScopeV1::kLocal, leaked_local,
                   /*gpu_fallback=*/false, /*receipt_overflow=*/false);
  const auto aggregate_snapshot = aggregate.Snapshot();
  if (aggregate_snapshot.total_solve_count != 3 ||
      aggregate_snapshot.scopes[0].solve_count != 2 ||
      aggregate_snapshot.scopes[1].solve_count != 1) {
    return Fail("session aggregate solve counts do not conserve");
  }
  if (aggregate_snapshot.scopes[0].mismatch != 1 ||
      aggregate_snapshot.scopes[1].mismatch != 0) {
    return Fail("session aggregate did not detect a local PTOL leak");
  }
  if (aggregate_snapshot.scopes[1].gpu_fallback_count != 1 ||
      aggregate_snapshot.scopes[1].overflow != 1) {
    return Fail("session aggregate lost fallback/overflow accounting");
  }

  using aether::official::ba::BaSessionReceiptRingV1;
  using aether::official::ba::BaSolveReceiptV1;
  using aether::official::ba::CurrentBaSessionAggregateV1;
  using aether::official::ba::CurrentBaSessionReceiptRingV1;
  using aether::official::ba::RecordBaSessionSolveReceiptV1;
  using aether::official::ba::ScopedBaSessionAggregateBindingV1;

  const auto make_receipt = [](std::uint64_t seq,
                               SolveScopeV1 scope,
                               bool gpu_fallback) {
    BaSolveReceiptV1 receipt;
    receipt.solve_seq = seq;
    receipt.scope = scope;
    receipt.gpu_fallback = gpu_fallback;
    receipt.total_s = static_cast<double>(seq);
    receipt.jac_s = receipt.total_s + 0.125;
    receipt.lin_s = receipt.total_s + 0.25;
    receipt.res_s = receipt.total_s + 0.5;
    receipt.pre_s = receipt.total_s + 1.0;
    receipt.min_s = receipt.total_s + 2.0;
    receipt.post_s = receipt.total_s + 3.0;
    receipt.iters = static_cast<int>(seq % 101U);
    receipt.term = static_cast<int>(seq % 7U);
    receipt.threads = static_cast<int>(seq % 8U) + 1;
    const std::string raw = std::to_string(seq);
    std::memcpy(receipt.ptol.raw.data(), raw.c_str(), raw.size() + 1U);
    receipt.ptol.raw_present = true;
    receipt.ptol.requested = static_cast<double>(seq);
    receipt.ptol.base = 0.0;
    receipt.ptol.parse_status = PtolParseStatusV1::kValid;
    if (scope == SolveScopeV1::kGlobal) {
      receipt.ptol.effective = receipt.ptol.requested;
      receipt.ptol.source = PtolSourceV1::kGlobalEnv;
    } else {
      receipt.ptol.effective = receipt.ptol.base;
      receipt.ptol.source = PtolSourceV1::kBaseLocalScope;
    }
    return receipt;
  };
  const auto receipt_is_consistent = [](const BaSolveReceiptV1& receipt) {
    const bool policy_consistent =
        receipt.ptol.parse_status == PtolParseStatusV1::kValid &&
        receipt.ptol.base == 0.0 &&
        (receipt.scope == SolveScopeV1::kGlobal
             ? receipt.ptol.effective == receipt.ptol.requested &&
                   receipt.ptol.source == PtolSourceV1::kGlobalEnv
             : receipt.ptol.effective == receipt.ptol.base &&
                   receipt.ptol.source == PtolSourceV1::kBaseLocalScope);
    return policy_consistent &&
           std::strtoull(receipt.ptol.raw.data(), nullptr, 10) ==
               receipt.solve_seq &&
           receipt.total_s == static_cast<double>(receipt.solve_seq) &&
           receipt.jac_s == receipt.total_s + 0.125 &&
           receipt.ptol.requested ==
               static_cast<double>(receipt.solve_seq);
  };

  // Capacity loss is charged to the evicted receipt's scope, never to the
  // incoming receipt's scope. Exercise both mixed-scope boundary directions.
  {
    aether::official::ba::BaSessionAggregateAccumulatorV1 mixed_account;
    BaSessionReceiptRingV1 mixed_ring;
    constexpr std::uint64_t kBaseSeq = 800000;
    {
      ScopedBaSessionAggregateBindingV1 binding(&mixed_account, &mixed_ring);
      for (std::size_t i = 0;
           i < aether::official::ba::kBaReceiptRingCapacityV1; ++i) {
        RecordBaSessionSolveReceiptV1(make_receipt(
            kBaseSeq + i, SolveScopeV1::kLocal, false));
      }
      RecordBaSessionSolveReceiptV1(
          make_receipt(kBaseSeq + 999, SolveScopeV1::kGlobal, false));
    }
    const auto account = mixed_account.Snapshot();
    const auto receipts = mixed_ring.Snapshot();
    if (account.total_solve_count !=
            aether::official::ba::kBaReceiptRingCapacityV1 + 1 ||
        account.scopes[0].solve_count !=
            aether::official::ba::kBaReceiptRingCapacityV1 ||
        account.scopes[1].solve_count != 1 ||
        account.scopes[0].overflow != 1 ||
        account.scopes[1].overflow != 0 ||
        receipts.count != aether::official::ba::kBaReceiptRingCapacityV1 ||
        receipts.overwrite_count != 1 ||
        receipts.receipts[0].solve_seq != kBaseSeq + 1 ||
        receipts.receipts[receipts.count - 1].solve_seq != kBaseSeq + 999 ||
        receipts.receipts[receipts.count - 1].scope !=
            SolveScopeV1::kGlobal) {
      return Fail("mixed-scope local eviction was charged to incoming global");
    }
  }
  {
    aether::official::ba::BaSessionAggregateAccumulatorV1 mixed_account;
    BaSessionReceiptRingV1 mixed_ring;
    constexpr std::uint64_t kBaseSeq = 810000;
    {
      ScopedBaSessionAggregateBindingV1 binding(&mixed_account, &mixed_ring);
      for (std::size_t i = 0;
           i < aether::official::ba::kBaReceiptRingCapacityV1; ++i) {
        RecordBaSessionSolveReceiptV1(make_receipt(
            kBaseSeq + i, SolveScopeV1::kGlobal, false));
      }
      RecordBaSessionSolveReceiptV1(
          make_receipt(kBaseSeq + 999, SolveScopeV1::kLocal, false));
    }
    const auto account = mixed_account.Snapshot();
    const auto receipts = mixed_ring.Snapshot();
    if (account.total_solve_count !=
            aether::official::ba::kBaReceiptRingCapacityV1 + 1 ||
        account.scopes[0].solve_count != 1 ||
        account.scopes[1].solve_count !=
            aether::official::ba::kBaReceiptRingCapacityV1 ||
        account.scopes[0].overflow != 0 ||
        account.scopes[1].overflow != 1 ||
        receipts.count != aether::official::ba::kBaReceiptRingCapacityV1 ||
        receipts.overwrite_count != 1 ||
        receipts.receipts[0].solve_seq != kBaseSeq + 1 ||
        receipts.receipts[receipts.count - 1].solve_seq != kBaseSeq + 999 ||
        receipts.receipts[receipts.count - 1].scope !=
            SolveScopeV1::kLocal) {
      return Fail("mixed-scope global eviction was charged to incoming local");
    }
  }
  {
    aether::official::ba::BaSessionAggregateAccumulatorV1 truncated_account;
    BaSessionReceiptRingV1 truncated_ring;
    auto truncated =
        make_receipt(820000, SolveScopeV1::kLocal, false);
    truncated.ptol.raw_truncated = true;
    {
      ScopedBaSessionAggregateBindingV1 binding(&truncated_account,
                                                &truncated_ring);
      RecordBaSessionSolveReceiptV1(truncated);
    }
    const auto account = truncated_account.Snapshot();
    const auto receipts = truncated_ring.Snapshot();
    if (account.scopes[0].overflow != 1 ||
        account.scopes[1].overflow != 0 || receipts.overwrite_count != 0 ||
        receipts.count != 1 || !receipts.receipts[0].ptol.raw_truncated) {
      return Fail("raw-truncated loss accounting changed with eviction fix");
    }
  }

  // Interleave two owners beyond capacity. Each ring must retain only its own
  // last 32 self-consistent composite receipts; timing and PTOL are one object.
  aether::official::ba::BaSessionAggregateAccumulatorV1 session_a;
  aether::official::ba::BaSessionAggregateAccumulatorV1 session_b;
  BaSessionReceiptRingV1 ring_a;
  BaSessionReceiptRingV1 ring_b;
  constexpr std::uint64_t kSessionABase = 100000;
  constexpr std::uint64_t kSessionBBase = 200000;
  constexpr std::uint64_t kSessionASolves = 120;
  constexpr std::uint64_t kSessionBSolves = 90;
  std::atomic<bool> start{false};
  std::thread thread_a([&] {
    ScopedBaSessionAggregateBindingV1 binding(&session_a, &ring_a);
    while (!start.load(std::memory_order_acquire)) {
    }
    for (std::uint64_t i = 0; i < kSessionASolves; ++i) {
      if (!RecordBaSessionSolveReceiptV1(
              make_receipt(kSessionABase + i, SolveScopeV1::kLocal, false))) {
        std::abort();
      }
    }
  });
  std::thread thread_b([&] {
    ScopedBaSessionAggregateBindingV1 binding(&session_b, &ring_b);
    while (!start.load(std::memory_order_acquire)) {
    }
    for (std::uint64_t i = 0; i < kSessionBSolves; ++i) {
      if (!RecordBaSessionSolveReceiptV1(make_receipt(
              kSessionBBase + i, SolveScopeV1::kGlobal, i == 0))) {
        std::abort();
      }
    }
  });
  start.store(true, std::memory_order_release);
  thread_a.join();
  thread_b.join();

  const auto aggregate_a = session_a.Snapshot();
  const auto aggregate_b = session_b.Snapshot();
  const auto retained_a = ring_a.Snapshot();
  const auto retained_b = ring_b.Snapshot();
  const std::uint64_t expected_a_overwrite =
      kSessionASolves - aether::official::ba::kBaReceiptRingCapacityV1;
  const std::uint64_t expected_b_overwrite =
      kSessionBSolves - aether::official::ba::kBaReceiptRingCapacityV1;
  if (aggregate_a.total_solve_count != kSessionASolves ||
      aggregate_a.scopes[0].solve_count != kSessionASolves ||
      aggregate_a.scopes[1].solve_count != 0 ||
      aggregate_a.scopes[0].overflow != expected_a_overwrite ||
      retained_a.count != aether::official::ba::kBaReceiptRingCapacityV1 ||
      retained_a.overwrite_count != expected_a_overwrite) {
    return Fail("interleaved session A ring/account is not isolated");
  }
  if (aggregate_b.total_solve_count != kSessionBSolves ||
      aggregate_b.scopes[0].solve_count != 0 ||
      aggregate_b.scopes[1].solve_count != kSessionBSolves ||
      aggregate_b.scopes[1].gpu_fallback_count != 1 ||
      aggregate_b.scopes[1].overflow != expected_b_overwrite ||
      retained_b.count != aether::official::ba::kBaReceiptRingCapacityV1 ||
      retained_b.overwrite_count != expected_b_overwrite) {
    return Fail("interleaved session B ring/account is not isolated");
  }
  BaSolveReceiptV1 first_a_from_get;
  if (!ring_a.Get(0, &first_a_from_get) ||
      first_a_from_get.solve_seq != retained_a.receipts[0].solve_seq ||
      ring_a.Get(retained_a.count, &first_a_from_get)) {
    return Fail("owner-specific ring Get does not match its snapshot bounds");
  }
  for (std::size_t i = 0; i < retained_a.count; ++i) {
    const auto& receipt = retained_a.receipts[i];
    if (!receipt_is_consistent(receipt) ||
        receipt.scope != SolveScopeV1::kLocal ||
        receipt.solve_seq < kSessionABase ||
        receipt.solve_seq >= kSessionABase + kSessionASolves) {
      return Fail("session A snapshot mixed timing/PTOL or owner identity");
    }
  }
  for (std::size_t i = 0; i < retained_b.count; ++i) {
    const auto& receipt = retained_b.receipts[i];
    if (!receipt_is_consistent(receipt) ||
        receipt.scope != SolveScopeV1::kGlobal ||
        receipt.solve_seq < kSessionBBase ||
        receipt.solve_seq >= kSessionBBase + kSessionBSolves) {
      return Fail("session B snapshot mixed timing/PTOL or owner identity");
    }
  }

  // A reset accounts only A's retained-sample loss and leaves B untouched.
  {
    ScopedBaSessionAggregateBindingV1 binding(&session_a, &ring_a);
    if (!aether::official::ba::ResetActiveBaSessionReceiptRingV1()) {
      return Fail("bound session A reset was rejected");
    }
  }
  if (ring_a.Count() != 0 || ring_b.Count() != retained_b.count ||
      session_a.Snapshot().scopes[0].overflow !=
          expected_a_overwrite + retained_a.count ||
      session_b.Snapshot().scopes[1].overflow != expected_b_overwrite) {
    return Fail("session A reset erased or charged session B");
  }

  // B drain is a single immutable snapshot. Appending after the drain cannot
  // mutate it, and no receipt from A may appear in it.
  const auto drained_b = ring_b.Drain();
  if (drained_b.count != retained_b.count || ring_b.Count() != 0) {
    return Fail("session B drain did not atomically clear only B");
  }
  for (std::size_t i = 0; i < drained_b.count; ++i) {
    if (!receipt_is_consistent(drained_b.receipts[i]) ||
        drained_b.receipts[i].solve_seq < kSessionBBase) {
      return Fail("session B drain contains session A or torn receipt fields");
    }
  }
  {
    ScopedBaSessionAggregateBindingV1 binding(&session_b, &ring_b);
    RecordBaSessionSolveReceiptV1(
        make_receipt(300001, SolveScopeV1::kGlobal, true));
  }
  if (drained_b.receipts[0].solve_seq != retained_b.receipts[0].solve_seq ||
      ring_b.Count() != 1 || ring_a.Count() != 0) {
    return Fail("drained snapshot changed after a later append");
  }

  // Nested bindings restore both owner components.
  session_a.Reset();
  session_b.Reset();
  ring_a.Reset();
  ring_b.Reset();
  {
    ScopedBaSessionAggregateBindingV1 outer(&session_a, &ring_a);
    if (CurrentBaSessionAggregateV1() != &session_a ||
        CurrentBaSessionReceiptRingV1() != &ring_a) {
      return Fail("outer session ledger binding was not installed");
    }
    {
      ScopedBaSessionAggregateBindingV1 inner(&session_b, &ring_b);
      RecordBaSessionSolveReceiptV1(
          make_receipt(400001, SolveScopeV1::kGlobal, false));
    }
    if (CurrentBaSessionAggregateV1() != &session_a ||
        CurrentBaSessionReceiptRingV1() != &ring_a) {
      return Fail("nested teardown did not restore the outer ledger");
    }
    RecordBaSessionSolveReceiptV1(
        make_receipt(400002, SolveScopeV1::kLocal, false));
  }
  if (session_a.Snapshot().total_solve_count != 1 || ring_a.Count() != 1 ||
      session_b.Snapshot().total_solve_count != 1 || ring_b.Count() != 1) {
    return Fail("nested ledger binding mixed session receipts");
  }

  // Missing or partial binding is explicit and fail-closed: count it, but do
  // not silently attribute it to the last/other session.
  const std::uint64_t unbound_before =
      aether::official::ba::GetUnboundBaSolveCountV1();
  if (RecordBaSessionSolveReceiptV1(
          make_receipt(500001, SolveScopeV1::kGlobal, false))) {
    return Fail("unbound receipt was accepted");
  }
  {
    ScopedBaSessionAggregateBindingV1 partial(&session_a, nullptr);
    if (RecordBaSessionSolveReceiptV1(
            make_receipt(500002, SolveScopeV1::kGlobal, false))) {
      return Fail("partially bound receipt was accepted");
    }
  }
  if (aether::official::ba::GetUnboundBaSolveCountV1() !=
          unbound_before + 2 ||
      session_a.Snapshot().total_solve_count != 1 || ring_a.Count() != 1 ||
      session_b.Snapshot().total_solve_count != 1 || ring_b.Count() != 1) {
    return Fail("unbound receipt was not explicitly isolated and counted");
  }

  // Sequential batch invocations each create both ledger components at zero.
  aether::official::ba::BaSessionAggregateAccumulatorV1 first_batch;
  aether::official::ba::BaSessionAggregateAccumulatorV1 second_batch;
  BaSessionReceiptRingV1 first_batch_ring;
  BaSessionReceiptRingV1 second_batch_ring;
  {
    ScopedBaSessionAggregateBindingV1 binding(&first_batch,
                                              &first_batch_ring);
    RecordBaSessionSolveReceiptV1(
        make_receipt(600001, SolveScopeV1::kGlobal, false));
    RecordBaSessionSolveReceiptV1(
        make_receipt(600002, SolveScopeV1::kGlobal, true));
  }
  if (second_batch.Snapshot().total_solve_count != 0 ||
      second_batch_ring.Count() != 0) {
    return Fail("later batch inherited an earlier batch ledger");
  }
  {
    ScopedBaSessionAggregateBindingV1 binding(&second_batch,
                                              &second_batch_ring);
    RecordBaSessionSolveReceiptV1(
        make_receipt(700001, SolveScopeV1::kLocal, false));
  }
  if (first_batch.Snapshot().total_solve_count != 2 ||
      first_batch_ring.Count() != 2 ||
      second_batch.Snapshot().total_solve_count != 1 ||
      second_batch_ring.Count() != 1) {
    return Fail("sequential batch ledgers mixed");
  }
  BaSolveReceiptV1 fallback_receipt;
  if (!first_batch_ring.Get(1, &fallback_receipt) ||
      !fallback_receipt.gpu_fallback ||
      fallback_receipt.solve_seq != 600002) {
    return Fail("GPU failure CPU-fallback receipt was not independently kept");
  }
#endif

  std::cout << "PASS: global PTOL policy isolates local BA and rejects invalid values\n";
  return 0;
#endif
}
