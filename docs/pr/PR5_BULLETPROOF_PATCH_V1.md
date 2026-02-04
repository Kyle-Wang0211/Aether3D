# PR5 v1.2 BULLETPROOF PATCH - PRODUCTION-HARDENED CAPTURE SYSTEM
 
> **Version**: 1.2.0
> **Base**: PR5_PATCH_V1_1_HARDENING.md
> **Focus**: 60 Production-Critical Hardening Measures
> **Research**: 2024-2025 State-of-the-Art + Real-World Failure Analysis
> **Status:** DRAFT
> **Created:** 2026-02-03
> **Dependencies:** PR2 (Evidence System), PR3 (Gate System), PR4 (Soft System)
 
---
 
## EXECUTIVE SUMMARY
 
This v1.2 patch addresses **60 critical production vulnerabilities** that will cause failures in real-world deployment scenarios:
 
- **Real devices**: Different ISP pipelines, EIS distortion, lens switching
- **Real networks**: Upload failures, bandwidth constraints, offline operation
- **Real lighting**: HDR scenes, mixed illuminants, rapid transitions
- **Real users**: Erratic motion, interruptions, multi-session workflows
 
The patch is organized into **12 PARTs** covering the complete capture pipeline from sensor to cloud.
 
### 关键改进亮点
 
1. **传感器层面**：ISP 检测、曝光锁定验证、镜头切换检测、EIS/滚动快门处理
2. **状态机强化**：滞回阈值防止振荡、统一策略解析器协调决策
3. **帧处置保证**：延迟决策 SLA、最小进度保证、姿态链保护
4. **质量度量**：全局一致性探测、平移-视差耦合、度量独立性检查
5. **动态场景**：反射感知检测、自适应掩码膨胀、两阶段账本提交
6. **纹理响应**：重复纹理主动响应策略、漂移轴引导
7. **曝光颜色**：锚点过渡混合、光照不变特征
8. **隐私合规**：差分隐私描述符、可验证删除证明、密钥轮换
9. **审计模式**：封闭集审计模式，版本化控制
10. **跨平台**：统计距离夹具、Web 平台回退
11. **性能预算**：紧急降级路径、内存签名跟踪
12. **测试验证**：质量门控验收、确定性回归集
 
---
 
## 实施架构
 
### 核心文件结构
 
```
Core/Capture/PR5/
├── Constants/
│   └── PR5CaptureConstants.swift          # 所有常量定义（100+）
├── Sensor/
│   ├── ISPDetector.swift                  # ISP 检测与补偿
│   ├── ExposureLockVerifier.swift        # 曝光锁定验证
│   ├── LensChangeDetector.swift          # 镜头切换检测
│   ├── EISRollingShutterHandler.swift    # EIS/滚动快门处理
│   └── FramePacingNormalizer.swift       # 帧率归一化
├── StateMachine/
│   ├── HysteresisStateMachine.swift      # 滞回状态机
│   └── CapturePolicyResolver.swift       # 统一策略解析器
├── Disposition/
│   ├── DeferDecisionManager.swift        # 延迟决策管理
│   ├── MinimumProgressGuarantee.swift   # 最小进度保证
│   └── PoseChainPreserver.swift          # 姿态链保护
├── Quality/
│   ├── GlobalConsistencyProbe.swift      # 全局一致性探测
│   ├── TranslationParallaxCoupler.swift   # 平移-视差耦合
│   └── MetricIndependenceChecker.swift   # 度量独立性检查
├── Dynamic/
│   ├── ReflectionAwareDynamicDetector.swift # 反射感知动态检测
│   ├── AdaptiveMaskDilator.swift         # 自适应掩码膨胀
│   └── TwoPhaseLedgerCommit.swift        # 两阶段账本提交
├── Texture/
│   ├── RepetitionResponsePolicy.swift    # 重复纹理响应策略
│   └── DriftAxisGuidance.swift           # 漂移轴引导
├── Exposure/
│   ├── AnchorTransitionBlender.swift      # 锚点过渡混合
│   └── IlluminationInvariantFeatures.swift # 光照不变特征
├── Privacy/
│   ├── DifferentialPrivacyDescriptors.swift # 差分隐私描述符
│   ├── VerifiableDeletionProof.swift     # 可验证删除证明
│   └── KeyRotationPlan.swift             # 密钥轮换计划
├── Audit/
│   └── ClosedSetAuditSchema.swift         # 封闭集审计模式
├── Platform/
│   ├── StatisticalDistanceFixtures.swift # 统计距离夹具
│   └── WebPlatformFallback.swift         # Web 平台回退
├── Performance/
│   ├── EmergencyDegradationPath.swift    # 紧急降级路径
│   └── MemorySignatureTracker.swift      # 内存签名跟踪
└── Testing/
    ├── QualityGatedAcceptance.swift       # 质量门控验收
    └── DeterministicRegressionSet.swift   # 确定性回归集
```
 
---
 
## PART 0: SENSOR AND CAMERA PIPELINE HARDENING
 
### 0.1 ISP (Image Signal Processor) Detection and Bypass
 
**问题**：不同设备应用不可见的 ISP 处理（降噪、锐化、局部对比度、HDR 色调映射），破坏"原始"帧。你以为有原始数据，但已经被处理过了。
 
