# PR2-JSM CI 全面修复提示词 (v2)

## 🚨 CI失败根因分析

### 失败概览 (8个CI Job全部失败)

| Job名称 | 失败原因 | 根因 |
|---------|----------|------|
| Preflight (Phase 0.5 guardrails) | Swift编译错误 | 代码问题 |
| Test & Lint | Swift编译错误 | 代码问题 |
| PIZ Tests (macos-15) | Swift编译错误 | 代码问题 |
| PIZ Tests (ubuntu-22.04) | Swift编译错误 | 代码问题 |
| PIZ Cross-Platform Comparison | 依赖piz-matrix失败 | 级联失败 |
| PIZ Sealing Evidence Generation | 依赖piz-compare失败 | 级联失败 |
| PIZ Final Gate (no-skip policy) | 依赖所有PIZ job失败 | 级联失败 |

### 根本原因

**问题1: 分支分歧 - 缺少 `capacitySaturated` 状态**

Main分支已合并PR1，包含:
```
Contract Version: PR2-JSM-2.5 (PR1 C-Class: +1 state CAPACITY_SATURATED)
States: 9 | Transitions: 14 | FailureReasons: 14 | CancelReasons: 2
```

PR2分支基于旧main开发:
```
Contract Version: PR2-JSM-3.0
States: 8 | Transitions: 13 | FailureReasons: 17 | CancelReasons: 3
```

**问题2: CI Workflow文件落后**

PR2分支的 `.github/workflows/ci.yml` 缺少:
- `concurrency` 配置
- PIZ相关的所有job (piz-matrix, piz-compare, piz-sealing-evidence, piz-gate)
- `ref` 配置用于PR正确检出
- 系统依赖安装步骤
- Build warnings检查

**问题3: 编译错误**

```
error: switch must be exhaustive - add missing case: '.capacitySaturated'
```
位置: `ProgressEstimator.swift` 的 `nextNonTerminalState` 方法

---

## ✅ 修复步骤

### 第一步: 合并Main分支

```bash
# 1. 保存当前工作
git stash  # 如果有未提交的更改

# 2. 获取最新main
git fetch origin main

# 3. 合并main到当前PR2分支
git merge origin/main --no-edit

# 4. 如果有冲突，解决后:
git add .
git merge --continue
```

### 第二步: 更新Contract Version (合并后的版本)

**目标版本**: `PR2-JSM-3.0-merged`

**计算**:
- States: 9 (8原有 + capacitySaturated)
- Transitions: 15 (13原有 + PROCESSING→CAPACITY_SATURATED + 可能的其他)
- FailureReasons: 17 (PR2新增3个)
- CancelReasons: 3 (PR2新增1个)
- ILLEGAL_TRANSITION_COUNT: 66 (9×9 - 15 = 66)
- TOTAL_STATE_PAIRS: 81 (9×9 = 81)

**需要更新Header的文件** (每个文件的前5行):
```swift
// ============================================================================
// CONSTITUTIONAL CONTRACT - DO NOT EDIT WITHOUT RFC
// Contract Version: PR2-JSM-3.0-merged
// States: 9 | Transitions: 15 | FailureReasons: 17 | CancelReasons: 3
// ============================================================================
```

文件列表:
1. `Core/Jobs/JobState.swift`
2. `Core/Jobs/ContractConstants.swift`
3. `Core/Jobs/JobStateMachine.swift`
4. `Core/Jobs/JobStateMachineError.swift`
5. `Core/Jobs/FailureReason.swift`
6. `Core/Jobs/CancelReason.swift`
7. `Core/Jobs/RetryCalculator.swift`
8. `Core/Jobs/DLQEntry.swift`
9. `Core/Jobs/CircuitBreaker.swift`
10. `Core/Jobs/DeterministicEncoder.swift`
11. `Core/Jobs/TransitionSpan.swift`
12. `Core/Jobs/ProgressEstimator.swift`

### 第三步: 修复 JobState.swift

确保包含 `capacitySaturated`:

```swift
public enum JobState: String, Codable, CaseIterable {
    case pending = "pending"
    case uploading = "uploading"
    case queued = "queued"
    case processing = "processing"
    case packaging = "packaging"
    case completed = "completed"
    case failed = "failed"
    case cancelled = "cancelled"
    case capacitySaturated = "capacity_saturated"  // PR1 C-Class: terminal non-error state

    public var isTerminal: Bool {
        switch self {
        case .completed, .failed, .cancelled, .capacitySaturated:
            return true
        case .pending, .uploading, .queued, .processing, .packaging:
            return false
        }
    }

    public var isCancellable: Bool {
        switch self {
        case .pending, .uploading, .queued:
            return true
        case .processing, .packaging, .completed, .failed, .cancelled, .capacitySaturated:
            return false
        }
    }
}
```

### 第四步: 修复 ContractConstants.swift

```swift
public static let CONTRACT_VERSION = "PR2-JSM-3.0-merged"
public static let STATE_COUNT = 9
public static let LEGAL_TRANSITION_COUNT = 15
public static let ILLEGAL_TRANSITION_COUNT = 66  // 9×9 - 15 = 66
public static let TOTAL_STATE_PAIRS = 81  // 9×9 = 81
public static let FAILURE_REASON_COUNT = 17
public static let CANCEL_REASON_COUNT = 3
```

### 第五步: 修复 JobStateMachine.swift

添加新的合法转换:

```swift
private static let legalTransitions: Set<Transition> = [
    Transition(from: .pending, to: .uploading),
    Transition(from: .pending, to: .cancelled),
    Transition(from: .uploading, to: .queued),
    Transition(from: .uploading, to: .failed),
    Transition(from: .uploading, to: .cancelled),
    Transition(from: .queued, to: .processing),
    Transition(from: .queued, to: .failed),
    Transition(from: .queued, to: .cancelled),
    Transition(from: .processing, to: .packaging),
    Transition(from: .processing, to: .failed),
    Transition(from: .processing, to: .cancelled),
    Transition(from: .processing, to: .capacitySaturated),  // PR1 C-Class
    Transition(from: .packaging, to: .completed),
    Transition(from: .packaging, to: .failed),
    Transition(from: .packaging, to: .capacitySaturated),   // 如果需要
]
```

### 第六步: 修复 ProgressEstimator.swift (关键!)

```swift
private func nextNonTerminalState(after state: JobState) -> JobState? {
    switch state {
    case .pending: return .uploading
    case .uploading: return .queued
    case .queued: return .processing
    case .processing: return .packaging
    case .packaging: return nil  // completed is terminal
    case .completed, .failed, .cancelled, .capacitySaturated: return nil  // ← 添加 capacitySaturated
    }
}
```

### 第七步: 修复 TransitionSpan.swift

检查所有switch语句，确保包含 `.capacitySaturated`:

```swift
// 示例 - 检查所有switch语句
switch state {
case .pending, .uploading, .queued, .processing, .packaging:
    // 非终态处理
case .completed, .failed, .cancelled, .capacitySaturated:
    // 终态处理
}
```

### 第八步: 检查所有其他文件的switch语句

使用grep查找所有可能遗漏的switch:

```bash
grep -rn "switch.*JobState" Core/ Tests/
grep -rn "case \.completed" Core/ Tests/
```

确保每个switch都包含 `.capacitySaturated` case。

---

## 🔍 本地验证命令 (必须全部通过!)

