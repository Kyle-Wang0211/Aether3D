# SSOT Constants Registry

> **Contract Version:** 1
> **Last Updated:** 2026-01-12
> **Status:** Active

---

<!-- SSOT:VERSION:BEGIN -->
## Version Info

| Key | Value |
|-----|-------|
| SSOT_VERSION | 1.0.0 |
| SCHEMA_VERSION | 1.0.0 |
| GENERATOR | PR#1 |
<!-- SSOT:VERSION:END -->

---

<!-- SSOT:FILES:BEGIN -->
## Source Files

| File | Purpose | Location |
|------|---------|----------|
| SSOTVersion.swift | Version constants | Core/Constants/ |
| SSOTTypes.swift | Type definitions | Core/Constants/ |
| SSOTValidation.swift | Validation logic | Core/Constants/ |
| SystemConstants.swift | System limits | Core/Constants/ |
| ConversionConstants.swift | Unit conversions | Core/Constants/ |
| QualityThresholds.swift | Quality thresholds | Core/Constants/ |
| ErrorDomain.swift | Error domains | Core/Constants/ |
| SSOTErrorCode.swift | Error code struct | Core/Constants/ |
| ErrorCodes.swift | Error instances | Core/Constants/ |
| SSOTRegistry.swift | Central registry | Core/Constants/ |
| SSOT.swift | Public API | Core/Constants/ |
<!-- SSOT:FILES:END -->

---

<!-- SSOT:SYSTEM_CONSTANTS:BEGIN -->
## System Constants

| SSOT_ID | Value | Unit | Category | Documentation |
|---------|-------|------|----------|---------------|
| SystemConstants.maxFrames | 5000 | frames | system | Hard limit on maximum number of frames in a capture sequence (15分钟视频采样上限) |
| SystemConstants.minFrames | 10 | frames | system | Hard limit on minimum number of frames required for processing |
| SystemConstants.maxGaussians | 1000000 | gaussians | system | Hard limit on maximum number of Gaussian splats in a scene |
<!-- SSOT:SYSTEM_CONSTANTS:END -->

---

<!-- SSOT:CONVERSION_CONSTANTS:BEGIN -->
## Conversion Constants

| SSOT_ID | Value | Unit | Rationale |
|---------|-------|------|-----------|
| ConversionConstants.bytesPerKB | 1024 | bytes | IEC 80000-13 (KiB) |
| ConversionConstants.bytesPerMB | 1048576 | bytes | IEC 80000-13 (MiB) |
<!-- SSOT:CONVERSION_CONSTANTS:END -->

---

<!-- SSOT:QUALITY_THRESHOLDS:BEGIN -->
## Quality Thresholds

| SSOT_ID | Value | Unit | Category | Min | Max | Default | OnExceed | OnUnderflow | Documentation |
|---------|------|------|----------|-----|-----|---------|----------|-------------|---------------|
| QualityThresholds.sfmRegistrationMinRatio | 0.75 | ratio | quality | 0.0 | 1.0 | 0.75 | warn | reject | Minimum ratio of successfully registered frames in SFM pipeline (配准率保底) |
| QualityThresholds.psnrMinDb | 30.0 | db | quality | 0.0 | 100.0 | 30.0 | warn | reject | Minimum Peak Signal-to-Noise Ratio in decibels for acceptable quality (本色区域最低要求) |
| QualityThresholds.psnrWarnDb | 32.0 | db | quality | 0.0 | 100.0 | 32.0 | warn | warn | PSNR threshold below which user should be warned (低于这个提醒用户) |
<!-- SSOT:QUALITY_THRESHOLDS:END -->

---

<!-- SSOT:RETRY_CONSTANTS:BEGIN -->
## Retry Constants