**研究参考**：
- "Deep Learning ISP Survey" (ACM Computing Surveys 2024)
- "ParamISP: Learning Camera-Specific ISP Parameters" (CVPR 2024)
- "InvISP: Invertible Image Signal Processing" (CVPR 2021)
 
**解决方案**：ISP 检测与能力门控策略
 
**实施文件**：`Core/Capture/PR5/Sensor/ISPDetector.swift`
 
**关键常量**：
- `ISP_DETECTION_SAMPLE_FRAMES: Int = 10`
- `ISP_NOISE_FLOOR_THRESHOLD: Double = 0.02`
- `ISP_SHARPENING_DETECTION_THRESHOLD: Double = 0.15`
- `ISP_HDR_TONE_CURVE_DEVIATION: Double = 0.1`
 
**核心功能**：
- 噪声底分析（MAD 方法）
- 锐化检测（LoG 分析）
- 色调曲线分析（CDF 偏差）
- 补偿策略推荐（fullLedger/reducedAssistGain/textureBoostPenalty/conservativeKeyframe）
 
### 0.2 Exposure Lock Verification
 
**问题**：iOS/Android "曝光锁定"在不同设备/OS 版本上语义不一致。某些设备只锁定 EV，不锁定 ISO/快门。WB 锁定可能是假的。
 
**解决方案**：锁定后验证与回退策略
 
**实施文件**：`Core/Capture/PR5/Sensor/ExposureLockVerifier.swift`
 
**关键常量**：
- `EXPOSURE_LOCK_VERIFY_FRAMES: Int = 5`
- `EXPOSURE_LOCK_ISO_DRIFT_TOLERANCE: Double = 0.05`
- `EXPOSURE_LOCK_SHUTTER_DRIFT_TOLERANCE: Double = 0.05`
- `WB_LOCK_VERIFY_TEMPERATURE_DRIFT_K: Double = 100.0`
 
**核心功能**：
- 锁定状态分类（trueLock/evOnlyLock/pseudoLock/noLock）
- 参数漂移检测
- 补偿动作推荐（none/useSegmentedAnchors/increaseDriftPenalty/abandonLock）
 
### 0.3 Lens/Camera Switch Detection
 
**问题**：用户缩放手势或系统自动切换可能改变相机（广角/超广角/长焦），导致内参跳变，破坏重建。
 
**研究参考**：
- "Multi-Camera Visual Odometry (MCVO)" (arXiv 2024)
- "MASt3R-SLAM: Calibration-Free SLAM" (CVPR 2025)
 
**解决方案**：内参监控与自动会话分段
 
**实施文件**：`Core/Capture/PR5/Sensor/LensChangeDetector.swift`
 
**关键常量**：
- `LENS_FOCAL_LENGTH_JUMP_THRESHOLD: Double = 0.1`
- `LENS_FOV_JUMP_THRESHOLD: Double = 5.0`
- `LENS_SWITCH_COOLDOWN_MS: Int64 = 500`
- `MAX_SEGMENTS_PER_SESSION: Int = 10`
 
**核心功能**：
- 镜头切换事件检测
- 会话分段管理（隔离跨段特征匹配）
- 段内关键帧计数
 
### 0.4 EIS/Rolling Shutter Distortion Handling
 
**问题**：电子图像稳定（EIS）扭曲几何。滚动快门创建扫描线相关姿态。两者如不处理会破坏重建。
 
**研究参考**：
- "GaVS: Gaussian Splatting for Video Stabilization" (2025)
- "RS-ORB-SLAM3: Rolling Shutter Compensation" (GitHub 2024)
 
**解决方案**：能力检测与策略调整
 
**实施文件**：`Core/Capture/PR5/Sensor/EISRollingShutterHandler.swift`
 
**关键常量**：
- `EIS_DETECTION_THRESHOLD: Double = 0.2`
- `ROLLING_SHUTTER_READOUT_TIME_MS: Double = 33.0`
- `MAX_SAFE_ANGULAR_VELOCITY_RAD_S: Double = 0.5`
- `EIS_ENABLED_WEIGHT_REPROJ: Double = 0.5`
- `EIS_ENABLED_WEIGHT_SCALE: Double = 1.5`
 
**核心功能**：
- 稳定化能力检测（EIS/OIS）
- RS 补偿策略（权重调整）
- 关键帧适用性检查（角速度限制）
 
### 0.5 Frame Pacing Normalization
 
**问题**：帧率变化（24/30/60fps），基于帧数的窗口阈值变得不正确。
 
**解决方案**：所有窗口基于时间（ms）定义，帧数派生
 
**实施文件**：`Core/Capture/PR5/Sensor/FramePacingNormalizer.swift`
 
**关键常量**：
- `FRAME_RATE_ESTIMATION_WINDOW_MS: Int64 = 1000`
- `MIN_SUPPORTED_FPS: Double = 15.0`
- `MAX_SUPPORTED_FPS: Double = 120.0`
- `FRAME_DROP_DETECTION_THRESHOLD_MS: Double = 50.0`
 
**核心功能**：
- FPS 估计（滑动窗口）
- 丢帧检测
- 时间窗口到帧数转换
 
---
 
## PART 1: STATE MACHINE HARDENING
 
### 1.1 Hysteresis-Based State Transitions
 
**问题**：条件在阈值附近徘徊时状态振荡。
 
