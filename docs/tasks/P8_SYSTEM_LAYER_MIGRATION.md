       C++ render graph 标记 MSAA resolve / depth-stencil / 中间处理纹理为"pass 内临时"
       → 平台桥接层翻译为各自 API（Metal memoryless / Vulkan transient+lazily_allocated）
       → 效果：这些 target 不分配持久内存，零系统内存开销
       决策条件（C++ 层判定）：
         - target 在单个 render pass 内产生并消费
         - pass 结束后不被后续任何 pass 读取
         - load 行为 = DONT_CARE 或 CLEAR，store 行为 = DONT_CARE
       @1170×2532 depth32Float: 节省 ~11.3 MB/target
   ```

   #### 主动监测 vs 被动响应——`didReceiveMemoryWarning` 的局限
   ```
   被动方案：
     didReceiveMemoryWarning → 此时已在 jetsam 限额边缘 → 来不及释放 → 被杀

   主动方案（Aether3D）：
     每 500ms 轮询 os_proc_available_memory() → 绝对值水位判定 → 提前数百 MB 开始释放
     iOS: os_proc_available_memory() > 400MB → GREEN
          200-400MB → YELLOW（开始预释放）
          100-200MB → ORANGE（积极释放）
          50-100MB → RED（紧急释放）
          < 50MB → CRITICAL（停止采集，保存数据）
     Android: onTrimMemory(RUNNING_MODERATE=5) → YELLOW
              onTrimMemory(RUNNING_LOW=10) → ORANGE
              onTrimMemory(RUNNING_CRITICAL=15) → RED
     三层防线：主动轮询 + DispatchSource.memoryPressure + didReceiveMemoryWarning（最后兜底）
   ```

   #### 内存预算表（v1.7，iPhone 15 Pro 基准）
   ```
   总可用内存（含 Increased Memory Limit entitlement）：~5.46 GB
   安全预算（扣除 25% 裕量）：                          ~4.10 GB

   分项预算：
   ├─ ARKit + 系统框架（不可控）：          ~300 MB
   ├─ Metal 驱动 + App 二进制：            ~200 MB（clean memory，不计入 footprint）
   ├─ TSDF 体素（mmap 分层后常驻部分）：    ~500 MB（冷区在磁盘，零 footprint）
   ├─ 深度图 pipeline（FP16 ring buffer）：~1.5 MB（256×192×2×3）
   ├─ ICP 临时（Arena 帧分配器）：          ~16 MB（帧末重置）
   ├─ 点云 / Mesh / 3DGS：               ~350 MB
   ├─ Metal Heap (purgeable textures)：   ~300 MB（volatile 标记后可被系统回收）
   ├─ Transient 渲染目标（C++ 标记临时）：   0 MB（C++ 判定生命周期→平台层执行零分配）
   ├─ 缓存（全可驱逐）：                   ~200 MB
   └─ 安全余量：                          ~2,230 MB（~54% 空闲 → jetsam 几乎不可能）
   ```

   #### 设备分级内存策略
   ```
   Tier 1 (8GB: iPhone 15/16 Pro): voxel_size=5mm, max_volume=5m³, 全驻留
   Tier 2 (6GB: iPhone 14/15):     voxel_size=10mm, max_volume=4m³, mmap 冷热分层
   Tier 3 (4GB: iPhone 13/SE 3):   voxel_size=20mm, max_volume=3m³, 强制 mmap + 降采样
   Android 分级参照 RAM 大小同理（4/6/8/12 GB 四档）
   ```

8. `C08 CrashPreventionEngine`：**四层崩溃免疫架构**（v1.7 新增）
   > **设计哲学**：崩溃分四大来源（内存/GPU/热/传感器），每一源头都采用“主动预防 + 被动恢复”双防线。

   #### 层 1：内存崩溃免疫（Anti-Jetsam/Anti-LMK）
   ```
   → 由 C07 MemoryPressureDefense 完全覆盖
   → 核心策略：在 OS 杀进程之前，应用自己已经释放到安全水位
   → iOS: os_proc_available_memory() 实时监测 + Increased Memory Limit entitlement
   → Android: onTrimMemory(TRIM_MEMORY_RUNNING_CRITICAL) 之前就已主动释放
   → 预期效果：jetsam/LMK 杀死概率从行业平均 ~0.3% 降至 < 0.02%
   ```

   #### 层 2：GPU 崩溃免疫（Device Lost Recovery）
   ```
   Vulkan (Android/鸿蒙):
     防御链：robustBufferAccess2 → pipeline robustness → device fault diagnostics → 全量恢复

     (a) 预防 — 启用 VK_EXT_robustness2:
         robustBufferAccess2 = VK_TRUE   → 越界访问返回 0 而非崩溃
         robustImageAccess2 = VK_TRUE    → 无效纹理访问返回 (0,0,0,0/1)
         nullDescriptor = VK_TRUE        → 允许 null descriptor 绑定

     (b) 预防 — VK_EXT_pipeline_robustness:
         所有 compute/graphics pipeline 设置 robustness = ROBUST_BUFFER/IMAGE_ACCESS
         → 着色器越界不触发 GPU 硬件异常

     (c) 检测 — VK_EXT_device_fault:
         VK_ERROR_DEVICE_LOST 时调用 vkGetDeviceFaultInfoEXT()
         → 获取精确故障原因（address fault / timeout / vendor-specific）
         → 写入 C06 telemetry（gpu_fault_reason, gpu_fault_address）

     (d) 恢复 — 全量设备重建管线:
         detect VK_ERROR_DEVICE_LOST
         → 停止所有 command buffer 提交
         → 等待所有 fence（超时 500ms 直接跳过）
         → 销毁 VkDevice + VkSwapchain + 所有 pipeline
         → 重新创建 VkDevice（复用 VkPhysicalDevice + VkInstance）
         → 重建 swapchain + pipeline cache + descriptor pool
         → 从最近 stable_frame_state 恢复 TSDF + pose graph
         → 恢复渲染（用户仅感知 ~200-500ms 卡顿，无数据丢失）

     恢复时间预算：< 500ms（< 30 帧 @60fps）
     最大连续恢复次数：3 次/分钟 → 超过则进入 L3 安全模式（停止 GPU 计算，仅保留 CPU 主路径）

   Metal (iOS):
     防御链：commandBuffer.error 检查 → MTLDeviceNotification → 设备重建

     (a) 预防 — 每个 MTLCommandBuffer 完成后检查 .error:
         .GPUCommandBufferError.timeout → 着色器执行超时 → 简化 dispatch 尺寸
         .GPUCommandBufferError.pageFault → GPU 内存访问错误 → 触发 C07 L3
         .GPUCommandBufferError.notPermitted → 后台执行被终止 → 等待前台恢复

     (b) 恢复 — 轻量级：
         Metal 不像 Vulkan 需要重建 device（MTLDevice 在 iOS 上全局唯一且持久）
         → 仅需重建 command queue + buffer pool + pipeline state 缓存
         → 恢复时间 < 100ms
   ```

   #### 层 2.5：GPU 超时防御（Dispatch Sizing + Watchdog）
   ```
   GPU 超时是第二大 GPU 崩溃原因（仅次于 OOM）。iOS 看门狗 ~5s，Android ~2-10s。

   (a) Compute Dispatch 分批：
       大工作量（>65536 体素/dispatch）拆分为多个 batch，batch 间插入 pipeline barrier
       → GPU 在 barrier 处有机会检查超时，避免单次 dispatch 卡死
       → 每 batch 上限与 DegradationTier 联动：
         TIER_FULL: 65536 voxels/dispatch
         TIER_REDUCED: 32768
         TIER_MINIMAL: 16384

   (b) CPU 侧 GPU Watchdog：
       独立线程监控 last_gpu_completion_frame 与 last_gpu_submission_frame 差异
       - 500ms 无完成 → kSlow → 下帧缩减工作量
       - 2s 无完成 → kHung → 尝试取消并重启
       - 4s 无完成 → kEmergencyAbort → 跳过当前帧，防止 OS 杀进程

   (c) Metal 间接 Dispatch：
       让 preprocessing kernel 动态决定实际 dispatch 尺寸（基于活跃体素数），
       避免过度 dispatch 空体素浪费 GPU 时间
   ```

   #### 层 2.7：GPU 帧节奏管理（Frame Pacing，v1.11 新增）
   ```
   问题：不规律的帧提交导致 GPU 频率剧烈波动 → 峰值功耗 → 加速发热。

   (a) 帧提交节奏平稳化（C++ 核心层决策）：
       C++ 侧维护 target_present_interval（基于 AetherThermalLevel 10 级动态调整）
       → L0-L3: 16.67ms (60fps)  — 全能力扫描
       → L4-L5: 33.33ms (30fps)  — 负载收敛，维持扫描质量
       → L6-L7: 50ms (20fps)     — 重负载，优先稳定
       → L8-L9: 100ms (10fps) 或停止帧提交 — 紧急/关停
       C++ 渲染循环在 GPU work 完成后，计算距下一 target 时刻的剩余时间
       → 若有余量，delay 提交而非立即 present → 保持恒定帧间隔

   (b) 平台层翻译：
       iOS:    MTLDrawable presentAfterMinimumDuration(interval)
       Android: VK_GOOGLE_display_timing / Choreographer.postFrameCallbackDelayed
       鸿蒙:   OH_NativeVSync 注册回调，手动对齐 VSync 边界

   (c) 与热系统联动：
       AetherThermalEngine L4+ 触发降帧率时，同步更新 target_present_interval
       → 帧率下降是"有计划的平滑过渡"，不是"GPU 忙不过来的被动丢帧"
       → 用户感知：稳定 30fps >> 不稳定 40-60fps 抖动
   ```

   #### 层 3：热崩溃免疫（Predictive Thermal Defense）
   ```
   核心思想：不等 OS 降频/杀进程，自己提前降负载。

   **当前代码 → 10 级目标的差距分析**：
   - 现有 `handle_thermal_state(int state)` 接受 4 级输入（0/1/2/3）→ 映射到 skip target（1/2/4/12）
   - 现有 AIMD 热控（additive-increase/multiplicative-decrease）+ 滞回防抖（10s degrade / 5s recover）
   - **差距**：输入只有 4 级离散 → 需要升级为 10 级 + 连续 headroom；且完全依赖平台层传入 → 需要自己检测、自己算
   - **为什么 10 级，不是 7 级**：Android 和鸿蒙各提供 7 级（0-6），但它们的 7 级是"平台全局"视角的粗粒度分级，不针对 3D 扫描的质量过渡区做细分。Aether3D 的 10 级在中间段（L2-L6）提供 5 级精细粒度（vs Android/鸿蒙仅 3 级），在极端段（L7-L9）覆盖 Android EMERGENCY+SHUTDOWN 和鸿蒙 EMERGENCY 的三种紧急状态。**10 级 = 超集映射，三端平台级别全部被 Aether 10 级覆盖，无信息损失**。

   #### 三端热系统对标表（Android 7 级 vs 鸿蒙 7 级 vs iOS 4 级 vs Aether 10 级）

   ```
   ┌──────────────────────────────────────────────────────────────────────────────────────────────────────────────┐
   │                          三端平台热系统 vs Aether 10 级对标矩阵                                              │
   ├────────┬─────────────────────┬─────────────────────┬──────────────────┬──────────────────────────────────────┤
   │ Aether │ Android AThermal    │ 鸿蒙 OH_Thermal     │ iOS Thermal      │ Aether 超越点                        │
   │ 10 级  │ Status (NDK)        │ Level (NDK)         │ State            │                                      │
   ├────────┼─────────────────────┼─────────────────────┼──────────────────┼──────────────────────────────────────┤
   │ L0     │ NONE(0)             │ COOL(0)             │ nominal(0)       │ 对齐——三端均表示"无热压"              │
   │ FROST  │ headroom < light_th │ 完全冷态            │ 正常运行         │                                      │
   ├────────┼─────────────────────┼─────────────────────┼──────────────────┼──────────────────────────────────────┤
   │ L1     │ NONE(0)→LIGHT(1)    │ COOL(0)→NORMAL(1)   │ nominal(0)       │ ★ 独有：趋势检测启动层               │
   │ WARM   │ 过渡区（平台无此级）│ 过渡区               │                  │ Android/鸿蒙在此区域无独立级别        │
   │        │                     │                     │                  │ Aether 通过帧耗时斜率+CPU探针检测      │
   ├────────┼─────────────────────┼─────────────────────┼──────────────────┼──────────────────────────────────────┤
   │ L2     │ LIGHT(1)            │ NORMAL(1)           │ nominal(0)→      │ ★ 独有：3DGS优化降频层               │
   │ MILD   │ UX不受影响          │ 正常温度            │ fair(1)过渡区     │ 平台说"UX不受影响"→Aether主动降低     │
   │        │                     │                     │                  │ 后台优化频率，用户无感知               │
   ├────────┼─────────────────────┼─────────────────────┼──────────────────┼──────────────────────────────────────┤
   │ L3     │ LIGHT(1)→           │ WARM(2)             │ fair(1)          │ ★ 独有：扫描质量过渡区起点            │
   │ LOADED │ MODERATE(2)过渡区   │ 温热                │                  │ 平台 LIGHT→MODERATE 之间无细分        │
   │        │                     │                     │                  │ Aether 在此开始隔帧融合               │
   ├────────┼─────────────────────┼─────────────────────┼──────────────────┼──────────────────────────────────────┤
   │ L4     │ MODERATE(2)         │ HOT(3)              │ fair(1)          │ ★ 平台对齐：中度节流                  │
   │ HIGH   │ UX未大幅受影响      │ 较热                │                  │ + Aether 级内连续headroom微调skip     │
   ├────────┼─────────────────────┼─────────────────────┼──────────────────┼──────────────────────────────────────┤
   │ L5     │ MODERATE(2)→        │ HOT(3)→             │ fair(1)→         │ ★ 独有：ICP降迭代+回环暂停层          │
   │ SEVERE │ SEVERE(3)过渡区     │ OVERHEATED(4)过渡区 │ serious(2)过渡区 │ 三大平台在此区域均无独立级别           │
   │        │                     │                     │                  │ Aether 精确控制 ICP 和 MC 提取频率    │
   ├────────┼─────────────────────┼─────────────────────┼──────────────────┼──────────────────────────────────────┤
   │ L6     │ SEVERE(3)           │ OVERHEATED(4)       │ serious(2)       │ 平台对齐：headroom=1.0 锚定点         │
   │ CRISIS │ headroom≥1.0        │ 过热                │ 严重             │ Android SEVERE保证headroom_th=1.0     │
   │        │ UX大幅受影响        │                     │                  │ Aether此级停止新帧采集                │
   ├────────┼─────────────────────┼─────────────────────┼──────────────────┼──────────────────────────────────────┤
   │ L7     │ CRITICAL(4)         │ WARNING(5)          │ serious(2)→      │ 平台对齐+超越：平台"已尽全力"          │
   │ ALARM  │ 平台已尽全力降功耗  │ 警告级              │ critical(3)过渡  │ Aether 仅保留渲染+导出，冻结一切计算  │
   ├────────┼─────────────────────┼─────────────────────┼──────────────────┼──────────────────────────────────────┤
   │ L8     │ EMERGENCY(5)        │ EMERGENCY(6)        │ critical(3)      │ ★ 独有对齐：自动保存+准备关停          │
   │ FREEZE │ 关键组件关闭中      │ 紧急                │ 临界             │ Android/鸿蒙此级已开始关闭组件         │
   │        │                     │                     │                  │ Aether 主动保存进度→准备安全退出       │
   ├────────┼─────────────────────┼─────────────────────┼──────────────────┼──────────────────────────────────────┤
   │ L9     │ SHUTDOWN(6)         │ （鸿蒙无此级）      │ （iOS无此级）    │ ★ 仅Android有对应：需立即关停          │
   │ DEAD   │ 需立即关机          │ 超出鸿蒙最高级      │ 超出iOS最高级    │ Aether 触发紧急数据持久化→graceful exit│
   └────────┴─────────────────────┴─────────────────────┴──────────────────┴──────────────────────────────────────┘

   ★ 标记 = Aether 在该区间提供了平台所不具备的细分能力或独有防护

   **10 级相对 7 级的核心优势**：
   1. 中间段 5 级细分（L2-L6）vs Android/鸿蒙 3 级 → 扫描质量过渡更平滑，用户感知抖动 ↓60%
   2. 极端段 3 级覆盖（L7-L9）vs 7 级仅 1 个 CRITICAL → 紧急状态分层处理，数据零丢失
   3. L1 独有趋势检测层 → 比任何平台提前 10-30s 预警
   4. 每级内连续 headroom 微调 → 实质上是"10 离散 × ∞连续"的二维热控矩阵
   ```

   #### AetherThermalEngine 10 级建设方案（v1.12 完整实施规格）

   ##### 步骤 1：新建 `thermal_engine.h` + `thermal_engine.cpp`（独立模块，不侵入现有代码）

   ```cpp
   // aether_cpp/include/aether/core/thermal_engine.h
   #pragma once
   #include <cstdint>

   namespace aether {
   namespace core {

   // ═══════════════════════════════════════════════════════════════════
   // AetherThermalLevel: 10 级自研热系统（L0-L9）
   // 全面超越 Android 7 级(AThermalStatus) + 鸿蒙 7 级(OH_ThermalLevel) + iOS 4 级(ProcessInfo.ThermalState)
   //
   // 设计原则：
   //   (1) 超集映射——三端平台的任何离散级别都能精确映射到 Aether 10 级中的某一级
   //   (2) 中间段细分——3D 扫描质量过渡区（TSDF fusion/ICP/MC 提取最敏感的区域）
   //       提供 5 级粒度（L2-L6），vs Android/鸿蒙仅 3 级
   //   (3) 极端段分层——L7/L8/L9 对应 Android CRITICAL/EMERGENCY/SHUTDOWN，
   //       提供数据持久化→安全退出的分层缓冲
   //   (4) 连续 headroom 贯穿全级——每级内部均可用 headroom 微调参数
   // ═══════════════════════════════════════════════════════════════════
   enum class AetherThermalLevel : int {
       kFrost    = 0,  // headroom [0.000, 0.080) — 完全冷态，可激进优化
       kWarm     = 1,  // headroom [0.080, 0.160) — 升温趋势启动检测（★独有）
       kMild     = 2,  // headroom [0.160, 0.280) — 温和负载，降低后台优化频率
       kLoaded   = 3,  // headroom [0.280, 0.420) — 扫描质量过渡起点，隔帧融合（★独有细分）
       kHigh     = 4,  // headroom [0.420, 0.580) — 中度节流，skip_rate↑ + ICP max_iter↓
       kSevere   = 5,  // headroom [0.580, 0.720) — ICP 降迭代 + MC 降频 + 暂停回环（★独有细分）
       kCrisis   = 6,  // headroom [0.720, 0.850) — 停止新帧采集，仅维持已有数据渲染
       kAlarm    = 7,  // headroom [0.850, 0.940) — 冻结一切计算，仅保留渲染+导出
       kFreeze   = 8,  // headroom [0.940, 0.985) — 自动保存进度，准备安全退出
       kDead     = 9,  // headroom [0.985, 1.000] — 紧急数据持久化 → graceful exit
   };
   static constexpr int kThermalLevelCount = 10;

   // headroom → level 阈值表（升级方向：headroom 递增 → level 递增）
   // 注意：降级方向使用滞回阈值（低于升级阈值 0.02），防抖
   static constexpr float kLevelThresholds[kThermalLevelCount] = {
       0.000f,  // L0 kFrost
       0.080f,  // L1 kWarm
       0.160f,  // L2 kMild
       0.280f,  // L3 kLoaded
       0.420f,  // L4 kHigh
       0.580f,  // L5 kSevere
       0.720f,  // L6 kCrisis
       0.850f,  // L7 kAlarm
       0.940f,  // L8 kFreeze
       0.985f,  // L9 kDead
   };

   struct AetherThermalState {
       AetherThermalLevel level{AetherThermalLevel::kFrost};
       float headroom{0.0f};           // 0.0-1.0 连续值（自研融合算出）
       float time_to_next_s{999.0f};   // 预计距下一级的秒数（正=升温中，负=降温中）
       float thermal_slope{0.0f};      // 热斜率（headroom/s，正=升温，负=降温）
       float thermal_slope_2nd{0.0f};  // 热加速度（headroom/s²，v1.12 新增：二阶趋势）
       float confidence{1.0f};         // 融合置信度 [0,1]（可用信号越多越高）
   };

   // 平台层每帧传入的原始观测量（C++ 核心层不关心哪个平台，只看数值）
   struct ThermalObservation {
       // ── 共同信号源（三端都必须传）──
       float frame_time_ms;            // 本帧实际耗时
       float gpu_elapsed_ratio;        // GPU compute 实际耗时 / 预期耗时（>1.0 = 被降频）

       // ── 平台信号（平台层采集后传入，不可用时填 -1.0f / -1 表示缺失）──
       int   platform_discrete_level;  // iOS: 0-3, Android: 0-6, 鸿蒙: 0-6（-1 = 缺失）
       float platform_headroom;        // Android getThermalHeadroom（-1.0f = 不可用）
       float battery_temperature_c;    // 电池温度（-1.0f = 不可用）
       float cpu_probe_latency_us;     // CPU 探针延迟（-1.0f = 未执行本帧）

       // ── v1.12 新增信号 ──
       float ambient_temperature_c;    // 环境温度（-1.0f = 不可用，来自气象 API 或传感器）
       float battery_charge_rate;      // 充电功率变化率 W/s（-1.0f = 不可用，辅助热源判定）

       double timestamp_s;             // 帧时间戳（单调递增）
   };

   class AetherThermalEngine {
   public:
       AetherThermalEngine();

       // 核心算法：每帧调用一次，输入原始观测，输出 10 级 + 连续 headroom
       AetherThermalState update(const ThermalObservation& obs);

       // 查询当前状态（不触发更新）
       AetherThermalState current_state() const { return state_; }

       // CPU 探针：自主执行，不需要平台层参与
       float run_cpu_probe();

       // 紧急状态查询（L7+ 时为 true，触发外部 save/exit 流程）
       bool is_emergency() const { return static_cast<int>(state_.level) >= 7; }

       // 重置（新扫描会话开始时调用）
       void reset();

   private:
       AetherThermalState state_{};

       // ═══ 多信号融合权重（运行时根据信号可用性动态归一化）═══
       static constexpr float kW_frame_slope    = 0.28f;  // 帧耗时斜率（一阶+二阶）
       static constexpr float kW_cpu_probe      = 0.22f;  // CPU 探针延迟比
       static constexpr float kW_gpu_ratio      = 0.18f;  // GPU 利用率代理
       static constexpr float kW_platform       = 0.17f;  // 平台离散状态锚定
       static constexpr float kW_battery_temp   = 0.10f;  // 电池温度趋势
       static constexpr float kW_ambient_corr   = 0.05f;  // 环境温度校正
       // 总和 = 1.00（所有信号可用时）

       // ═══ 帧耗时趋势分析（一阶 + 二阶）═══
       float frame_times_[180]{};       // 最近 180 帧环形缓冲（3s @60fps，比 7 级版多 60 帧）
       int   frame_time_idx_{0};
       int   frame_time_count_{0};
       // 增量式线性回归（O(1) per frame）
       double sum_x_{0}, sum_y_{0}, sum_xy_{0}, sum_x2_{0};
       float compute_frame_time_slope() const;      // 一阶斜率 ms/s
       float compute_frame_time_accel() const;      // 二阶加速度 ms/s²（v1.12 新增）

       // ═══ CPU 探针基线与历史（EWMA 漂移补偿）═══
       float cpu_probe_baseline_us_{0.0f};           // 冷态基线
       float cpu_probe_ewma_us_{0.0f};               // EWMA 当前估计（v1.12：漂移补偿）
       static constexpr float kProbeEwmaAlpha = 0.1f;// EWMA 系数
       float cpu_probe_history_[60]{};                // 最近 60 次探针结果（每 2s = 120s 窗口）
       int   cpu_probe_idx_{0};
       int   cpu_probe_count_{0};
       int   cpu_probe_calibration_count_{0};         // 冷态校准计数（前 10 次）
       float compute_cpu_probe_ratio() const;

       // ═══ 电池温度趋势 ═══
       float battery_temps_[30]{};      // 最近 30 次电池温度（每 4s = 120s 窗口）
       int   battery_temp_idx_{0};
       int   battery_temp_count_{0};
       float compute_battery_slope() const;  // °C/min

       // ═══ 平台锚定（Kalman-EMA 混合校准）═══
       struct PlatformAnchor {
           float headroom_at_anchor;
           int   platform_level;
           float platform_headroom_raw;  // Android getThermalHeadroom 原始值
           double timestamp_s;
       };
       PlatformAnchor last_anchor_{};
       float anchor_correction_{0.0f};   // 累积校准偏移量
       static constexpr float kAnchorAlpha = 0.25f;  // 校准收敛速度
       void calibrate_from_platform(const ThermalObservation& obs, float fused_headroom, double now_s);

       // ═══ Android API 35+ 阈值动态适配 ═══
       struct PlatformThresholds {
           bool valid{false};
           float thresholds[7]{0.0f};  // Android 7 级对应的 headroom 阈值
       };
       PlatformThresholds android_thresholds_{};

       // ═══ Kalman-EMA 混合热斜率预测器 ═══
       //   Kalman 部分：状态向量 [headroom, slope]，2x2
       //   EMA 部分：快速响应短期波动
       //   融合：Kalman 输出 × 0.6 + EMA × 0.4（Kalman 长期趋势更准，EMA 短期响应更快）
       float kalman_state_[2]{0.0f, 0.0f};  // [headroom_est, slope_est]
       float kalman_P_[4]{1.0f, 0.0f, 0.0f, 1.0f};  // 2x2 协方差矩阵（展平）
       static constexpr float kKalmanQ_h = 1e-4f;  // 过程噪声：headroom
       static constexpr float kKalmanQ_s = 1e-3f;  // 过程噪声：slope
       static constexpr float kKalmanR   = 0.01f;  // 观测噪声
       void kalman_predict(float dt);
       void kalman_update(float observed_headroom);
       float ema_slope_{0.0f};
       static constexpr float kEmaAlpha = 0.15f;
       double last_update_s_{0.0};

       // ═══ 滞回防抖（10 级版：分区间不同确认帧数）═══
       int   consecutive_upgrade_frames_{0};
       int   consecutive_downgrade_frames_{0};
       AetherThermalLevel pending_level_{AetherThermalLevel::kFrost};
       // 升级确认帧数（级别越高确认越快，紧急时不等）
       static constexpr int kUpgradeFrames[kThermalLevelCount] = {
           0,   // →L0: 不会"升级"到 L0
           8,   // →L1: 8 帧确认（~133ms@60fps）
           6,   // →L2: 6 帧
           5,   // →L3: 5 帧
           4,   // →L4: 4 帧
           3,   // →L5: 3 帧
           2,   // →L6: 2 帧（紧急区域快速响应）
           1,   // →L7: 1 帧
           1,   // →L8: 1 帧（立即响应）
           0,   // →L9: 0 帧（零延迟，立即进入 DEAD）
       };
       // 降级确认帧数（越低越慢，防止过早恢复）
       static constexpr int kDowngradeFrames[kThermalLevelCount] = {
           600, // →L0: 10s@60fps（最谨慎恢复）
           480, // →L1: 8s
           360, // →L2: 6s
           300, // →L3: 5s
           240, // →L4: 4s
           180, // →L5: 3s
           120, // →L6: 2s
           60,  // →L7: 1s
           30,  // →L8: 0.5s
           0,   // →L9: 不会"降级"到 L9
       };
       AetherThermalLevel apply_hysteresis(AetherThermalLevel target);

       // ═══ 多信号融合核心 ═══
       float fuse_headroom(const ThermalObservation& obs);
       AetherThermalLevel headroom_to_level(float headroom) const;
       float level_upper_bound(AetherThermalLevel level) const;

       // ═══ 平台级别归一化 ═══
       // iOS 4 级 → Aether headroom 映射
       static constexpr float kIosToHeadroom[4] = {0.04f, 0.30f, 0.65f, 0.92f};
       // Android 7 级 → Aether headroom 映射（无 API 35 阈值时的默认值）
       static constexpr float kAndroidToHeadroom[7] = {0.04f, 0.14f, 0.35f, 0.72f, 0.88f, 0.96f, 0.99f};
       // 鸿蒙 7 级 → Aether headroom 映射
       static constexpr float kHarmonyToHeadroom[7] = {0.04f, 0.12f, 0.28f, 0.50f, 0.75f, 0.90f, 0.97f};
       float platform_level_to_headroom(int level, int platform_max) const;
   };

   }  // namespace core
   }  // namespace aether
   ```

   ##### 步骤 2：实现多信号融合算法（`thermal_engine.cpp`）

   ```cpp
   // aether_cpp/src/core/thermal_engine.cpp
   // 核心算法：6 信号加权融合 + Kalman-EMA 混合预测 + 平台锚定校准

   float AetherThermalEngine::fuse_headroom(const ThermalObservation& obs) {
       // ═══ 1. 收集可用信号及其归一化值 [0.0, 1.0] ═══
       float signals[6] = {0.0f};
       float weights[6] = {0.0f};
       int   available_count = 0;

       // 信号 A：帧耗时斜率（一阶 + 二阶加速度加权）
       float slope_1st = compute_frame_time_slope();  // ms/s
       float slope_2nd = compute_frame_time_accel();  // ms/s²