| SSOT_ID | Value | Unit | Category | Min | Max | Default | OnExceed | OnUnderflow | Documentation |
|---------|-------|------|----------|-----|-----|---------|----------|-------------|---------------|
| RetryConstants.maxRetryCount | 10 | count | - | - | - | - | - | - | 用户可接受的最大等待重试次数，配合10秒间隔共100秒 |
| RetryConstants.retryIntervalSeconds | 10.0 | seconds | performance | 1.0 | 60.0 | 10.0 | warn | reject | 每次重试间隔，足够让临时网络问题恢复 |
| RetryConstants.uploadTimeoutSeconds | ∞ | seconds | performance | 0.0 | ∞ | ∞ | warn | reject | 无限制，后台持续上传，1.08GB大文件需要充足时间 |
| RetryConstants.downloadMaxRetryCount | 3 | count | - | - | - | - | - | - | 下载失败重试次数，指数退避 |
| RetryConstants.artifactTTLSeconds | 1800 | seconds | resource | 60.0 | 3600.0 | 1800 | warn | reject | 30分钟云端保留，足够断点续传，ACK后立即删除 |
| RetryConstants.heartbeatIntervalSeconds | 30.0 | seconds | performance | 5.0 | 120.0 | 30.0 | warn | reject | 心跳间隔，平衡服务器负载与状态检测及时性 |
| RetryConstants.pollingIntervalSeconds | 3.0 | seconds | performance | 1.0 | 10.0 | 3.0 | warn | reject | 进度轮询间隔，白盒阶段使用，后续可升级WebSocket |
| RetryConstants.stallDetectionSeconds | 300 | seconds | safety | 60.0 | 600.0 | 300 | warn | reject | 5分钟无响应判定卡死，需三指标同时满足 |
| RetryConstants.stallHeartbeatFailureCount | 10 | count | - | - | - | - | - | - | 连续10次心跳失败（配合30秒间隔=5分钟） |
<!-- SSOT:RETRY_CONSTANTS:END -->

---

<!-- SSOT:SAMPLING_CONSTANTS:BEGIN -->
## Sampling Constants

| SSOT_ID | Value | Unit | Category | Min | Max | Default | OnExceed | OnUnderflow | Documentation |
|---------|-------|------|----------|-----|-----|---------|----------|-------------|---------------|
| SamplingConstants.minVideoDurationSeconds | 2.0 | seconds | quality | 1.0 | 10.0 | 2.0 | warn | reject | 低于2秒无法保证30帧最低要求 |
| SamplingConstants.maxVideoDurationSeconds | 900 | seconds | quality | 60.0 | 1800.0 | 900 | reject | warn | 15分钟上限，平衡质量与处理时间 |
| SamplingConstants.minFrameCount | 30 | frames | - | - | - | - | - | reject | 3DGS重建最低帧数要求 |
| SamplingConstants.maxFrameCount | 1800 | frames | - | - | - | - | - | - | 15分钟×2fps，控制云端处理时间 |
 pr/1-system-layer

 pr/1-system-layer

| SamplingConstants.maxUploadSizeBytes | 1161527296 | bytes | - | - | - | - | - | - | 1.08GB，1800帧×600KB最大估算 |
 main
 main
| SamplingConstants.jpegQuality | 0.85 | ratio | quality | 0.0 | 1.0 | 0.85 | warn | reject | 固定85%质量，永不降低 |
| SamplingConstants.maxImageLongEdge | 1920 | pixels | - | - | - | - | - | - | 1080p长边，永不降低 |
<!-- SSOT:SAMPLING_CONSTANTS:END -->

---

<!-- SSOT:FRAME_QUALITY_CONSTANTS:BEGIN -->
## Frame Quality Constants

| SSOT_ID | Value | Unit | Category | Min | Max | Default | OnExceed | OnUnderflow | Documentation |
|---------|-------|------|----------|-----|-----|---------|----------|-------------|---------------|
| FrameQualityConstants.blurThresholdLaplacian | 200.0 | variance | quality | 50.0 | 500.0 | 200.0 | warn | reject | 比行业标准(100)严格2倍，宁可丢帧也要清晰 |
| FrameQualityConstants.darkThresholdBrightness | 60.0 | brightness | quality | 0.0 | 255.0 | 60.0 | warn | reject | 暗部细节和深度估计都会失效 |
| FrameQualityConstants.brightThresholdBrightness | 200.0 | brightness | quality | 0.0 | 255.0 | 200.0 | reject | warn | 过曝区域完全没有纹理信息 |
| FrameQualityConstants.maxFrameSimilarity | 0.92 | ratio | quality | 0.0 | 1.0 | 0.92 | reject | warn | 高于92%为冗余帧，减少无效数据 |
| FrameQualityConstants.minFrameSimilarity | 0.50 | ratio | quality | 0.0 | 1.0 | 0.50 | warn | reject | 低于50%为跳帧，连续性断裂 |
<!-- SSOT:FRAME_QUALITY_CONSTANTS:END -->

---

<!-- SSOT:CONTINUITY_CONSTANTS:BEGIN -->
## Continuity Constants

