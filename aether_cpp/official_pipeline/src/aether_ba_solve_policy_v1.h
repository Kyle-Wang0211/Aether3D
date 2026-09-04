#pragma once

#include <algorithm>
#include <array>
#include <atomic>
#include <cmath>
#include <cstddef>
#include <cstdint>
#include <cstdlib>
#include <cstring>
#include <mutex>

namespace aether::official::ba {

enum class SolveScopeV1 : int {
  kLocal = 0,
  kGlobal = 1,
};

enum class PtolParseStatusV1 : int {
  kMissing = 0,
  kEmpty = 1,
  kGarbage = 2,
  kNonPositive = 3,
  kNonFinite = 4,
  kValid = 5,
};

enum class PtolSourceV1 : int {
  kBaseLocalScope = 0,
  kBaseFallback = 1,
  kGlobalEnv = 2,
};

constexpr std::size_t kPtolRawCapacityV1 = 64;
constexpr std::size_t kBaReceiptRingCapacityV1 = 32;

struct GlobalPtolResolutionV1 {
  std::array<char, kPtolRawCapacityV1> raw{};
  bool raw_present = false;
  bool raw_truncated = false;
  double requested = 0.0;
  double base = 0.0;
  double effective = 0.0;
  PtolParseStatusV1 parse_status = PtolParseStatusV1::kMissing;
  PtolSourceV1 source = PtolSourceV1::kBaseFallback;
};

struct BaSolveReceiptV1 {
  double total_s = 0.0;
  double jac_s = 0.0;
  double lin_s = 0.0;
  double res_s = 0.0;
  double pre_s = 0.0;
  double min_s = 0.0;
  double post_s = 0.0;
  int iters = 0;
  int term = 0;
  int threads = 0;
  std::uint64_t solve_seq = 0;
  SolveScopeV1 scope = SolveScopeV1::kLocal;
  GlobalPtolResolutionV1 ptol;
  bool gpu_fallback = false;
};

struct BaReceiptRingSnapshotV1 {
  std::array<BaSolveReceiptV1, kBaReceiptRingCapacityV1> receipts{};
  std::size_t count = 0;
  // Number of oldest receipts overwritten since the last reset/drain.
  std::uint64_t overwrite_count = 0;
};

struct BaReceiptAppendResultV1 {
  bool overwritten = false;
  // Valid exactly when overwritten is true. The loss belongs to this receipt's
  // scope, not to the newly appended receipt's scope.
  BaSolveReceiptV1 evicted;
};

class BaSessionReceiptRingV1 {
 public:
  // Returns the owner-local receipt displaced by this append, if any. Another
  // session can never affect this result.
  BaReceiptAppendResultV1 Append(const BaSolveReceiptV1& receipt) {
    std::lock_guard<std::mutex> lock(mutex_);
    BaReceiptAppendResultV1 result;
    result.overwritten = size_ == kBaReceiptRingCapacityV1;
    if (result.overwritten) result.evicted = receipts_[next_];
    receipts_[next_] = receipt;
    next_ = (next_ + 1U) % kBaReceiptRingCapacityV1;
    if (result.overwritten) {
      ++overwrite_count_;
    } else {
      ++size_;
    }
    return result;
  }

  std::size_t Count() const {
    std::lock_guard<std::mutex> lock(mutex_);
    return size_;
  }

  bool Get(std::size_t index, BaSolveReceiptV1* out) const {
    if (out == nullptr) return false;
    std::lock_guard<std::mutex> lock(mutex_);
    if (index >= size_) return false;
    const std::size_t oldest =
        (next_ + kBaReceiptRingCapacityV1 - size_) %
        kBaReceiptRingCapacityV1;
    *out = receipts_[(oldest + index) % kBaReceiptRingCapacityV1];
    return true;
  }

  BaReceiptRingSnapshotV1 Snapshot() const {
    std::lock_guard<std::mutex> lock(mutex_);
    return SnapshotUnlocked();
  }

  BaReceiptRingSnapshotV1 Drain() {
    std::lock_guard<std::mutex> lock(mutex_);
    BaReceiptRingSnapshotV1 snapshot = SnapshotUnlocked();
    ClearUnlocked();
    return snapshot;
  }

  // Reset returns the receipts it discarded so the caller can account for
  // deliberate sample loss by scope; it never touches another ring.
  BaReceiptRingSnapshotV1 Reset() {
    std::lock_guard<std::mutex> lock(mutex_);
    BaReceiptRingSnapshotV1 snapshot = SnapshotUnlocked();
    ClearUnlocked();
    return snapshot;
  }

