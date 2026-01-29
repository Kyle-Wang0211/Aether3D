# PR2-JSM 最终验证与推送提示词

## 🎯 任务目标

执行最终验证，确认所有修复正确后完成 git add、commit 和 push。

---

## ✅ 第一步：最终验证检查

执行以下所有验证命令，**必须全部通过**才能继续：

```bash
# 1. 清理并重新构建
swift package clean
swift build 2>&1 | tee /tmp/build.log

# 2. 检查是否有编译错误
if grep -i "error:" /tmp/build.log; then
  echo "❌ BUILD FAILED - 请修复错误后重试"
  exit 1
fi
echo "✅ Build passed"

# 3. 检查是否有 exhaustive switch 警告
if swift build 2>&1 | grep -i "exhaustive\|missing case"; then
  echo "❌ SWITCH NOT EXHAUSTIVE - 请修复后重试"
  exit 1
fi
echo "✅ No exhaustive switch warnings"

# 4. 运行所有测试
swift test 2>&1 | tee /tmp/test.log
if grep "failed" /tmp/test.log | grep -v "0 failed"; then
  echo "❌ TESTS FAILED - 请修复后重试"
  exit 1
fi
echo "✅ All tests passed"

# 5. 验证关键文件
echo "=== 验证合同版本 ==="
grep "CONTRACT_VERSION" Core/Jobs/ContractConstants.swift
grep "STATE_COUNT = 9" Core/Jobs/ContractConstants.swift && echo "✅ STATE_COUNT = 9"
grep "LEGAL_TRANSITION_COUNT = 15" Core/Jobs/ContractConstants.swift && echo "✅ TRANSITION_COUNT = 15"

echo "=== 验证 capacitySaturated ==="
grep "capacitySaturated" Core/Jobs/JobState.swift && echo "✅ JobState has capacitySaturated"
grep "capacitySaturated" Core/Jobs/ProgressEstimator.swift && echo "✅ ProgressEstimator fixed"
grep "capacitySaturated" Core/Jobs/JobStateMachine.swift && echo "✅ JobStateMachine has transitions"

echo "=== 验证 Header 一致性 ==="
grep -l "PR2-JSM-3.0-merged" Core/Jobs/*.swift | wc -l
# 预期输出: 12 (所有 Core/Jobs 文件)
```

---

## ✅ 第二步：Git 状态检查

```bash
# 查看当前状态
git status

# 查看所有更改的文件
git diff --name-only

# 查看统计信息
git diff --stat
```

---

## ✅ 第三步：Git Add

添加所有修改的文件：

```bash
# 添加 Core/Jobs 目录下的所有修改
git add Core/Jobs/JobState.swift
git add Core/Jobs/ContractConstants.swift
git add Core/Jobs/JobStateMachine.swift
git add Core/Jobs/JobStateMachineError.swift
git add Core/Jobs/FailureReason.swift
git add Core/Jobs/CancelReason.swift
git add Core/Jobs/RetryCalculator.swift
git add Core/Jobs/DLQEntry.swift
git add Core/Jobs/CircuitBreaker.swift
git add Core/Jobs/DeterministicEncoder.swift
git add Core/Jobs/TransitionSpan.swift
git add Core/Jobs/ProgressEstimator.swift

# 添加测试文件
git add Tests/Jobs/JobStateMachineTests.swift
git add Tests/Jobs/RetryCalculatorTests.swift
git add Tests/Jobs/CircuitBreakerTests.swift
git add Tests/Jobs/DeterministicEncoderTests.swift

# 添加 CI Workflow 文件（如果有更改）
git add .github/workflows/ci.yml
git add .github/workflows/ci-gate.yml

# 验证暂存区
git status
```

---

## ✅ 第四步：Git Commit

使用以下 commit message：

```bash
git commit -m "$(cat <<'EOF'
fix(pr2): merge main and add capacitySaturated state support

BREAKING CHANGE: Contract version updated to PR2-JSM-3.0-merged

Changes:
- Merge origin/main to incorporate PR1 C-Class capacitySaturated state
- Update contract version: PR2-JSM-3.0-merged
- States: 9 (added capacitySaturated)
- Transitions: 15 (added PROCESSING->CAPACITY_SATURATED, PACKAGING->CAPACITY_SATURATED)
- FailureReasons: 17 (PR2 additions preserved)
- CancelReasons: 3 (PR2 additions preserved)

Fixed:
- ProgressEstimator.swift switch exhaustiveness
- All JobState switch statements include capacitySaturated
- Contract header consistency across all 12 Core/Jobs files

Preserved PR2 Features:
- Decorrelated jitter (Netflix/AWS pattern)
- Circuit breaker (Martin Fowler pattern)
- Dead Letter Queue (DLQ)
- Idempotent transitions
- Heartbeat monitoring
- OpenTelemetry-compatible TransitionSpan

All local tests pass (44 tests).

Co-Authored-By: Claude <noreply@anthropic.com>
EOF
)"
```

---

## ✅ 第五步：Git Push

```bash
# 推送到远程仓库 (当前分支是 pr2)
git push origin pr2

# 如果需要 force push（谨慎使用）
# git push origin pr2 --force-with-lease
```

---

## 🔍 推送后验证

推送成功后，检查 GitHub Actions：

1. 打开 PR 页面
2. 等待 CI 运行完成
3. 验证所有 8 个 job 全部通过：
   - ✅ Preflight (Phase 0.5 guardrails)
   - ✅ Test & Lint
   - ✅ PIZ Tests (macos-15)
   - ✅ PIZ Tests (ubuntu-22.04)
   - ✅ PIZ Cross-Platform Comparison
   - ✅ PIZ Sealing Evidence Generation
   - ✅ PIZ Final Gate (no-skip policy)
   - ✅ CI Gate

---

## ⚠️ 如果 CI 失败

1. 查看失败的 job 日志
2. 复制错误信息
3. 本地重现并修复
4. 重新运行验证步骤
5. 再次 add、commit、push

---

## 📋 最终检查清单

在执行 push 之前，确认以下所有项目：

- [ ] `swift build` 无错误
- [ ] `swift test` 全部通过
- [ ] 无 "missing case" 警告
- [ ] `CONTRACT_VERSION = "PR2-JSM-3.0-merged"`
- [ ] `STATE_COUNT = 9`
- [ ] `LEGAL_TRANSITION_COUNT = 15`
- [ ] 所有 12 个 Core/Jobs 文件 header 一致
- [ ] `capacitySaturated` 在 JobState.swift 中存在
- [ ] `capacitySaturated` 在 ProgressEstimator.swift 的 switch 中
- [ ] CI workflow 文件已更新（包含 PIZ jobs）

**只有当以上所有项目都确认通过后，才能执行 push！**