| SSOT_ID | Value | Unit | Category | Min | Max | Default | OnExceed | OnUnderflow | Documentation |
|---------|-------|------|----------|-----|-----|---------|----------|-------------|---------------|
| ContinuityConstants.maxDeltaThetaDegPerFrame | 30.0 | degreesPerFrame | quality | 5.0 | 90.0 | 30.0 | reject | warn | 30°/帧已是快速转动，正常扫描约10-20°/帧 |
| ContinuityConstants.maxDeltaTranslationMPerFrame | 0.25 | metersPerFrame | quality | 0.01 | 1.0 | 0.25 | reject | warn | 0.25m/帧已是快速移动，正常扫描更慢 |
| ContinuityConstants.freezeWindowFrames | 20 | frames | - | - | - | - | - | - | 约0.67秒@30fps，给用户足够缓冲时间 |
| ContinuityConstants.recoveryStableFrames | 15 | frames | - | - | - | - | - | - | 约0.5秒@30fps，确保真正稳定后才恢复 |
| ContinuityConstants.recoveryMaxDeltaThetaDegPerFrame | 15.0 | degreesPerFrame | quality | 1.0 | 45.0 | 15.0 | reject | warn | 恢复时比正常阈值更严格 |
<!-- SSOT:CONTINUITY_CONSTANTS:END -->

---

<!-- SSOT:COVERAGE_VISUALIZATION_CONSTANTS:BEGIN -->
## Coverage Visualization Constants

| SSOT_ID | Value | Unit | Category | Min | Max | Default | OnExceed | OnUnderflow | Documentation |
|---------|-------|------|----------|-----|-----|---------|----------|-------------|---------------|
| CoverageVisualizationConstants.s0BorderWidthPx | 1.0 | pixels | quality | 0.5 | 3.0 | 1.0 | warn | reject | 1px白线分割三角形，让用户知道这里有东西要扫 |
| CoverageVisualizationConstants.s4MinThetaSpanDeg | 16.0 | degrees | quality | 5.0 | 90.0 | 16.0 | warn | reject | 视角跨度至少16°才能保证多视角重建质量 |
| CoverageVisualizationConstants.s4MinL2PlusCount | 7 | count | - | - | - | - | - | - | 至少7个有效视角（每个差5°以上） |
| CoverageVisualizationConstants.s4MinL3Count | 3 | count | - | - | - | - | - | - | 至少3个高质量视角（每个差10°以上） |
| CoverageVisualizationConstants.s4MaxReprojRmsPx | 1.0 | pixels | quality | 0.1 | 5.0 | 1.0 | reject | warn | 重投影误差<1px保证几何精度 |
| CoverageVisualizationConstants.s4MaxEdgeRmsPx | 0.5 | pixels | quality | 0.1 | 2.0 | 0.5 | reject | warn | 边缘抖动<0.5px保证边界稳定 |
| CoverageVisualizationConstants.patchSizeMinM | 0.005 | meters | quality | 0.001 | 0.1 | 0.005 | warn | reject | 0.5cm最小Patch，捕捉细节 |
| CoverageVisualizationConstants.patchSizeMaxM | 0.5 | meters | quality | 0.1 | 2.0 | 0.5 | warn | reject | 50cm最大Patch，覆盖大平面 |
| CoverageVisualizationConstants.patchSizeFallbackM | 0.05 | meters | quality | 0.01 | 0.2 | 0.05 | warn | reject | 5cm默认Patch，适合大多数场景 |
<!-- SSOT:COVERAGE_VISUALIZATION_CONSTANTS:END -->

---

<!-- SSOT:STORAGE_CONSTANTS:BEGIN -->
## Storage Constants

| SSOT_ID | Value | Unit | Category | Min | Max | Default | OnExceed | OnUnderflow | Documentation |
|---------|-------|------|----------|-----|-----|---------|----------|-------------|---------------|
| StorageConstants.lowStorageWarningBytes | 1610612736 | bytes | - | - | - | - | - | - | 1.5GB警告阈值，预留足够空间处理新素材 |
| StorageConstants.maxAssetCount | Int.max | count | - | - | - | - | - | - | 不限制数量，用户自行管理 |
| StorageConstants.autoCleanupEnabled | 0.0 | dimensionless | resource | 0.0 | 1.0 | 0.0 | warn | warn | 不自动清理，避免误删用户数据 |
<!-- SSOT:STORAGE_CONSTANTS:END -->

---

<!-- SSOT:DOMAINS:BEGIN -->
## Error Domains

| Domain | Code Range | Prefix | Description |
|--------|------------|--------|-------------|
| SSOT | 1000-1999 | SSOT_ | SSOT system errors |
| CAPTURE | 1000-1999 | E_ | Client capture errors |
| STORAGE | 2000-2999 | E_ | Client storage errors |
| NETWORK | 3000-3999 | E_ | Network errors |
| PIPELINE | 4000-4999 | C_ | Cloud pipeline errors |
| QUALITY | 5000-5999 | C_ | Quality validation errors |
| SYSTEM | 6000-6999 | S_ | System/fatal errors |
| AUDIT | 3000-3999 | AUDIT_ | Audit errors (legacy) |
<!-- SSOT:DOMAINS:END -->

---