  void Replace(const BaReceiptRingSnapshotV1& snapshot) {
    std::lock_guard<std::mutex> lock(mutex_);
    ClearUnlocked();
    const std::size_t count =
        std::min(snapshot.count, kBaReceiptRingCapacityV1);
    for (std::size_t i = 0; i < count; ++i) {
      receipts_[i] = snapshot.receipts[i];
    }
    size_ = count;
    next_ = count % kBaReceiptRingCapacityV1;
    overwrite_count_ = snapshot.overwrite_count;
  }

 private:
  BaReceiptRingSnapshotV1 SnapshotUnlocked() const {
    BaReceiptRingSnapshotV1 snapshot;
    snapshot.count = size_;
    snapshot.overwrite_count = overwrite_count_;
    const std::size_t oldest =
        (next_ + kBaReceiptRingCapacityV1 - size_) %
        kBaReceiptRingCapacityV1;
    for (std::size_t i = 0; i < size_; ++i) {
      snapshot.receipts[i] =
          receipts_[(oldest + i) % kBaReceiptRingCapacityV1];
    }
    return snapshot;
  }

  void ClearUnlocked() {
    size_ = 0;
    next_ = 0;
    overwrite_count_ = 0;
  }

  mutable std::mutex mutex_;
  std::array<BaSolveReceiptV1, kBaReceiptRingCapacityV1> receipts_{};
  std::size_t size_ = 0;
  std::size_t next_ = 0;
  std::uint64_t overwrite_count_ = 0;
};

struct BaScopeAggregateSnapshotV1 {
  SolveScopeV1 scope = SolveScopeV1::kLocal;
  std::uint64_t solve_count = 0;
  std::uint64_t gpu_fallback_count = 0;
  // Policy-invariant violations across all solves in this scope.
  std::uint64_t mismatch = 0;
  // Sample ring overwrites plus raw-value truncations. Aggregate counts and
  // last effective values remain lossless when this is non-zero.
  std::uint64_t overflow = 0;
  bool has_last = false;
  GlobalPtolResolutionV1 last;
};

struct BaSessionAggregateSnapshotV1 {
  std::uint64_t total_solve_count = 0;
  std::array<BaScopeAggregateSnapshotV1, 2> scopes{};
};

#define AETHER_BA_SESSION_AGGREGATE_ACCUMULATOR_V1 1

class BaSessionAggregateAccumulatorV1 {
 public:
  BaSessionAggregateAccumulatorV1() { InitializeSnapshotUnlocked(); }

  void Reset() {
    std::lock_guard<std::mutex> lock(mutex_);
    InitializeSnapshotUnlocked();
  }

  void Replace(const BaSessionAggregateSnapshotV1& snapshot) {
    std::lock_guard<std::mutex> lock(mutex_);
    snapshot_ = snapshot;
    snapshot_.scopes[0].scope = SolveScopeV1::kLocal;
    snapshot_.scopes[1].scope = SolveScopeV1::kGlobal;
  }

  void Record(SolveScopeV1 scope,
              const GlobalPtolResolutionV1& ptol,
              bool gpu_fallback,
              bool receipt_overflow) {
    std::lock_guard<std::mutex> lock(mutex_);
    RecordUnlocked(scope, ptol, gpu_fallback, receipt_overflow);
  }

  void RecordReceiptLoss(SolveScopeV1 scope, std::uint64_t count) {
    std::lock_guard<std::mutex> lock(mutex_);
    snapshot_.scopes[scope == SolveScopeV1::kGlobal ? 1U : 0U].overflow +=
        count;
  }

  BaSessionAggregateSnapshotV1 Snapshot() const {
    std::lock_guard<std::mutex> lock(mutex_);
    return snapshot_;
  }

 private:
  void InitializeSnapshotUnlocked() {
    snapshot_ = BaSessionAggregateSnapshotV1{};
    snapshot_.scopes[0].scope = SolveScopeV1::kLocal;
    snapshot_.scopes[1].scope = SolveScopeV1::kGlobal;
  }

  void RecordUnlocked(SolveScopeV1 scope,
                      const GlobalPtolResolutionV1& ptol,
                      bool gpu_fallback,
                      bool receipt_overflow) {
    BaScopeAggregateSnapshotV1& aggregate =
        snapshot_.scopes[scope == SolveScopeV1::kGlobal ? 1U : 0U];
    ++snapshot_.total_solve_count;
    ++aggregate.solve_count;
    if (gpu_fallback) ++aggregate.gpu_fallback_count;
    if (ResolutionMismatch(scope, ptol)) ++aggregate.mismatch;
    if (receipt_overflow) ++aggregate.overflow;
    if (ptol.raw_truncated) ++aggregate.overflow;
    aggregate.has_last = true;
    aggregate.last = ptol;
  }
  static bool ResolutionMismatch(SolveScopeV1 scope,
                                 const GlobalPtolResolutionV1& ptol) {
    if (scope == SolveScopeV1::kLocal) {
      return ptol.effective != ptol.base ||
             ptol.source != PtolSourceV1::kBaseLocalScope;
    }
    if (ptol.parse_status == PtolParseStatusV1::kValid) {
      return ptol.effective != ptol.requested ||
             ptol.source != PtolSourceV1::kGlobalEnv;
    }
    return ptol.effective != ptol.base ||
           ptol.source != PtolSourceV1::kBaseFallback;
  }