**研究参考**：
- "Schmitt Trigger Patterns for Embedded Systems" (2024)
- "Dead Zone in Control Systems" (2024)
 
**解决方案**：双阈值（进入/退出）与强制冷却
 
**实施文件**：`Core/Capture/PR5/StateMachine/HysteresisStateMachine.swift`
 
**关键常量**：
- `LOW_LIGHT_ENTRY_THRESHOLD: Double = 0.12`
- `LOW_LIGHT_EXIT_THRESHOLD: Double = 0.20`
- `WEAK_TEXTURE_ENTRY_THRESHOLD: Int = 60`
- `WEAK_TEXTURE_EXIT_THRESHOLD: Int = 100`
- `HIGH_MOTION_ENTRY_THRESHOLD: Double = 1.0`
- `HIGH_MOTION_EXIT_THRESHOLD: Double = 0.5`
- `STATE_TRANSITION_COOLDOWN_MS: Int64 = 1000`
- `EMERGENCY_TRANSITION_OVERRIDE: Bool = true`
 
**核心功能**：
- 滞回阈值管理
- 状态优先级排序（thermalThrottle > highMotion > lowLight > weakTexture > normal）
- 紧急转换覆盖
- 确认帧计数
 
### 1.2 Unified Policy Resolver
 
**问题**：状态机、预算系统和其他模块做出冲突决策。
 
**解决方案**：单一策略解析器仲裁所有决策
 
**实施文件**：`Core/Capture/PR5/StateMachine/CapturePolicyResolver.swift`
 
**关键常量**：
- `POLICY_UPDATE_INTERVAL_MS: Int64 = 100`
 
**核心功能**：
- 统一策略结构（曝光/质量/增强/关键帧/预算）
- 状态到策略映射
- 预算约束应用（只能限制，不能扩展）
- ISP 补偿应用
 
---
 
## PART 2: FRAME DISPOSITION HARDENING
 
### 2.1 Defer Decision SLA Enforcement
 
**问题**：`deferDecision` 帧无界累积，导致 OOM 或混乱的稀疏化。
 
**解决方案**：严格 SLA 与自动解析
 
**实施文件**：`Core/Capture/PR5/Disposition/DeferDecisionManager.swift`
 
**关键常量**：
- `DEFER_MAX_LATENCY_MS: Int64 = 500`
- `DEFER_MAX_QUEUE_DEPTH: Int = 30`
- `DEFER_TIMEOUT_ACTION: DeferTimeoutAction = .keepRawOnly`
 
**核心功能**：
- 延迟原因封闭集（budget/imu/depth/motion/dynamic/thermal）
- 队列深度限制
- 超时自动解析（keepRawOnly/discardBoth/forceDecision）
- 原因分解统计
 
### 2.2 Minimum Progress Guarantee
 
**问题**：弱纹理/低光下连续 `discardBoth` 导致"永不增亮"死锁。
 
**解决方案**：进度保证防止完全停滞
 
**实施文件**：`Core/Capture/PR5/Disposition/MinimumProgressGuarantee.swift`
 
**关键常量**：
- `PROGRESS_STALL_DETECTION_MS: Int64 = 3000`
- `PROGRESS_STALL_FRAME_COUNT: Int = 60`
- `PROGRESS_GUARANTEE_DELTA_MULTIPLIER: Double = 0.3`
- `PROGRESS_GUARANTEE_MAX_CONSECUTIVE_DISCARDS: Int = 30`
 
**核心功能**：
- 停滞检测（时间/帧数/连续丢弃）
- 自动激活保证（强制 keepRawOnly，降低 delta）
- 进度记录
 
### 2.3 Pose Chain Preservation
 
**问题**：`keepRawOnly` 如果辅助数据需要匹配，会破坏姿态跟踪链。
 
**解决方案**：即使 keepRawOnly 也保留最小跟踪摘要
 
**实施文件**：`Core/Capture/PR5/Disposition/PoseChainPreserver.swift`
 
**关键常量**：
- `POSE_CHAIN_MIN_FEATURES: Int = 20`
- `POSE_CHAIN_PRESERVE_IMU: Bool = true`
- `POSE_CHAIN_SUMMARY_MAX_BYTES: Int = 4096`
 
**核心功能**：
- 稀疏特征提取（最佳响应）
- IMU 数据保留
- 姿态估计保留
- 大小约束验证
 
---
 
## PART 3: QUALITY METRIC HARDENING
 
### 3.1 Global Consistency Probe
 
**问题**：高 `featureTrackingRate` 可能来自重复纹理/镜面表面。
 
**解决方案**：定期 mini-BA/PnP 验证"稳定"特征
 
**实施文件**：`Core/Capture/PR5/Quality/GlobalConsistencyProbe.swift`
 
**关键常量**：
- `CONSISTENCY_PROBE_INTERVAL_FRAMES: Int = 30`
- `CONSISTENCY_PROBE_SAMPLE_SIZE: Int = 50`
- `CONSISTENCY_PROBE_REPROJ_THRESHOLD_PX: Double = 3.0`
- `CONSISTENCY_PROBE_MIN_PASS_RATE: Double = 0.7`
- `CONSISTENCY_PROBE_FAILURE_PENALTY: Double = 0.5`
 
**核心功能**：
- 分层采样特征
- 重投影误差计算
- 一致性分数计算
- 质量乘数应用
 