<!-- SSOT:ERRORCODES:BEGIN -->
## Error Codes

| StableName | Domain | Code | Severity | Retry | UserMessage |
|------------|--------|------|----------|-------|-------------|
| SSOT_INVALID_SPEC | SSOT | 1000 | high | none | Invalid constant specification |
| SSOT_EXCEEDED_MAX | SSOT | 1001 | medium | none | Value exceeds maximum allowed |
| SSOT_UNDERFLOWED_MIN | SSOT | 1002 | medium | none | Value below minimum required |
| SSOT_ASSERTION_FAILED | SSOT | 1003 | critical | none | Internal assertion failed |
| SSOT_REGISTRY_INVALID | SSOT | 1004 | high | none | SSOT registry validation failed |
| SSOT_DUPLICATE_ERROR_CODE | SSOT | 1005 | high | none | Duplicate error code detected |
| SSOT_DUPLICATE_SPEC_ID | SSOT | 1006 | high | none | Duplicate constant spec ID detected |
| E_FRAMES_CLAMPED | CAPTURE | 1001 | low | none | Frame count adjusted to valid range |
| E_FRAMES_TOO_FEW | CAPTURE | 1002 | medium | none | Not enough frames captured |
| E_CAPTURE_INVALID | CAPTURE | 1003 | high | none | Capture data is invalid |
| E_CAPTURE_CORRUPTED | CAPTURE | 1004 | high | none | Capture data is corrupted |
| E_STORAGE_LOW | STORAGE | 2001 | low | none | Storage space is running low |
| E_STORAGE_WRITE_FAILED | STORAGE | 2002 | high | immediate | Failed to save data |
| E_STORAGE_READ_FAILED | STORAGE | 2003 | high | immediate | Failed to load data |
| E_UPLOAD_FAILED | NETWORK | 3001 | high | exponentialBackoff | Upload failed |
| E_DOWNLOAD_FAILED | NETWORK | 3002 | high | exponentialBackoff | Download failed |
| E_UPLOAD_TOO_LARGE | NETWORK | 3003 | medium | none | File is too large to upload |
| E_NETWORK_TIMEOUT | NETWORK | 3004 | high | exponentialBackoff | Connection timeout |
| C_SFM_FAILED | PIPELINE | 4001 | high | manual | 3D reconstruction failed |
| C_SFM_NO_IMAGES | PIPELINE | 4002 | medium | none | No valid images found |
| C_GAUSSIANS_CLAMPED | PIPELINE | 4003 | low | none | Detail level adjusted to system limits |
| C_TRAINING_TIMEOUT | PIPELINE | 4004 | high | manual | Processing timeout |
| C_TRAINING_FAILED | PIPELINE | 4005 | high | manual | Training failed |
| C_SFM_REGISTRATION_TOO_LOW | QUALITY | 5001 | medium | none | Image alignment failed |
| C_PSNR_BELOW_MIN | QUALITY | 5002 | medium | none | Quality too low |
| C_QUALITY_SCORE_BELOW_REJECT | QUALITY | 5003 | high | none | Quality check failed |
| C_QUALITY_INPUT_MISSING | QUALITY | 5004 | high | none | Missing quality data |
| C_PSNR_BELOW_RECOMMENDED | QUALITY | 5005 | low | none | Quality below recommended |
| S_INTERNAL_ERROR | SYSTEM | 6001 | critical | none | Internal error occurred |
| S_ASSERTION_FAILED | SYSTEM | 6002 | critical | none | System assertion failed |
| S_CONFIGURATION_ERROR | SYSTEM | 6003 | critical | none | Configuration error |
<!-- SSOT:ERRORCODES:END -->

---

<!-- SSOT:PROHIBITIONS:BEGIN -->
## Lint Prohibitions

| # | Rule | Test | Severity |
|---|------|------|----------|
| 1 | No fatalError in Core/ | FatalPatternScanTests | Block |
| 2 | No magic numbers | NoMagicNumbersLintTests | Warn |
| 3 | No silent clamp | ClampPatternScanTests | Warn |
| 4 | No print() in Core/ | PrintStatementScanTests | Warn |
| 5 | Error codes unique | ErrorCodesCoverageTests | Block |
| 6 | Constants have spec | ConstantSpecCoverageTests | Block |
| 7 | Doc-code sync | DocumentConsistencyTests | Block |
<!-- SSOT:PROHIBITIONS:END -->

---

<!-- SSOT:CHANGELOG:BEGIN -->
## Changelog

| Version | Date | PR | Change |
|---------|------|----|--------|
| 1.0.0 | 2026-01-12 | PR#1 | Initial SSOT system |
<!-- SSOT:CHANGELOG:END -->