  mutable std::mutex mutex_;
  BaSessionAggregateSnapshotV1 snapshot_;
};

// A bundle adjuster has no product-session parameter in its upstream ABI. The
// caller therefore binds both pieces of the owning session ledger for the
// duration of a synchronous BA call. Every spawned refinement thread must bind
// explicitly; a partial or absent binding is fail-closed and never falls back
// to a process-global ring.
inline thread_local BaSessionAggregateAccumulatorV1*
    g_ba_session_aggregate_v1 = nullptr;
inline thread_local BaSessionReceiptRingV1* g_ba_session_receipts_v1 = nullptr;
inline std::atomic<std::uint64_t> g_unbound_ba_solve_count_v1{0};

class ScopedBaSessionAggregateBindingV1 {
 public:
  ScopedBaSessionAggregateBindingV1(
      BaSessionAggregateAccumulatorV1* aggregate,
      BaSessionReceiptRingV1* receipts)
      : previous_aggregate_(g_ba_session_aggregate_v1),
        previous_receipts_(g_ba_session_receipts_v1) {
    g_ba_session_aggregate_v1 = aggregate;
    g_ba_session_receipts_v1 = receipts;
  }

  ~ScopedBaSessionAggregateBindingV1() {
    g_ba_session_aggregate_v1 = previous_aggregate_;
    g_ba_session_receipts_v1 = previous_receipts_;
  }

  ScopedBaSessionAggregateBindingV1(
      const ScopedBaSessionAggregateBindingV1&) = delete;
  ScopedBaSessionAggregateBindingV1& operator=(
      const ScopedBaSessionAggregateBindingV1&) = delete;

 private:
  BaSessionAggregateAccumulatorV1* previous_aggregate_ = nullptr;
  BaSessionReceiptRingV1* previous_receipts_ = nullptr;
};

inline BaSessionAggregateAccumulatorV1* CurrentBaSessionAggregateV1() {
  return g_ba_session_aggregate_v1;
}

inline BaSessionReceiptRingV1* CurrentBaSessionReceiptRingV1() {
  return g_ba_session_receipts_v1;
}

inline void ResetBaSessionAggregateV1(
    BaSessionAggregateAccumulatorV1* aggregate) {
  if (aggregate != nullptr) aggregate->Reset();
}

inline BaSessionAggregateSnapshotV1 GetBaSessionAggregateSnapshotV1(
    const BaSessionAggregateAccumulatorV1* aggregate) {
  return aggregate == nullptr ? BaSessionAggregateSnapshotV1{}
                              : aggregate->Snapshot();
}

inline bool RecordBaSessionSolveReceiptV1(const BaSolveReceiptV1& receipt) {
  BaSessionAggregateAccumulatorV1* aggregate =
      CurrentBaSessionAggregateV1();
  BaSessionReceiptRingV1* receipts = CurrentBaSessionReceiptRingV1();
  if (aggregate == nullptr || receipts == nullptr) {
    g_unbound_ba_solve_count_v1.fetch_add(1, std::memory_order_relaxed);
    return false;
  }
  const BaReceiptAppendResultV1 append_result = receipts->Append(receipt);
  aggregate->Record(receipt.scope,
                    receipt.ptol,
                    receipt.gpu_fallback,
                    /*receipt_overflow=*/false);
  if (append_result.overwritten) {
    aggregate->RecordReceiptLoss(append_result.evicted.scope, 1);
  }
  return true;
}

inline bool ResetActiveBaSessionReceiptRingV1() {
  BaSessionAggregateAccumulatorV1* aggregate =
      CurrentBaSessionAggregateV1();
  BaSessionReceiptRingV1* receipts = CurrentBaSessionReceiptRingV1();
  if (aggregate == nullptr || receipts == nullptr) return false;
  const BaReceiptRingSnapshotV1 discarded = receipts->Reset();
  for (std::size_t i = 0; i < discarded.count; ++i) {
    aggregate->RecordReceiptLoss(discarded.receipts[i].scope, 1);
  }
  return true;
}

inline std::uint64_t GetUnboundBaSolveCountV1() {
  return g_unbound_ba_solve_count_v1.load(std::memory_order_relaxed);
}

inline thread_local std::uint32_t g_global_ba_scope_depth_v1 = 0;

// The production core is compiled with -ffast-math, which permits the compiler
// to assume floating-point values are finite and optimize std::isfinite away.
// Parse safety therefore has to inspect the IEEE-754 exponent bits directly.
inline bool IsFiniteDoubleBitsV1(double value) {
  static_assert(sizeof(double) == sizeof(std::uint64_t));
  volatile double stored = value;
  std::array<unsigned char, sizeof(double)> representation{};
  const volatile unsigned char* source =
      reinterpret_cast<const volatile unsigned char*>(&stored);
  for (std::size_t i = 0; i < representation.size(); ++i) {
    representation[i] = source[i];
  }
  std::uint64_t bits = 0;
  std::memcpy(&bits, representation.data(), sizeof(bits));
  constexpr std::uint64_t kExponentMask = UINT64_C(0x7ff0000000000000);
  return (bits & kExponentMask) != kExponentMask;
}

inline SolveScopeV1 CurrentBaSolveScopeV1() {
  return g_global_ba_scope_depth_v1 == 0 ? SolveScopeV1::kLocal
                                        : SolveScopeV1::kGlobal;
}

class ScopedGlobalBaSolveV1 {
 public:
  ScopedGlobalBaSolveV1() { ++g_global_ba_scope_depth_v1; }
  ~ScopedGlobalBaSolveV1() { --g_global_ba_scope_depth_v1; }