### 3.2 Translation-Parallax Coupling
 
**问题**：纯旋转看起来像高视差但不提供 3D 信息。
 
**解决方案**：视差分数与平移证据耦合
 
**实施文件**：`Core/Capture/PR5/Quality/TranslationParallaxCoupler.swift`
 
**关键常量**：
- `MIN_TRANSLATION_FOR_PARALLAX_M: Double = 0.02`
- `PURE_ROTATION_PARALLAX_PENALTY: Double = 0.3`
- `PARALLAX_TRANSLATION_COUPLING_WEIGHT: Double = 0.5`
 
**核心功能**：
- 平移比率计算（相对于场景深度）
- 纯旋转检测
- 耦合分数计算（惩罚纯旋转，提升良好基线）
 
### 3.3 Multi-Source Metric Independence Check
 
**问题**：从相同 ARKit/ARCore 源派生的度量可能共享错误。
 
**解决方案**：要求独立源之间一致
 
**实施文件**：`Core/Capture/PR5/Quality/MetricIndependenceChecker.swift`
 
**关键常量**：
- `METRIC_DISAGREEMENT_THRESHOLD: Double = 0.3`
- `METRIC_DISAGREEMENT_PENALTY: Double = 0.4`
- `MIN_INDEPENDENT_SOURCES: Int = 2`
 
**核心功能**：
- 源分组（visual/depth/imu/arPlatform/semantic）
- 源间一致性检查
- 加权最终值计算
- 不一致惩罚
 
---
 
## PART 4: DYNAMIC SCENE HARDENING
 
### 4.1 Reflection-Aware Dynamic Detection
 
**问题**：反射/屏幕显示运动触发假动态检测。
 
**研究参考**：
- "3DRef: 3D Dataset and Benchmark for Reflection Detection" (3DV 2024)
- "TraM-NeRF: Reflection Tracing for NeRF" (CGF 2024)
 
**解决方案**：结合动态检测与平面性和镜面分析
 
**实施文件**：`Core/Capture/PR5/Dynamic/ReflectionAwareDynamicDetector.swift`
 
**关键常量**：
- `REFLECTION_PLANARITY_THRESHOLD: Double = 0.9`
- `REFLECTION_SPECULAR_RATIO_THRESHOLD: Double = 0.3`
- `REFLECTION_DYNAMIC_PENALTY_REDUCTION: Double = 0.7`
- `SCREEN_DETECTION_ASPECT_RATIOS: [Double] = [16.0/9.0, 4.0/3.0, 21.0/9.0]`
 
**核心功能**：
- 平面性检查（深度方差）
- 镜面比率计算
- 屏幕宽高比检测
- 表面类型分类（realDynamic/reflectionLikely/screenLikely/uncertain）
- 惩罚乘数应用
 
### 4.2 Adaptive Mask Dilation
 
**问题**：固定膨胀杀死几何边缘。
 
**解决方案**：基于流不确定性的自适应膨胀与边缘保护
 
**实施文件**：`Core/Capture/PR5/Dynamic/AdaptiveMaskDilator.swift`
 
**关键常量**：
- `DILATION_MIN_RADIUS: Int = 3`
- `DILATION_MAX_RADIUS: Int = 20`
- `DILATION_FLOW_UNCERTAINTY_SCALE: Double = 2.0`
- `DILATION_EDGE_PROTECTION_RADIUS: Int = 5`
- `GEOMETRIC_EDGE_GRADIENT_THRESHOLD: Double = 30.0`
 
**核心功能**：
- 自适应半径计算（基于流不确定性）
- 几何边缘检测
- 边缘保护（不膨胀到几何边缘）
 
### 4.3 Two-Phase Ledger Commit
 
**问题**：动态补丁延迟太久创建永久黑洞。
 
**解决方案**：候选账本与最终提交
 
**实施文件**：`Core/Capture/PR5/Dynamic/TwoPhaseLedgerCommit.swift`
 
**关键常量**：
- `CANDIDATE_LEDGER_MAX_FRAMES: Int = 60`
- `CANDIDATE_CONFIRMATION_FRAMES: Int = 10`
- `CANDIDATE_TIMEOUT_ACTION: CandidateTimeoutAction = .commitWithPenalty`
- `CANDIDATE_COMMIT_PENALTY: Double = 0.5`
 
**核心功能**：
- 候选补丁管理
- 静态确认计数
- 超时处理（commitWithPenalty/discard/commitFull）
- 提升到主账本
 
---
 
## PART 5: TEXTURE RESPONSE HARDENING
 
### 5.1 Repetition Response Policy
 
**问题**：检测重复纹理不改变行为是无用的。
 
**解决方案**：主动响应策略调整捕获策略
 
**实施文件**：`Core/Capture/PR5/Texture/RepetitionResponsePolicy.swift`
 
**关键常量**：
- `REPETITION_RESPONSE_ROTATION_DAMPENING: Double = 0.5`
- `REPETITION_RESPONSE_TRANSLATION_BOOST: Double = 1.5`
- `REPETITION_RESPONSE_BASELINE_MULTIPLIER: Double = 2.0`
- `REPETITION_HIGH_THRESHOLD: Double = 0.6`
- `REPETITION_CRITICAL_THRESHOLD: Double = 0.8`
 
