# New Core Phase Gate Contract v1 (Phase 0-13)

## 1. 用法
- 本文件定义“新核心层发布阻断合同”。
- 每个 Phase 必须满足：
  - 必过 gate 组
  - 最低测试配额
  - 必交审计产物
- 任何一项不满足：`Phase 不得前进，不得打 pass tag`。

## 2. 全局硬规则
- `R1` 失败即阻断：`NC_RELEASE_HARD` 任一失败停止流水。
- `R2` 不达配额即失败：测试数量、类型分布必须达标。
- `R3` 无产物即失败：JSON/日志/哈希缺失视同失败。
- `R4` 可复验性：所有结果必须能在固定 seed 下重放。
- `R5` 无灰色状态：不存在“基本通过”。

## 3. Phase 合同矩阵

| Phase | 必过 Gate 层 | 最低测试总数 | 类型最低配额 | 必交产物 |
|---|---|---:|---|---|
| 0 | L0 L1 L2 | 1800 | D>=500 P>=300 M>=200 F>=300 A>=150 S>=50 E>=100 | fixture hashes, toolchain report |
| 1 | L0 L1 L2 L3 | 2600 | D>=700 P>=500 M>=300 F>=450 A>=200 S>=100 E>=150 | tsdf parity report, topology report |
| 2 | L0 L1 L2 L3 | 2800 | D>=750 P>=550 M>=350 F>=500 A>=220 S>=120 E>=180 | evidence replay diff=0 report |
| 3 | L0 L1 L2 L3 L4 | 2400 | D>=650 P>=450 M>=250 F>=450 A>=250 S>=100 E>=150 | merkle proof report, audit hash |
| 4 | L0 L1 L2 L4 | 3200 | D>=850 P>=600 M>=350 F>=550 A>=300 S>=150 E>=200 | time-anchor report, pure-policy report |
| 5 | L0 L1 L2 L3 L4 L6 | 3500 | D>=900 P>=650 M>=400 F>=600 A>=320 S>=180 E>=220 | quality closure report, upload contract report |
| 6 | L0 L1 L2 L4 L5 | 3600 | D>=900 P>=650 M>=420 F>=620 A>=320 S>=220 E>=230 | thermal/memory baseline report |
| 7 | L0 L1 L2 L3 L4 L5 | 3800 | D>=950 P>=700 M>=430 F>=650 A>=350 S>=250 E>=250 | guidance correctness + rate-limit replay |
| 8 | L0 L1 L2 L3 L4 L5 L6 | 4200 | D>=1050 P>=750 M>=500 F>=700 A>=400 S>=300 E>=300 | first-scan runtime metrics v1 |
| 9 | L0 L1 L2 L3 L4 L5 L6 | 4500 | D>=1100 P>=800 M>=550 F>=800 A>=420 S>=320 E>=350 | pure-vision uncertainty + scale report |
| 10 | L0 L1 L2 L3 L4 L5 L6 | 4600 | D>=1150 P>=820 M>=560 F>=820 A>=430 S>=320 E>=360 | coverage/IG/UI admission report |
| 11 | L0 L1 L2 L3 L4 L5 L6 | 4700 | D>=1180 P>=840 M>=580 F>=850 A>=450 S>=330 E>=370 | optimizer stability report |
| 12 | L0 L1 L2 L3 L4 L5 L6 | 4800 | D>=1200 P>=860 M>=600 F>=860 A>=460 S>=340 E>=380 | render fps/memory/thermal report |
| 13 | L0 L1 L2 L3 L4 L5 L6 | 5000 | D>=1300 P>=900 M>=650 F>=900 A>=500 S>=350 E>=400 | e2e A/B/C/D report + audit chain report |

说明:
- `D`: Deterministic
- `P`: Property
- `M`: Metamorphic
- `F`: Fuzz
- `A`: Adversarial
- `S`: Soak/Stress
- `E`: E2E Replay

## 4. 阈值补充合同 (硬门禁)

### 4.1 准确性与真实性
- `non_manifold_count == 0`
- `replay_hash_mismatch == 0`
- `illegal_state_transition == 0`
- `merkle_verify_failure == 0`

### 4.2 性能与稳定
- `first_scan_median_seconds <= 180`
- `first_scan_p95_seconds <= 900` (硬上限 15 分钟)
- `ct_vio_p95_ms <= 16`
- `framegate_p99_ms <= 8`
- `critical_thermal_events == 0`

### 4.3 审计与合规
- 会话必须具备：
  - 起始锚
  - 周期锚序列
  - 结束锚
- 任意锚缺失 => 直接失败。

## 5. 批次执行协议
- `B1` 每迁移一批，先跑本 Phase 的 `NC-fast`。
- `B2` `NC-fast` 通过后，跑 `NC-deep`。
- `B3` `NC-deep` 通过后，跑 `NC full sweep`。
- `B4` 全通过后才允许进入下一批。

## 6. 失败原因分解合同
- 每次失败必须输出：
  - `Top-5 root causes`
  - `failure->module` 映射
  - `复现实验命令`
  - `修复后回归编号`
- 缺少任一项，不允许关闭失败项。

## 7. 兼容车道要求 (非阻断)
- `LEGACY_COMPAT_SOFT` 仍需每日运行并产出：
  - 失败趋势
  - 波动分布
  - 对新核心的潜在污染风险
- 但不再影响 `phase-*-pass`。

## 8. 执行顺序建议
- 白天：`NC-fast + 关键 E2E`
- 夜间：`NC-deep + soak + fuzz + adversarial`
- 次日合并：统一生成 `gate_run_manifest.json`

## 9. 审计签收条件
- 本 Phase 所有必过 gate 通过。
- 测试总数与类型配额达标。
- 产物齐全且哈希可验。
- 失败分解与复现记录齐全。
- 才允许签收 `phase-*-pass`。

