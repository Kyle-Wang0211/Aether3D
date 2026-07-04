// [AETHER PROGRESS] Real staged progress for the on-device reconstruction
// pipeline (weighted stage budget + in-stage counters + monotonic clamp).
//
// Design (2026-07-04, replaces the time-based placeholder ticker that pinned
// and got the BGContinuedProcessingTask expired):
//   - stage axis = pipeline POSITION, never model quality: stages only advance
//     (retri-BA is a LATER segment, not a revisit of the BA segment);
//   - in-stage fraction comes only from monotone counters (items done / ceres
//     iteration index). Stage-scoped: hooks pass their stage id and are
//     ignored unless that stage is current (kills cross-pollution when BA
//     solvers re-run inside retriangulation);
//   - stages with no counter creep asymptotically toward their cap on wall
//     time and only jump to cap when the next stage begins;
//   - a single monotonic clamp at the read boundary guarantees the UI can
//     never see progress regress.
//
// C ABI on purpose: consumed from glomap-src C++ hooks, bench C++, and the
// iOS app's Objective-C umbrella without any header plumbing.

#include <algorithm>
#include <atomic>
#include <ctime>

namespace {
std::atomic<int> g_stage{0};
std::atomic<long> g_done{0};
std::atomic<long> g_total{0};
std::atomic<long> g_stage_t0{0};
std::atomic<int> g_permille{0};
// wall time of the last visible permille increase — drives the anti-stall
// nudge (measured 2026-07-04: the system expires a continued-processing task
// after ~60-90s of frozen progress; stage-5's two sequential ceres solves
// share one ratcheting iteration counter, so solve #2's early iterations are
// swallowed and the bar froze ~60s at 637‰ → BGTASK_EXPIRED)
std::atomic<long> g_last_move_t{0};

// Permille budget per stage, from measured phase splits (coarse; recalibrate
// from aether_phase_rss timestamps per device tier when telemetry lands).
// 0 idle, 1 relpose, 2 rotavg, 3 tracks, 4 global positioning,
// 5 internal BA, 6 retriangulation(+convert tail), 7 extra CAUCHY BA,
// 8 write, 9 done
// [v5.3] per-10000 scale: the system's stuck-task heuristic reads ONLY integer
// completedUnitCount jumps (DTS-confirmed, FB21338185; forum-measured floor
// ~1 unit / 10-20s). Finer units = every relpose pair / ceres iteration is an
// integer jump, and the anti-stall nudge (8s) always clears the floor.
constexpr int kBase[10] = {0, 100, 1100, 1900, 2400, 5400, 6900, 8100, 9750, 10000};
constexpr int kCap[10] = {100, 1100, 1900, 2400, 5400, 6900, 8100, 9750, 10000, 10000};
}  // namespace

extern "C" void aether_progress_stage(int stage) {
  if (stage < 0 || stage > 9) return;
  int cur = g_stage.load(std::memory_order_relaxed);
  if (stage <= cur) return;  // pipeline position only moves forward
  g_stage.store(stage, std::memory_order_relaxed);
  g_done.store(0, std::memory_order_relaxed);
  g_total.store(0, std::memory_order_relaxed);
  g_stage_t0.store((long)time(nullptr), std::memory_order_relaxed);
}

extern "C" void aether_progress_items(int stage, long done, long total) {
  if (stage != g_stage.load(std::memory_order_relaxed)) return;  // stage-scoped
  long d = g_done.load(std::memory_order_relaxed);
  while (done > d &&
         !g_done.compare_exchange_weak(d, done, std::memory_order_relaxed)) {
  }
  if (total > 0) g_total.store(total, std::memory_order_relaxed);
}

extern "C" int aether_progress_stage_get(void) {
  return g_stage.load(std::memory_order_relaxed);
}

extern "C" int aether_progress_permille(void) {
  int s = g_stage.load(std::memory_order_relaxed);
  double frac;
  long total = g_total.load(std::memory_order_relaxed);
  if (total > 0) {
    frac = std::min(
        1.0, (double)g_done.load(std::memory_order_relaxed) / (double)total);
  } else {
    long dt = (long)time(nullptr) - g_stage_t0.load(std::memory_order_relaxed);
    if (dt < 0) dt = 0;
    // asymptotic creep: ~50% of the segment at 45s, ~80% at 3min, never 100%
    frac = 1.0 - 1.0 / (1.0 + (double)dt / 45.0);
  }
  int p = kBase[s] + (int)(frac * (kCap[s] - kBase[s]));
  if (p > kCap[s]) p = kCap[s];
  int last = g_permille.load(std::memory_order_relaxed);
  long now = (long)time(nullptr);
  if (p <= last) {
    // anti-stall nudge: counters can legitimately freeze for minutes (bg
    // throttling stretches single ceres iterations to 20-60s; solve #2's
    // ratcheted early iterations). +1‰ per 15s of no real movement, capped
    // BELOW the segment cap — never a false completion, monotone, and the
    // real counter reclaims the bar the moment it moves again.
    long lm = g_last_move_t.load(std::memory_order_relaxed);
    if (lm == 0) {
      g_last_move_t.store(now, std::memory_order_relaxed);
    } else if (now - lm >= 8 && last + 1 < kCap[s]) {
      p = last + 1;  // 8s: comfortably under the ~10-20s/unit system floor
    }
  }
  while (p > last &&
         !g_permille.compare_exchange_weak(last, p, std::memory_order_relaxed)) {
  }
  if (p > last) g_last_move_t.store(now, std::memory_order_relaxed);
  return g_permille.load(std::memory_order_relaxed);
}