**核心功能**：
- 响应级别分类（none/mild/moderate/severe）
- 新颖性权重调整（降低旋转权重，提升平移权重）
- 关键帧间距调整
- 运动引导方向（垂直于漂移轴）
 
### 5.2 Drift Axis to Movement Guidance
 
**问题**：漂移轴预测不可操作。
 
**解决方案**：映射漂移轴到相机相对引导（通过亮度，非文本）
 
**实施文件**：`Core/Capture/PR5/Texture/DriftAxisGuidance.swift`
 
**核心功能**：
- 方向性亮度乘数计算
- 垂直方向奖励（最多 30% 奖励）
- 平行方向惩罚（最多 30% 惩罚）
- 运动方向检测（好/坏方向）
 
---
 
## PART 6: EXPOSURE AND COLOR HARDENING
 
### 6.1 Anchor Transition Blending
 
**问题**：切换曝光锚点导致 delta 乘数不连续。
 
**解决方案**：锚点过渡期间平滑插值
 
**实施文件**：`Core/Capture/PR5/Exposure/AnchorTransitionBlender.swift`
 
**关键常量**：
- `ANCHOR_TRANSITION_DURATION_MS: Int64 = 2000`
- `ANCHOR_TRANSITION_CURVE: TransitionCurve = .easeInOut`
- `ANCHOR_TRANSITION_MIN_INTERVAL_MS: Int64 = 5000`
 
**核心功能**：
- 过渡状态管理
- 曲线应用（linear/easeIn/easeOut/easeInOut）
- 锚点值插值（ISO/快门/EV/WB/deltaMultiplier）
- 最小间隔检查
 
### 6.2 Illumination-Invariant Evidence Features
 
**问题**：HDR 场景导致同一对象从不同角度有不同亮度。
 
**解决方案**：使用光照不变特征进行证据计算
 
**实施文件**：`Core/Capture/PR5/Exposure/IlluminationInvariantFeatures.swift`
 
**关键常量**：
- `ILLUMINATION_INVARIANT_WEIGHT: Double = 0.3`
- `GRADIENT_STRUCTURE_WEIGHT: Double = 0.4`
- `LOCAL_CONTRAST_WEIGHT: Double = 0.3`
 
**核心功能**：
- 颜色比率提取（RGB 归一化）
- 梯度结构（方向直方图，非幅度）
- 局部对比度（相对，非绝对）
- 组合分数计算
- 帧间比较
 
---
 
## PART 7: PRIVACY HARDENING
 
### 7.1 Differential Privacy for Descriptors
 
**问题**：特征描述符即使没有图像也能启用重新识别。
 
**研究参考**：
- "LDP-Feat: Image Features with Local Differential Privacy" (ICCV 2023)
- "Privacy Leakage of SIFT Features" (arXiv 2020)
 
**解决方案**：描述符的局部差分隐私与隐私预算
 
**实施文件**：`Core/Capture/PR5/Privacy/DifferentialPrivacyDescriptors.swift`
 
**关键常量**：
- `DP_EPSILON: Double = 2.0`
- `DP_DESCRIPTOR_DIM_LIMIT: Int = 64`
- `DP_QUANTIZATION_LEVELS: Int = 16`
- `DP_FACE_REGION_DROP: Bool = true`
- `DP_PRIVACY_BUDGET_PER_SESSION: Double = 10.0`
 
**核心功能**：
- 维度缩减
- 量化
- 拉普拉斯噪声添加
- 重新归一化
- 隐私预算跟踪
- 面部区域丢弃
 
### 7.2 Verifiable Deletion Proof
 
**问题**：GDPR 要求可证明删除但也需要审计跟踪。
 
**研究参考**：
- "SevDel: Accelerating Secure and Verifiable Data Deletion" (IEEE 2025)
- "Verifiable Machine Unlearning" (IEEE SaTML 2025)
 
**解决方案**：带哈希链的加密删除证明
 
**实施文件**：`Core/Capture/PR5/Privacy/VerifiableDeletionProof.swift`
 
**关键常量**：
- `DELETION_PROOF_HASH_ALGORITHM: String = "SHA256"`
- `DELETION_PROOF_CHAIN_LENGTH: Int = 1000`
- `DELETION_RETENTION_DAYS: Int = 90`
 
**核心功能**：
- 删除证明条目创建
- 哈希链维护
- 链完整性验证
- 审计导出
 
### 7.3 Key Rotation and Recovery Plan
 
**问题**：KMS 三层缺少轮换和灾难恢复。
 
**解决方案**：定义轮换计划与重包装和恢复演练
 
**实施文件**：`Core/Capture/PR5/Privacy/KeyRotationPlan.swift`
 
**关键常量**：
- `SESSION_KEY_ROTATION_HOURS: Int = 24`
- `ENVELOPE_KEY_MAX_USES: Int = 1000`
- `KEY_ROTATION_OVERLAP_HOURS: Int = 2`
- `RECOVERY_DRILL_INTERVAL_DAYS: Int = 30`
 
**核心功能**：
- 会话密钥轮换（24 小时）
- 信封密钥使用计数
- 重叠期管理（旧密钥仍有效）
- 恢复演练（会话密钥丢失/设备迁移/设备密钥丢失）
 
---
 
## PART 8: AUDIT SCHEMA HARDENING
 
### 8.1 Closed-Set Audit Schema
 
**问题**：不受控制的审计字段导致版本漂移和解析失败。
 