```bash
# 1. 清理构建
swift package clean

# 2. 构建 (必须无错误)
swift build 2>&1 | tee build.log
if grep -i "error:" build.log; then echo "❌ BUILD FAILED"; exit 1; fi

# 3. 检查exhaustive switch警告
swift build 2>&1 | grep -i "exhaustive\|missing case"
# 预期输出: 无

# 4. 运行所有测试 (必须全部通过)
swift test 2>&1 | tee test.log
if grep -i "failed" test.log | grep -v "0 failed"; then echo "❌ TESTS FAILED"; exit 1; fi

# 5. 特定测试验证
swift test --filter JobStateMachineTests
swift test --filter CircuitBreakerTests
swift test --filter DeterministicEncoderTests
swift test --filter PIZ

# 6. 验证状态计数
echo "Checking STATE_COUNT..."
grep "STATE_COUNT = 9" Core/Jobs/ContractConstants.swift && echo "✅ STATE_COUNT correct"

# 7. 验证capacitySaturated存在
echo "Checking capacitySaturated..."
grep "capacitySaturated" Core/Jobs/JobState.swift && echo "✅ capacitySaturated exists"

# 8. 验证ProgressEstimator修复
echo "Checking ProgressEstimator..."
grep "capacitySaturated" Core/Jobs/ProgressEstimator.swift && echo "✅ ProgressEstimator fixed"
```

---

## 🔄 CI Pipeline验证

合并main后，CI会运行以下jobs:

1. **Preflight (Phase 0.5 guardrails)** - 预检
2. **Test & Lint** - 编译和基本测试
3. **PIZ Tests (macos-15)** - macOS平台PIZ测试
4. **PIZ Tests (ubuntu-22.04)** - Linux平台PIZ测试
5. **PIZ Cross-Platform Comparison** - 跨平台比较
6. **PIZ Sealing Evidence Generation** - 证据生成
7. **PIZ Final Gate** - 最终门禁

**所有job必须全部通过才能合并PR!**

---

## ⚠️ 重要注意事项

1. **必须先合并main分支** - 否则CI workflow文件不完整
2. **保持PR2新增功能完整**:
   - Decorrelated jitter (Netflix/AWS pattern)
   - Circuit breaker (Martin Fowler pattern)
   - Dead Letter Queue (DLQ)
   - Idempotent transitions
   - Heartbeat monitoring
   - 3个新FailureReason (heartbeatTimeout, stalledProcessing, resourceExhausted)
   - 1个新CancelReason (systemTimeout)
3. **所有switch语句必须exhaustive**
4. **本地测试必须100%通过后才能push**
5. **不要修改main分支已有的逻辑**

---

## 📋 最终检查清单

- [ ] `git merge origin/main` 完成，无冲突
- [ ] 所有文件header更新为 `PR2-JSM-3.0-merged`
- [ ] `JobState.swift` 包含 `capacitySaturated` (9个状态)
- [ ] `ContractConstants.swift` 计数正确 (9 states, 15 transitions)
- [ ] `JobStateMachine.swift` 包含 `PROCESSING→CAPACITY_SATURATED` 转换
- [ ] `ProgressEstimator.swift` switch包含 `.capacitySaturated`
- [ ] `TransitionSpan.swift` switch包含 `.capacitySaturated`
- [ ] 所有其他文件的switch语句都exhaustive
- [ ] `swift build` 无错误
- [ ] `swift test` 全部通过
- [ ] `swift test --filter PIZ` 通过
- [ ] 无 "missing case" 警告

---

## 📝 Commit Message

```
fix(pr2): merge main and add capacitySaturated state support

- Merge origin/main to incorporate PR1 C-Class capacitySaturated state
- Update contract version to PR2-JSM-3.0-merged (9 states, 15 transitions)
- Fix exhaustive switch statements in all files
- Ensure all PR2 enhancements preserved:
  - Decorrelated jitter (Netflix/AWS pattern)
  - Circuit breaker pattern
  - Dead Letter Queue (DLQ)
  - Idempotent transitions
  - Heartbeat monitoring (3 new FailureReasons, 1 new CancelReason)

All local tests pass.

Co-Authored-By: Claude <noreply@anthropic.com>
```

---

## 🔁 如果还有失败

1. 查看具体错误: `swift build 2>&1 | grep -A5 "error:"`
2. 查看测试失败: `swift test 2>&1 | grep -B5 -A10 "failed"`
3. 逐个修复，每次修复后重新运行测试
4. **不要push直到所有本地测试通过**
