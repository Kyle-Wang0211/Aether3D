// official_gpu_watchdog_v1.h — framework worker 总巡逻员(Chromium watchdog 复刻)
//
// [GPU-HANG-B1 2026-08-06 二期件2] 逐字复刻 Chromium GPU watchdog 的挂死判定
// 机制(gpu/ipc/service/gpu_watchdog_thread.{h,cc},逐字源码快照在
// progecttwo/reference_upstream_snapshots/gpu_watchdog/),机制清单:
//   1. odd/even 原子计数器:Arm +1(变奇=armed)、Disarm +1(变偶=disarmed)、
//      InProgress +2(等价 Disarm+Arm,armed 态不变,任何线程可调),
//      IsArmed = 计数器 & 1。memory_order_relaxed 与上游一致(只要原子性
//      与最终一致,竞态读到旧值只是晚一拍发现进展,不影响正确性)。
//   2. 独立巡逻线程,周期 = 超时时长(默认 25s,与 Chromium Mac 档
//      kGpuWatchdogTimeout 同量级;env OFFICIAL_AETHER_WATCHDOG_TIMEOUT_MS
//      毫秒覆盖)。上游用 PostDelayedTask 自续任务,这里等价替换为
//      std::thread + condition_variable::wait_until 主循环(纯 std,零依赖)。
//   3. 每次到点(OnWatchdogTimeout 等价):disarmed || 计数器有进展 ||
//      SlowWatchdogThread → 无挂死,记账续期。SlowWatchdogThread = 墙钟
//      (system_clock)实际到点时刻比预期晚 ≥5s(上游 kUnreasonableTimeoutDelay)
//      → 系统整体慢(休眠/挂起/重度降频),豁免不判死。
//   4. 判死前二次确认(上游 DeliberatelyTerminateToRecoverFromHang 的
//      "crash dump 后 final check"等价):先记录诊断快照(耗时操作放中间,
//      给被守护线程一个最后窗口),再重读计数器 —— 有进展或已 disarm 则赦免。
//   5. 判死动作(单进程替换,上游是杀 GPU 进程由 browser 重启):
//      置原子 hang_detected 标志 + 经注入回调写一条 jsonl 遥测
//      (type:"watchdog_hang")。**不杀线程不杀进程** —— 一期纯观测,
//      供上层遥测与将来的恢复策略用。同一挂死片段只报一次
//      (观测到进展后解除,可再报)。
//
// 跨端铁律:纯 C++17 std(atomic/thread/condition_variable/chrono/functional),
// 无平台专属代码;回调注入切断对 session/jsonl 路径的直接依赖。
// 风格母版:official_mirror_ghost.h(单头文件,iOS 产品核与 host 工具同源)。
#pragma once

#include <atomic>
#include <chrono>
#include <condition_variable>
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <functional>
#include <mutex>
#include <string>
#include <thread>

namespace aether_gpu_watchdog_v1 {

// 上游 kGpuWatchdogTimeout(Mac)同量级默认值。
constexpr int64_t kDefaultTimeoutMs = 25000;
// 上游 kUnreasonableTimeoutDelay = base::Seconds(5):巡逻线程自身被墙钟
// 拖晚 ≥ 此值 → 慢系统豁免。
constexpr int64_t kUnreasonableTimeoutDelayMs = 5000;

inline int64_t TimeoutMsFromEnv() {
  const char* e = std::getenv("OFFICIAL_AETHER_WATCHDOG_TIMEOUT_MS");
  if (e != nullptr) {
    const long long ms = std::atoll(e);
    if (ms > 0) return static_cast<int64_t>(ms);
  }
  return kDefaultTimeoutMs;
}

class WatchdogV1 {
 public:
  // 判死回调:收到一条完整 JSON 行(不含换行),由接线方落盘
  // (production 接 AppendMatchFailJsonl → sfm_match_fail.jsonl)。
  // 在巡逻线程上调用;实现必须自带线程安全(open-append-close 即可)。
  using HangReportFn = std::function<void(const std::string& jsonl_line)>;

  WatchdogV1() = default;
  WatchdogV1(const WatchdogV1&) = delete;
  WatchdogV1& operator=(const WatchdogV1&) = delete;
  ~WatchdogV1() { Stop(); }

  // 启动巡逻线程。幂等:已启动则只更新回调。
  void Start(HangReportFn report) {
    std::lock_guard<std::mutex> lk(mutex_);
    report_ = std::move(report);
    if (thread_.joinable()) return;
    stop_requested_ = false;
    timeout_ms_ = TimeoutMsFromEnv();
    last_arm_disarm_counter_ = ReadArmDisarmCounter();
    thread_ = std::thread([this] { ThreadMain(); });
  }

  // 停止并 join 巡逻线程(析构自动调用)。
  void Stop() {
    {
      std::lock_guard<std::mutex> lk(mutex_);
      if (!thread_.joinable()) return;
      stop_requested_ = true;
    }
    cv_.notify_all();
    thread_.join();
  }