**解决方案**：严格版本化模式与未知字段拒绝
 
**实施文件**：`Core/Capture/PR5/Audit/ClosedSetAuditSchema.swift`
 
**关键常量**：
- `AUDIT_SCHEMA_VERSION: Int = 1`
- `AUDIT_REJECT_UNKNOWN_FIELDS: Bool = true`
- `AUDIT_FLOAT_QUANTIZATION_DECIMALS: Int = 4`
- `AUDIT_MAX_RECORD_SIZE_BYTES: Int = 8192`
 
**核心功能**：
- 版本化审计记录结构
- 量化（Double 到 Int16，0-1 范围到 0-1000）
- 字段验证
- 大小限制检查
- 嵌套类型（StateTransition/Exposure/Quality/Texture/Dynamic/InfoGain/Budget/Decision/Evidence）
 
---
 
## PART 9: CROSS-PLATFORM DETERMINISM HARDENING
 
### 9.1 Statistical Distance Fixtures
 
**问题**：像素级夹具在不同硬件解码器上失败。
 
**解决方案**：使用分布距离度量的统计夹具
 
**实施文件**：`Core/Capture/PR5/Platform/StatisticalDistanceFixtures.swift`
 
**关键常量**：
- `FIXTURE_KL_DIVERGENCE_THRESHOLD: Double = 0.1`
- `FIXTURE_EMD_THRESHOLD: Double = 0.05`
- `FIXTURE_HISTOGRAM_BINS: Int = 64`
- `FIXTURE_GRADIENT_DIRECTION_BINS: Int = 36`
 
**核心功能**：
- 统计指纹提取（亮度直方图/梯度方向直方图/颜色比率/局部对比度）
- KL 散度计算
- 地球移动距离（EMD）计算
- 决策验证（捕获状态/处置类别/关键帧候选/信息增益范围）
 
### 9.2 Web Platform IMU Fallback
 
**问题**：Web 平台没有/差的 IMU 访问。
 
**解决方案**：仅视觉稳定性估计与保守惩罚
 
**实施文件**：`Core/Capture/PR5/Platform/WebPlatformFallback.swift`
 
**关键常量**：
- `WEB_PLATFORM_STABILITY_PENALTY: Double = 0.3`
- `WEB_PLATFORM_MAX_MOTION_UNCERTAINTY: Double = 0.5`
- `VISION_ONLY_STABILITY_WEIGHT: Double = 0.7`
 
**核心功能**：
- 平台能力掩码（imu/depth/arPlatform/trueRaw/exposureLock/secureEnclave）
- 仅视觉稳定性估计（特征位移统计）
- 运动不确定性计算
- 平台惩罚应用
- 时间一致性检查
 
---
 
## PART 10: PERFORMANCE BUDGET HARDENING
 
### 10.1 Emergency Degradation Path
 
**问题**：超预算时没有定义的优雅降级路径。
 
**解决方案**：明确的紧急路径与有序降级步骤
 
**实施文件**：`Core/Capture/PR5/Performance/EmergencyDegradationPath.swift`
 
**关键常量**：
- `EMERGENCY_PATH_STAGES: Int = 4`
- `EMERGENCY_TRIGGER_CONSECUTIVE_P99: Int = 3`
- `EMERGENCY_RECOVERY_P50_COUNT: Int = 10`
 
**核心功能**：
- 降级阶段（normal/reduceTexture/reduceResolution/keyframeOnly/pauseCapture）
- P99 违规检测（连续 3 次触发升级）
- P50 恢复检测（连续 10 次触发降级）
- 阶段配置（纹理分析层级/分辨率缩放/关键帧模式/捕获启用）
 
### 10.2 Memory Signature Tracking
 
**问题**：内存增长但不知道来源。
 
**解决方案**：每对象类型内存签名
 
**实施文件**：`Core/Capture/PR5/Performance/MemorySignatureTracker.swift`
 
**关键常量**：
- `MEMORY_SIGNATURE_INTERVAL_FRAMES: Int = 1000`
- `MEMORY_GROWTH_WARNING_MB: Int = 50`
- `MEMORY_LEAK_THRESHOLD_MB_PER_1000_FRAMES: Int = 20`
 
**核心功能**：
- 内存签名记录（总内存/对象计数/缓冲区水位）
- 增长率计算（每 1000 帧 MB）
- 泄漏检测（rawFramePool/assistFramePool/deferQueue/candidateLedger）
- 健康状态评估
 
---
 
## PART 11: TEST VALIDATION HARDENING
 
### 11.1 Quality-Gated Acceptance
 
**问题**："达到 0.7 的时间"可以通过接受低质量帧来游戏化。
 
**解决方案**：达到证据阈值时必须通过的质量门控
 
**实施文件**：`Core/Capture/PR5/Testing/QualityGatedAcceptance.swift`
 
**关键常量**：
- `ACCEPTANCE_GATE_0_7_STABLE_RATIO: Double = 0.4`
- `ACCEPTANCE_GATE_0_7_SCALE_STATUS: ScaleStatus = .stable`
- `ACCEPTANCE_GATE_0_7_DYNAMIC_RATIO: Double = 0.15`
- `ACCEPTANCE_GATE_0_7_REPETITION_RISK: Double = 0.5`
- `ACCEPTANCE_GATE_0_7_CONSISTENCY_SCORE: Double = 0.6`
 