  ScopedGlobalBaSolveV1(const ScopedGlobalBaSolveV1&) = delete;
  ScopedGlobalBaSolveV1& operator=(const ScopedGlobalBaSolveV1&) = delete;
};

inline GlobalPtolResolutionV1 ResolveGlobalPtolV1(
    const char* raw, SolveScopeV1 scope, double base) {
  GlobalPtolResolutionV1 result;
  result.base = base;
  result.effective = base;
  result.source = scope == SolveScopeV1::kLocal
                      ? PtolSourceV1::kBaseLocalScope
                      : PtolSourceV1::kBaseFallback;

  if (raw == nullptr) {
    result.parse_status = PtolParseStatusV1::kMissing;
    return result;
  }

  result.raw_present = true;
  std::size_t i = 0;
  for (; raw[i] != '\0' && i + 1 < result.raw.size(); ++i) {
    result.raw[i] = raw[i];
  }
  result.raw[i] = '\0';
  result.raw_truncated = raw[i] != '\0';

  if (raw[0] == '\0') {
    result.parse_status = PtolParseStatusV1::kEmpty;
    return result;
  }

  char* end = nullptr;
  const double requested = std::strtod(raw, &end);
  if (end == raw || end == nullptr || *end != '\0') {
    result.parse_status = PtolParseStatusV1::kGarbage;
    return result;
  }
  if (!IsFiniteDoubleBitsV1(requested)) {
    result.parse_status = PtolParseStatusV1::kNonFinite;
    return result;
  }

  result.requested = requested;
  if (requested <= 0.0) {
    result.parse_status = PtolParseStatusV1::kNonPositive;
    return result;
  }

  result.parse_status = PtolParseStatusV1::kValid;
  if (scope == SolveScopeV1::kGlobal) {
    result.effective = requested;
    result.source = PtolSourceV1::kGlobalEnv;
  }
  return result;
}

inline const char* SolveScopeNameV1(SolveScopeV1 scope) {
  return scope == SolveScopeV1::kGlobal ? "global" : "local";
}

inline const char* PtolParseStatusNameV1(PtolParseStatusV1 status) {
  switch (status) {
    case PtolParseStatusV1::kMissing:
      return "missing";
    case PtolParseStatusV1::kEmpty:
      return "empty";
    case PtolParseStatusV1::kGarbage:
      return "garbage";
    case PtolParseStatusV1::kNonPositive:
      return "non_positive";
    case PtolParseStatusV1::kNonFinite:
      return "non_finite";
    case PtolParseStatusV1::kValid:
      return "valid";
  }
  return "unknown";
}

inline const char* PtolSourceNameV1(PtolSourceV1 source) {
  return source == PtolSourceV1::kGlobalEnv ? "global_env" : "base";
}

inline const char* PtolFallbackNameV1(const GlobalPtolResolutionV1& result) {
  if (result.source == PtolSourceV1::kGlobalEnv) return "none";
  if (result.source == PtolSourceV1::kBaseLocalScope) return "local_scope";
  return PtolParseStatusNameV1(result.parse_status);
}

}  // namespace aether::official::ba