  // ── 被守护线程侧打点(上游 Arm/Disarm/InProgress/IsArmed 逐字对应)──
  // Arm/Disarm 成对调用(armed 段入口/出口);InProgress 任何线程可调。
  void Arm() { arm_disarm_counter_.fetch_add(1, std::memory_order_relaxed); }
  void Disarm() { arm_disarm_counter_.fetch_add(1, std::memory_order_relaxed); }
  // +2 == Disarm()+Arm():armed 保持 armed(报进展),disarmed 保持 disarmed。
  void InProgress() {
    arm_disarm_counter_.fetch_add(2, std::memory_order_relaxed);
  }
  bool IsArmed() const {
    return (arm_disarm_counter_.load(std::memory_order_relaxed) & 1) != 0;
  }
  int ReadArmDisarmCounter() const {
    return arm_disarm_counter_.load(std::memory_order_relaxed);
  }

  // ── 上层遥测/策略读口 ──
  bool hang_detected() const {
    return hang_detected_.load(std::memory_order_relaxed);
  }
  int64_t hang_count() const {
    return hang_count_.load(std::memory_order_relaxed);
  }

  // Arm 的 RAII 包装:入口 Arm、所有出口(含异常)Disarm。
  class ArmScope {
   public:
    explicit ArmScope(WatchdogV1& w) : w_(w) { w_.Arm(); }
    ~ArmScope() { w_.Disarm(); }
    ArmScope(const ArmScope&) = delete;
    ArmScope& operator=(const ArmScope&) = delete;

   private:
    WatchdogV1& w_;
  };

 private:
  static int64_t EpochMsNow() {
    using namespace std::chrono;
    return duration_cast<milliseconds>(system_clock::now().time_since_epoch())
        .count();
  }

  void ThreadMain() {
    using clock = std::chrono::steady_clock;
    auto next_fire = clock::now() + std::chrono::milliseconds(timeout_ms_);
    // 上游 next_on_watchdog_timeout_time_(墙钟)—— 慢系统豁免的对照钟。
    int64_t next_fire_wall_ms = EpochMsNow() + timeout_ms_;
    std::unique_lock<std::mutex> lk(mutex_);
    for (;;) {
      cv_.wait_until(lk, next_fire, [this, &next_fire] {
        return stop_requested_ || clock::now() >= next_fire;
      });
      if (stop_requested_) return;

      // ── OnWatchdogTimeout 等价 ──
      const int counter = ReadArmDisarmCounter();
      const bool disarmed = (counter % 2) == 0;
      const bool progress = counter != last_arm_disarm_counter_;
      // SlowWatchdogThread:墙钟实际到点比预期晚 ≥5s → 系统慢,豁免。
      const bool slow =
          (EpochMsNow() - next_fire_wall_ms) >= kUnreasonableTimeoutDelayMs;
      const bool no_hang = disarmed || progress || slow;

      if (no_hang) {
        if (disarmed || progress) {
          // 挂死片段结束(如果曾报过)—— 允许下一片段再报一次。
          hang_reported_this_episode_ = false;
        }
      } else if (!hang_reported_this_episode_) {
        // ── DeliberatelyTerminateToRecoverFromHang 等价(观测版)──
        // ① 先记诊断快照(上游此处做 crash dump —— 耗时窗口给被守护
        //    线程最后的进展机会)。
        char snap[384];
        std::snprintf(
            snap, sizeof(snap),
            "{\"t\":%lld,\"type\":\"watchdog_hang\",\"timeout_ms\":%lld,"
            "\"counter\":%d,\"last_counter\":%d,\"hang_count\":%lld}",
            static_cast<long long>(EpochMsNow()),
            static_cast<long long>(timeout_ms_), counter,
            last_arm_disarm_counter_,
            static_cast<long long>(hang_count_.load(
                std::memory_order_relaxed) + 1));
        // ② 二次确认:重读计数器 —— 有进展或已 disarm → 赦免
        //    (上游 final check: IsArmed() 为假则不杀)。
        const int recheck = ReadArmDisarmCounter();
        const bool still_hung = ((recheck % 2) != 0) && recheck == counter;
        if (still_hung) {
          hang_detected_.store(true, std::memory_order_relaxed);
          hang_count_.fetch_add(1, std::memory_order_relaxed);
          hang_reported_this_episode_ = true;
          // 单进程替换:不杀线程不杀进程,只落遥测。回调在锁外调用,
          // 避免与 Start/Stop 互锁。
          HangReportFn report = report_;
          lk.unlock();
          if (report) {
            try {
              report(std::string(snap));
            } catch (...) {
              // 遥测永不反噬巡逻线程
            }
          }
          lk.lock();
          if (stop_requested_) return;
        }
      }

      // ContinueWithNextWatchdogTimeoutTask 等价:记账 + 续期。
      last_arm_disarm_counter_ = ReadArmDisarmCounter();
      next_fire = clock::now() + std::chrono::milliseconds(timeout_ms_);
      next_fire_wall_ms = EpochMsNow() + timeout_ms_;
    }
  }

  // 被守护线程(可多线程 InProgress)写、巡逻线程读。
  std::atomic<int> arm_disarm_counter_{0};
  // 巡逻线程私有(上游同名成员)。
  int last_arm_disarm_counter_ = 0;
  bool hang_reported_this_episode_ = false;
  int64_t timeout_ms_ = kDefaultTimeoutMs;

  std::atomic<bool> hang_detected_{false};
  std::atomic<int64_t> hang_count_{0};

  std::mutex mutex_;
  std::condition_variable cv_;
  std::thread thread_;
  bool stop_requested_ = false;
  HangReportFn report_;
};

}  // namespace aether_gpu_watchdog_v1