**核心功能**：
- 质量门控检查（稳定特征比率/尺度状态/动态比率/重复风险/一致性分数）
- 虚拟亮度检测（证据 OK 但质量不 OK）
- 失败原因报告
 
### 11.2 Deterministic Regression Set
 
**问题**：跨版本没有回归保护。
 
**解决方案**：确定性夹具的固定回归集
 
**实施文件**：`Core/Capture/PR5/Testing/DeterministicRegressionSet.swift`
 
**关键常量**：
- `REGRESSION_SET_SIZE: Int = 50`
- `REGRESSION_CATEGORIES: [String] = [normal_office, weak_texture_wall, specular_surface, low_light_corridor, repetitive_tile, high_motion, mixed_lighting, dynamic_objects, hdr_scene, glass_reflection]`
 
**核心功能**：
- 回归测试用例生成（每类别 5 个变体）
- 输入序列规范（帧数/统计夹具 ID/模拟运动模式/模拟光照）
- 预期输出（最终证据范围/关键帧计数范围/最大停滞持续时间/允许状态/禁止处置）
 
---
 
## PART 12: 实施顺序与依赖关系
 
### 阶段 1：传感器与相机管道（PART 0）- P0 关键路径
 
1. **ISPDetector.swift** - ISP 检测
   - 依赖：无
   - 影响：所有后续质量度量
   
2. **ExposureLockVerifier.swift** - 曝光锁定验证
   - 依赖：无
   - 影响：曝光策略决策
   
3. **LensChangeDetector.swift** - 镜头切换检测
   - 依赖：无
   - 影响：会话分段和姿态跟踪
   
4. **EISRollingShutterHandler.swift** - EIS/滚动快门处理
   - 依赖：无
   - 影响：关键帧选择和几何一致性
   
5. **FramePacingNormalizer.swift** - 帧率归一化
   - 依赖：无
   - 影响：所有基于时间的窗口计算
 
### 阶段 2：状态机强化（PART 1）- P0 控制平面核心
 
6. **HysteresisStateMachine.swift** - 滞回状态机
   - 依赖：FramePacingNormalizer
   - 影响：所有状态转换决策
   
7. **CapturePolicyResolver.swift** - 统一策略解析器
   - 依赖：HysteresisStateMachine, ISPDetector
   - 影响：所有模块的策略协调
 
### 阶段 3：帧处置强化（PART 2）- P0 防止死锁
 
8. **DeferDecisionManager.swift** - 延迟决策管理
   - 依赖：CapturePolicyResolver
   - 影响：内存管理和决策延迟
   
9. **MinimumProgressGuarantee.swift** - 最小进度保证
   - 依赖：DeferDecisionManager
   - 影响：防止捕获完全停滞
   
10. **PoseChainPreserver.swift** - 姿态链保护
    - 依赖：无
    - 影响：姿态跟踪连续性
 
### 阶段 4-12：质量、动态、纹理、曝光、隐私、审计、平台、性能、测试
 
（详细实施顺序见各 PART 说明）
 
---
 
## 常量整合
 
所有常量集中在 `Core/Capture/PR5/Constants/PR5CaptureConstants.swift`：
 
- **PART 0**: ISP、曝光锁定、镜头切换、EIS、帧率（20+ 常量）
- **PART 1**: 状态机滞回、策略解析（10+ 常量）
- **PART 2**: 延迟决策、进度保证、姿态链（10+ 常量）
- **PART 3**: 一致性探测、视差耦合、独立性检查（10+ 常量）
- **PART 4**: 反射检测、掩码膨胀、两阶段提交（10+ 常量）
- **PART 5**: 重复响应、漂移轴（5+ 常量）
- **PART 6**: 锚点过渡、光照不变（5+ 常量）
- **PART 7**: 差分隐私、删除证明、密钥轮换（10+ 常量）
- **PART 8**: 审计模式（5+ 常量）
- **PART 9**: 统计夹具、Web 回退（5+ 常量）
- **PART 10**: 紧急降级、内存跟踪（5+ 常量）
- **PART 11**: 质量门控、回归集（5+ 常量）
 
**总计：100+ 常量**
 
---
 
## 集成点
 
### 与现有系统的集成
 
1. **PR2 证据系统**
   - `IlluminationInvariantFeatures` 影响证据计算
   - `TwoPhaseLedgerCommit` 影响账本更新
   
2. **PR3 门控系统**
   - `CapturePolicyResolver` 协调门控决策
   - `QualityGatedAcceptance` 验证门控质量
   
3. **PR4 软系统**
   - `HysteresisStateMachine` 管理软状态转换
   - `MinimumProgressGuarantee` 防止软系统死锁
 
### 数据流集成
 
```
传感器数据 → ISPDetector → ExposureLockVerifier → LensChangeDetector
    ↓
FramePacingNormalizer → HysteresisStateMachine → CapturePolicyResolver
    ↓
DeferDecisionManager → MinimumProgressGuarantee → PoseChainPreserver
    ↓
GlobalConsistencyProbe → TranslationParallaxCoupler → MetricIndependenceChecker
    ↓
ReflectionAwareDynamicDetector → AdaptiveMaskDilator → TwoPhaseLedgerCommit
    ↓
RepetitionResponsePolicy → DriftAxisGuidance
    ↓
AnchorTransitionBlender → IlluminationInvariantFeatures
    ↓
DifferentialPrivacyDescriptors → VerifiableDeletionProof → KeyRotationPlan
    ↓
ClosedSetAuditSchema → StatisticalDistanceFixtures → WebPlatformFallback
    ↓
EmergencyDegradationPath → MemorySignatureTracker
    ↓
QualityGatedAcceptance → DeterministicRegressionSet
```
 
---
 
## 测试策略
 
### 单元测试
每个模块独立测试，覆盖：
- 正常路径
- 边界条件
- 错误处理
- 性能基准
 
### 集成测试
- 阶段 1-3：传感器到状态机集成
- 阶段 4-6：质量到动态场景集成
- 阶段 7-9：曝光到隐私集成
- 阶段 10-12：平台到测试集成
 
### 回归测试
使用 `DeterministicRegressionSet` 的 50 个测试用例，覆盖 10 个场景类别。
 
### 性能测试
- 内存签名跟踪验证内存使用
- 紧急降级路径验证性能预算
- 帧率归一化验证时间窗口准确性
 
---
 
## 实施检查清单
 
### 阶段 1-3（P0 关键路径）
- [ ] ISP 检测与补偿
- [ ] 曝光锁定验证
- [ ] 镜头切换检测
- [ ] EIS/滚动快门处理
- [ ] 帧率归一化
- [ ] 滞回状态机
- [ ] 统一策略解析器
- [ ] 延迟决策管理
- [ ] 最小进度保证
- [ ] 姿态链保护
 
### 阶段 4-6（P1 质量保证）
- [ ] 全局一致性探测
- [ ] 平移-视差耦合
- [ ] 度量独立性检查
- [ ] 反射感知动态检测
- [ ] 自适应掩码膨胀
- [ ] 两阶段账本提交
- [ ] 重复纹理响应策略
- [ ] 漂移轴引导
 
### 阶段 7-9（P1-P2 功能完善）
- [ ] 锚点过渡混合
- [ ] 光照不变特征
- [ ] 差分隐私描述符
- [ ] 可验证删除证明
- [ ] 密钥轮换计划
- [ ] 封闭集审计模式
 
### 阶段 10-12（P2 平台与测试）
- [ ] 统计距离夹具
- [ ] Web 平台回退
- [ ] 紧急降级路径
- [ ] 内存签名跟踪
- [ ] 质量门控验收
- [ ] 确定性回归集
 
---
 
## 风险评估与缓解
 
### 高风险项
1. **ISP 检测准确性** - 可能误判导致策略错误
   - 缓解：保守默认值 + 校准验证
2. **状态机滞回振荡** - 可能在某些场景下仍振荡
   - 缓解：紧急覆盖机制 + 审计日志
3. **内存泄漏** - 延迟队列和候选账本可能泄漏
   - 缓解：内存签名跟踪 + 自动清理
 
### 中风险项
1. **跨平台确定性** - 统计夹具可能不够严格
   - 缓解：多平台验证 + 容差调整
2. **隐私预算耗尽** - 差分隐私预算可能过早耗尽
   - 缓解：预算监控 + 降级策略
 
---
 
## 成功标准
 
1. **功能完整性**：所有 30 个组件实现并通过单元测试
2. **集成稳定性**：通过所有集成测试，无死锁或内存泄漏
3. **性能目标**：满足性能预算，紧急降级路径有效
4. **质量保证**：通过质量门控验收，回归测试全部通过
5. **跨平台兼容**：统计夹具在 iOS/Android/Web 上通过
 
---
 
## 研究参考
 
### 传感器与相机管道
- "Deep Learning ISP Survey" (ACM Computing Surveys 2024)
- "ParamISP: Learning Camera-Specific ISP Parameters" (CVPR 2024)
- "InvISP: Invertible Image Signal Processing" (CVPR 2021)
- "GaVS: Gaussian Splatting for Video Stabilization" (2025)
- "RS-ORB-SLAM3: Rolling Shutter Compensation" (GitHub 2024)
- "Gaussian Splatting on the Move" (ECCV 2024)
 
### 状态机与控制
- "Schmitt Trigger Patterns for Embedded Systems" (2024)
- "Dead Zone in Control Systems" (2024)
 
### 动态场景与反射
- "3DRef: 3D Dataset and Benchmark for Reflection Detection" (3DV 2024)
- "TraM-NeRF: Reflection Tracing for NeRF" (CGF 2024)
 
### 隐私与安全
- "LDP-Feat: Image Features with Local Differential Privacy" (ICCV 2023)
- "Privacy Leakage of SIFT Features" (arXiv 2020)
- "SevDel: Accelerating Secure and Verifiable Data Deletion" (IEEE 2025)
- "Verifiable Machine Unlearning" (IEEE SaTML 2025)
 
### 跨平台与测试
- "Multi-Camera Visual Odometry (MCVO)" (arXiv 2024)
- "MASt3R-SLAM: Calibration-Free SLAM" (CVPR 2025)
- "InFlux: Dynamic Intrinsics Benchmark" (arXiv 2024)
 
---
 
**END OF PR5 v1.2 BULLETPROOF PATCH IMPLEMENTATION PLAN**
 
**Total Components**: 30+
**Total Constants**: 100+
**Coverage**: 60 production-critical vulnerabilities addressed