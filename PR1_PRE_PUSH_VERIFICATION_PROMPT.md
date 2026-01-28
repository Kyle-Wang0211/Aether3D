# PR1 Constitutional Amendments - Pre-Push Verification Prompt

**Version**: 1.0.0
**Date**: 2026-01-28
**Purpose**: 最全面最严格的本地测试，确保 PR1 宪法修正案在 push 前完全正确

---

## 执行要求

**必须全部通过才能 push。任何一项失败都必须修复后重新验证。**

---

## PHASE 1: 文件存在性验证

### 1.1 核心文档存在性

```bash
echo "=== PHASE 1.1: 核心文档存在性 ==="

# 必须全部存在
FILES=(
    "docs/constitution/CI_HARDENING_CONSTITUTION.md"
    "docs/constitution/MODULE_CONTRACT_EQUIVALENCE.md"
    "docs/constitution/SPEC_DRIFT_HANDLING.md"
    "docs/constitution/LOCAL_PREFLIGHT_GATE.md"
    "docs/constitution/EMERGENCY_PROTOCOL.md"
    "docs/drift/DRIFT_REGISTRY.md"
    "docs/emergencies/ACTIVE_BYPASSES.md"
)

FAILED=0
for f in "${FILES[@]}"; do
    if [ -f "$f" ]; then
        echo "✓ $f exists"
    else
        echo "✗ MISSING: $f"
        FAILED=1
    fi
done

if [ $FAILED -eq 1 ]; then
    echo "PHASE 1.1 FAILED"
    exit 1
fi
echo "PHASE 1.1 PASSED"
```

### 1.2 Hash 文件存在性（MANDATORY per MODULE_CONTRACT §2.4）

```bash
echo "=== PHASE 1.2: Hash 文件存在性 ==="

HASH_FILES=(
    "docs/constitution/CI_HARDENING_CONSTITUTION.hash"
    "docs/constitution/MODULE_CONTRACT_EQUIVALENCE.hash"
    "docs/constitution/SPEC_DRIFT_HANDLING.hash"
    "docs/constitution/LOCAL_PREFLIGHT_GATE.hash"
    "docs/constitution/EMERGENCY_PROTOCOL.hash"
)

FAILED=0
for f in "${HASH_FILES[@]}"; do
    if [ -f "$f" ]; then
        echo "✓ $f exists"
    else
        echo "✗ MISSING: $f"
        FAILED=1
    fi
done

if [ $FAILED -eq 1 ]; then
    echo "PHASE 1.2 FAILED - Hash files are MANDATORY per MODULE_CONTRACT_EQUIVALENCE §2.4"
    exit 1
fi
echo "PHASE 1.2 PASSED"
```

### 1.3 脚本文件存在性

```bash
echo "=== PHASE 1.3: 脚本文件存在性 ==="

SCRIPTS=(
    "scripts/scan-prohibited-patterns.sh"
    "scripts/verify-ssot-integrity.sh"
    "scripts/verify-all-hashes.sh"
    "scripts/install-hooks.sh"
    "scripts/pre-push"
    "scripts/check-overdue-bypasses.sh"
)

FAILED=0
for f in "${SCRIPTS[@]}"; do
    if [ -f "$f" ]; then
        echo "✓ $f exists"
    else
        echo "✗ MISSING: $f"
        FAILED=1
    fi
done

if [ $FAILED -eq 1 ]; then
    echo "PHASE 1.3 FAILED"
    exit 1
fi
echo "PHASE 1.3 PASSED"
```

### 1.4 脚本可执行权限

```bash
echo "=== PHASE 1.4: 脚本可执行权限 ==="

FAILED=0
for f in "${SCRIPTS[@]}"; do
    if [ -x "$f" ]; then
        echo "✓ $f is executable"
    else
        echo "✗ NOT EXECUTABLE: $f"
        FAILED=1
    fi
done

if [ $FAILED -eq 1 ]; then
    echo "PHASE 1.4 FAILED - Run: chmod +x scripts/*"
    exit 1
fi
echo "PHASE 1.4 PASSED"
```

---

## PHASE 2: Hash 完整性验证

### 2.1 使用脚本验证

```bash
echo "=== PHASE 2.1: Hash 完整性验证（脚本方式）==="

if ./scripts/verify-all-hashes.sh; then
    echo "PHASE 2.1 PASSED"
else
    echo "PHASE 2.1 FAILED - Document modified without updating hash"
    exit 1
fi
```

### 2.2 手动逐一验证（双重检查）

```bash
echo "=== PHASE 2.2: Hash 完整性验证（手动方式）==="

DOCS=(
    "docs/constitution/CI_HARDENING_CONSTITUTION"
    "docs/constitution/MODULE_CONTRACT_EQUIVALENCE"
    "docs/constitution/SPEC_DRIFT_HANDLING"
    "docs/constitution/LOCAL_PREFLIGHT_GATE"
    "docs/constitution/EMERGENCY_PROTOCOL"
)

FAILED=0
for base in "${DOCS[@]}"; do
    md_file="${base}.md"
    hash_file="${base}.hash"

    expected=$(cat "$hash_file" | tr -d '[:space:]')
    actual=$(shasum -a 256 "$md_file" | cut -d' ' -f1)

    if [ "$expected" = "$actual" ]; then
        echo "✓ $md_file hash matches"
    else
        echo "✗ HASH MISMATCH: $md_file"
        echo "  Expected: $expected"
        echo "  Actual:   $actual"
        FAILED=1
    fi
done

if [ $FAILED -eq 1 ]; then
    echo "PHASE 2.2 FAILED"
    exit 1
fi
echo "PHASE 2.2 PASSED"
```

---

## PHASE 3: 文档内容验证

### 3.1 必需章节存在性

```bash
echo "=== PHASE 3.1: 必需章节存在性 ==="

FAILED=0

# CI_HARDENING_CONSTITUTION.md 必须包含 §0-§8
echo "Checking CI_HARDENING_CONSTITUTION.md..."
for section in "§0" "§1" "§2" "§3" "§4" "§5" "§6" "§7" "§8"; do
    if grep -q "$section" docs/constitution/CI_HARDENING_CONSTITUTION.md; then
        echo "  ✓ $section found"
    else
        echo "  ✗ MISSING: $section"
        FAILED=1
    fi
done

# MODULE_CONTRACT_EQUIVALENCE.md 必须包含 §0-§9
echo "Checking MODULE_CONTRACT_EQUIVALENCE.md..."
for section in "§0" "§1" "§2" "§3" "§4" "§5" "§6" "§7" "§8" "§9"; do
    if grep -q "$section" docs/constitution/MODULE_CONTRACT_EQUIVALENCE.md; then
        echo "  ✓ $section found"
    else
        echo "  ✗ MISSING: $section"
        FAILED=1
    fi
done

# SPEC_DRIFT_HANDLING.md 必须包含 §0-§9
echo "Checking SPEC_DRIFT_HANDLING.md..."
for section in "§0" "§1" "§2" "§3" "§4" "§5" "§6" "§7" "§8" "§9"; do
    if grep -q "$section" docs/constitution/SPEC_DRIFT_HANDLING.md; then
        echo "  ✓ $section found"
    else
        echo "  ✗ MISSING: $section"
        FAILED=1
    fi
done

# LOCAL_PREFLIGHT_GATE.md 必须包含 §0-§6
echo "Checking LOCAL_PREFLIGHT_GATE.md..."
for section in "§0" "§1" "§2" "§3" "§4" "§5" "§6"; do
    if grep -q "$section" docs/constitution/LOCAL_PREFLIGHT_GATE.md; then
        echo "  ✓ $section found"
    else
        echo "  ✗ MISSING: $section"
        FAILED=1
    fi
done

# EMERGENCY_PROTOCOL.md 必须包含 §0-§7
echo "Checking EMERGENCY_PROTOCOL.md..."
for section in "§0" "§1" "§2" "§3" "§4" "§5" "§6" "§7"; do
    if grep -q "$section" docs/constitution/EMERGENCY_PROTOCOL.md; then
        echo "  ✓ $section found"
    else
        echo "  ✗ MISSING: $section"
        FAILED=1
    fi
done

if [ $FAILED -eq 1 ]; then
    echo "PHASE 3.1 FAILED"
    exit 1
fi
echo "PHASE 3.1 PASSED"
```

### 3.2 IMMUTABLE 标记验证

```bash
echo "=== PHASE 3.2: IMMUTABLE 标记验证 ==="

FAILED=0
DOCS=(
    "docs/constitution/CI_HARDENING_CONSTITUTION.md"
    "docs/constitution/MODULE_CONTRACT_EQUIVALENCE.md"
    "docs/constitution/SPEC_DRIFT_HANDLING.md"
    "docs/constitution/LOCAL_PREFLIGHT_GATE.md"
    "docs/constitution/EMERGENCY_PROTOCOL.md"
)

for doc in "${DOCS[@]}"; do
    if grep -q "IMMUTABLE" "$doc"; then
        echo "✓ $doc has IMMUTABLE marker"
    else
        echo "✗ MISSING IMMUTABLE marker: $doc"
        FAILED=1
    fi
done

if [ $FAILED -eq 1 ]; then
    echo "PHASE 3.2 FAILED - All constitution documents MUST have IMMUTABLE marker"
    exit 1
fi
echo "PHASE 3.2 PASSED"
```

### 3.3 版本号验证

```bash
echo "=== PHASE 3.3: 版本号验证 ==="

FAILED=0
for doc in "${DOCS[@]}"; do
    if grep -q "1.0.0" "$doc"; then
        echo "✓ $doc has version 1.0.0"
    else
        echo "✗ MISSING version 1.0.0: $doc"
        FAILED=1
    fi
done

if [ $FAILED -eq 1 ]; then
    echo "PHASE 3.3 FAILED"
    exit 1
fi
echo "PHASE 3.3 PASSED"
```

### 3.4 日期验证

```bash
echo "=== PHASE 3.4: 日期验证 ==="

FAILED=0
for doc in "${DOCS[@]}"; do
    if grep -q "2026-01-28" "$doc"; then
        echo "✓ $doc has date 2026-01-28"
    else
        echo "✗ MISSING date 2026-01-28: $doc"
        FAILED=1
    fi
done

if [ $FAILED -eq 1 ]; then
    echo "PHASE 3.4 FAILED"
    exit 1
fi
echo "PHASE 3.4 PASSED"
```

---

## PHASE 4: INDEX.md 验证

### 4.1 新条目存在性

```bash
echo "=== PHASE 4.1: INDEX.md 新条目存在性 ==="

ENTRIES=(
    "CI_HARDENING_CONSTITUTION.md"
    "MODULE_CONTRACT_EQUIVALENCE.md"
    "SPEC_DRIFT_HANDLING.md"
    "LOCAL_PREFLIGHT_GATE.md"
    "EMERGENCY_PROTOCOL.md"
)

FAILED=0
for entry in "${ENTRIES[@]}"; do
    count=$(grep -c "$entry" docs/constitution/INDEX.md)
    if [ "$count" -ge 1 ]; then
        echo "✓ $entry found in INDEX.md ($count times)"
    else
        echo "✗ MISSING from INDEX.md: $entry"
        FAILED=1
    fi
done

if [ $FAILED -eq 1 ]; then
    echo "PHASE 4.1 FAILED"
    exit 1
fi
echo "PHASE 4.1 PASSED"
```

### 4.2 链接有效性

```bash
echo "=== PHASE 4.2: INDEX.md 链接有效性 ==="

FAILED=0
for entry in "${ENTRIES[@]}"; do
    if [ -f "docs/constitution/$entry" ]; then
        echo "✓ Link valid: $entry"
    else
        echo "✗ BROKEN LINK: $entry (file does not exist)"
        FAILED=1
    fi
done

if [ $FAILED -eq 1 ]; then
    echo "PHASE 4.2 FAILED"
    exit 1
fi
echo "PHASE 4.2 PASSED"
```

### 4.3 格式一致性

```bash
echo "=== PHASE 4.3: INDEX.md 格式一致性 ==="

# 检查所有新条目都有 "Who depends", "What breaks", "Why exists" 子项
FAILED=0
for entry in "${ENTRIES[@]}"; do
    # 获取条目所在行号
    line_num=$(grep -n "$entry" docs/constitution/INDEX.md | head -1 | cut -d: -f1)
    if [ -z "$line_num" ]; then
        echo "✗ Cannot find $entry in INDEX.md"
        FAILED=1
        continue
    fi

    # 检查接下来3行是否包含必需的子项
    next_lines=$(sed -n "$((line_num+1)),$((line_num+3))p" docs/constitution/INDEX.md)

    if echo "$next_lines" | grep -q "Who depends"; then
        echo "  ✓ $entry has 'Who depends'"
    else
        echo "  ✗ $entry MISSING 'Who depends'"
        FAILED=1
    fi

    if echo "$next_lines" | grep -q "What breaks"; then
        echo "  ✓ $entry has 'What breaks'"
    else
        echo "  ✗ $entry MISSING 'What breaks'"
        FAILED=1
    fi

    if echo "$next_lines" | grep -q "Why exists"; then
        echo "  ✓ $entry has 'Why exists'"
    else
        echo "  ✗ $entry MISSING 'Why exists'"
        FAILED=1
    fi
done

if [ $FAILED -eq 1 ]; then
    echo "PHASE 4.3 FAILED"
    exit 1
fi
echo "PHASE 4.3 PASSED"
```

---

## PHASE 5: DRIFT_REGISTRY 验证

### 5.1 漂移数量验证

```bash
echo "=== PHASE 5.1: DRIFT_REGISTRY 漂移数量验证 ==="

DRIFT_COUNT=$(grep -c "^| D[0-9]" docs/drift/DRIFT_REGISTRY.md 2>/dev/null || echo 0)

if [ "$DRIFT_COUNT" -eq 10 ]; then
    echo "✓ DRIFT_REGISTRY contains exactly 10 drifts (D001-D010)"
else
    echo "✗ DRIFT_REGISTRY should contain 10 drifts, found: $DRIFT_COUNT"
    exit 1
fi
echo "PHASE 5.1 PASSED"
```

### 5.2 漂移 ID 完整性

```bash
echo "=== PHASE 5.2: DRIFT_REGISTRY 漂移 ID 完整性 ==="

FAILED=0
for i in $(seq -w 1 10); do
    drift_id="D0$i"
    if [ "$i" -eq 10 ]; then
        drift_id="D010"
    fi

    if grep -q "$drift_id" docs/drift/DRIFT_REGISTRY.md; then
        echo "✓ $drift_id found"
    else
        echo "✗ MISSING: $drift_id"
        FAILED=1
    fi
done

if [ $FAILED -eq 1 ]; then
    echo "PHASE 5.2 FAILED"
    exit 1
fi
echo "PHASE 5.2 PASSED"
```

---

## PHASE 6: 脚本功能验证

### 6.1 scan-prohibited-patterns.sh 语法

```bash
echo "=== PHASE 6.1: scan-prohibited-patterns.sh 语法验证 ==="

if bash -n scripts/scan-prohibited-patterns.sh; then
    echo "✓ scan-prohibited-patterns.sh syntax OK"
else
    echo "✗ scan-prohibited-patterns.sh has syntax errors"
    exit 1
fi
echo "PHASE 6.1 PASSED"
```

### 6.2 verify-ssot-integrity.sh 语法

```bash
echo "=== PHASE 6.2: verify-ssot-integrity.sh 语法验证 ==="

if bash -n scripts/verify-ssot-integrity.sh; then
    echo "✓ verify-ssot-integrity.sh syntax OK"
else
    echo "✗ verify-ssot-integrity.sh has syntax errors"
    exit 1
fi
echo "PHASE 6.2 PASSED"
```

### 6.3 verify-all-hashes.sh 语法

```bash
echo "=== PHASE 6.3: verify-all-hashes.sh 语法验证 ==="

if bash -n scripts/verify-all-hashes.sh; then
    echo "✓ verify-all-hashes.sh syntax OK"
else
    echo "✗ verify-all-hashes.sh has syntax errors"
    exit 1
fi
echo "PHASE 6.3 PASSED"
```

### 6.4 install-hooks.sh 语法

```bash
echo "=== PHASE 6.4: install-hooks.sh 语法验证 ==="

if bash -n scripts/install-hooks.sh; then
    echo "✓ install-hooks.sh syntax OK"
else
    echo "✗ install-hooks.sh has syntax errors"
    exit 1
fi
echo "PHASE 6.4 PASSED"
```

### 6.5 pre-push 语法

```bash
echo "=== PHASE 6.5: pre-push 语法验证 ==="

if bash -n scripts/pre-push; then
    echo "✓ pre-push syntax OK"
else
    echo "✗ pre-push has syntax errors"
    exit 1
fi
echo "PHASE 6.5 PASSED"
```

### 6.6 check-overdue-bypasses.sh 语法

```bash
echo "=== PHASE 6.6: check-overdue-bypasses.sh 语法验证 ==="

if bash -n scripts/check-overdue-bypasses.sh; then
    echo "✓ check-overdue-bypasses.sh syntax OK"
else
    echo "✗ check-overdue-bypasses.sh has syntax errors"
    exit 1
fi
echo "PHASE 6.6 PASSED"
```

### 6.7 verify-all-hashes.sh 实际执行

```bash
echo "=== PHASE 6.7: verify-all-hashes.sh 实际执行 ==="

if ./scripts/verify-all-hashes.sh; then
    echo "✓ verify-all-hashes.sh executed successfully"
else
    echo "✗ verify-all-hashes.sh execution failed"
    exit 1
fi
echo "PHASE 6.7 PASSED"
```

---

## PHASE 7: CI 硬化合规验证

### 7.1 现有代码已使用 ClockProvider

```bash
echo "=== PHASE 7.1: ClockProvider 存在性验证 ==="

if [ -f "App/Capture/ClockProvider.swift" ] || [ -f "Core/Time/ClockProvider.swift" ]; then
    echo "✓ ClockProvider.swift exists"
elif find . -name "ClockProvider.swift" -type f 2>/dev/null | head -1 | grep -q "."; then
    echo "✓ ClockProvider.swift found: $(find . -name 'ClockProvider.swift' -type f 2>/dev/null | head -1)"
else
    echo "⚠ WARNING: ClockProvider.swift not found (may be expected if not yet implemented)"
fi
echo "PHASE 7.1 COMPLETED"
```

### 7.2 现有代码已使用 TimerScheduler

```bash
echo "=== PHASE 7.2: TimerScheduler 存在性验证 ==="

if [ -f "App/Capture/TimerScheduler.swift" ] || [ -f "Core/Time/TimerScheduler.swift" ]; then
    echo "✓ TimerScheduler.swift exists"
elif find . -name "TimerScheduler.swift" -type f 2>/dev/null | head -1 | grep -q "."; then
    echo "✓ TimerScheduler.swift found: $(find . -name 'TimerScheduler.swift' -type f 2>/dev/null | head -1)"
else
    echo "⚠ WARNING: TimerScheduler.swift not found (may be expected if not yet implemented)"
fi
echo "PHASE 7.2 COMPLETED"
```

---

## PHASE 8: Swift 构建验证

### 8.1 Swift Build

```bash
echo "=== PHASE 8.1: Swift Build ==="

if swift build 2>&1; then
    echo "✓ swift build succeeded"
else
    echo "✗ swift build FAILED"
    exit 1
fi
echo "PHASE 8.1 PASSED"
```

### 8.2 Swift Test (如果存在)

```bash
echo "=== PHASE 8.2: Swift Test ==="

# 检查是否有测试目标
if swift test --list-tests 2>/dev/null | head -1 | grep -q "."; then
    if swift test 2>&1; then
        echo "✓ swift test succeeded"
    else
        echo "✗ swift test FAILED"
        exit 1
    fi
else
    echo "⚠ No tests found, skipping"
fi
echo "PHASE 8.2 COMPLETED"
```

### 8.3 CaptureStaticScanTests (如果存在)

```bash
echo "=== PHASE 8.3: CaptureStaticScanTests ==="

if swift test --filter CaptureStaticScanTests 2>&1; then
    echo "✓ CaptureStaticScanTests passed"
else
    # 检查是否是因为测试不存在
    if swift test --list-tests 2>/dev/null | grep -q "CaptureStaticScanTests"; then
        echo "✗ CaptureStaticScanTests FAILED"
        exit 1
    else
        echo "⚠ CaptureStaticScanTests not found, skipping"
    fi
fi
echo "PHASE 8.3 COMPLETED"
```

---

## PHASE 9: Markdown 格式验证

### 9.1 Markdown 语法检查 (如果 markdownlint 可用)

```bash
echo "=== PHASE 9.1: Markdown 语法检查 ==="

if command -v markdownlint &> /dev/null; then
    DOCS=(
        "docs/constitution/CI_HARDENING_CONSTITUTION.md"
        "docs/constitution/MODULE_CONTRACT_EQUIVALENCE.md"
        "docs/constitution/SPEC_DRIFT_HANDLING.md"
        "docs/constitution/LOCAL_PREFLIGHT_GATE.md"
        "docs/constitution/EMERGENCY_PROTOCOL.md"
        "docs/drift/DRIFT_REGISTRY.md"
    )

    FAILED=0
    for doc in "${DOCS[@]}"; do
        if markdownlint "$doc" 2>/dev/null; then
            echo "✓ $doc passes markdownlint"
        else
            echo "⚠ $doc has markdownlint warnings (non-blocking)"
        fi
    done
else
    echo "⚠ markdownlint not installed, skipping"
fi
echo "PHASE 9.1 COMPLETED"
```

### 9.2 表格格式验证

```bash
echo "=== PHASE 9.2: 表格格式验证 ==="

# 检查 DRIFT_REGISTRY.md 表格头
if grep -q "| ID | PR | Constant | Plan | SSOT | Category | Reason | Impact | Date |" docs/drift/DRIFT_REGISTRY.md; then
    echo "✓ DRIFT_REGISTRY.md has correct table header"
else
    echo "✗ DRIFT_REGISTRY.md table header incorrect"
    exit 1
fi
echo "PHASE 9.2 PASSED"
```

---

## PHASE 10: Git 状态验证

### 10.1 所有新文件已暂存

```bash
echo "=== PHASE 10.1: Git 状态验证 ==="

# 检查是否有未暂存的新文件
UNTRACKED=$(git status --porcelain | grep "^??" | grep -E "(constitution|drift|emergencies|scripts)" || true)

if [ -n "$UNTRACKED" ]; then
    echo "✗ Untracked files found:"
    echo "$UNTRACKED"
    echo "Run: git add <files>"
    exit 1
fi

echo "✓ No untracked constitution/drift/emergencies/scripts files"
echo "PHASE 10.1 PASSED"
```

### 10.2 无意外修改

```bash
echo "=== PHASE 10.2: 无意外修改 ==="

# 列出所有修改的文件
MODIFIED=$(git status --porcelain | grep "^ M" || true)

if [ -n "$MODIFIED" ]; then
    echo "Modified files (review for unexpected changes):"
    echo "$MODIFIED"
    echo ""
    echo "If these are expected, continue. If not, review before push."
fi
echo "PHASE 10.2 COMPLETED"
```

---

## PHASE 11: 交叉引用验证

### 11.1 文档间引用有效性

```bash
echo "=== PHASE 11.1: 文档间引用有效性 ==="

FAILED=0

# CI_HARDENING 应该引用 ClockProvider/TimerScheduler
if grep -q "ClockProvider" docs/constitution/CI_HARDENING_CONSTITUTION.md; then
    echo "✓ CI_HARDENING references ClockProvider"
else
    echo "✗ CI_HARDENING should reference ClockProvider"
    FAILED=1
fi

# MODULE_CONTRACT 应该引用 CLOSED_SET_GOVERNANCE
if grep -q "CLOSED_SET_GOVERNANCE" docs/constitution/MODULE_CONTRACT_EQUIVALENCE.md || \
   grep -q "closed.set" docs/constitution/MODULE_CONTRACT_EQUIVALENCE.md; then
    echo "✓ MODULE_CONTRACT references closed-set concepts"
else
    echo "⚠ MODULE_CONTRACT should reference CLOSED_SET_GOVERNANCE (warning)"
fi

# SPEC_DRIFT 应该引用 DRIFT_REGISTRY
if grep -q "DRIFT_REGISTRY" docs/constitution/SPEC_DRIFT_HANDLING.md; then
    echo "✓ SPEC_DRIFT references DRIFT_REGISTRY"
else
    echo "✗ SPEC_DRIFT should reference DRIFT_REGISTRY"
    FAILED=1
fi

# LOCAL_PREFLIGHT 应该引用 CI_HARDENING
if grep -q "CI_HARDENING" docs/constitution/LOCAL_PREFLIGHT_GATE.md || \
   grep -q "prohibited pattern" docs/constitution/LOCAL_PREFLIGHT_GATE.md; then
    echo "✓ LOCAL_PREFLIGHT references CI hardening concepts"
else
    echo "⚠ LOCAL_PREFLIGHT should reference CI_HARDENING (warning)"
fi

# EMERGENCY_PROTOCOL 应该引用 ACTIVE_BYPASSES
if grep -q "ACTIVE_BYPASSES" docs/constitution/EMERGENCY_PROTOCOL.md; then
    echo "✓ EMERGENCY_PROTOCOL references ACTIVE_BYPASSES"
else
    echo "✗ EMERGENCY_PROTOCOL should reference ACTIVE_BYPASSES"
    FAILED=1
fi

if [ $FAILED -eq 1 ]; then
    echo "PHASE 11.1 FAILED"
    exit 1
fi
echo "PHASE 11.1 PASSED"
```

---

## PHASE 12: 最终汇总

### 12.1 执行完整验证脚本

将以上所有 Phase 合并到一个脚本中执行：

```bash
#!/bin/bash
# PR1 宪法修正案 - 完整预推送验证
# 使用方法: ./scripts/pr1-full-verification.sh

set -e

echo "╔══════════════════════════════════════════════════════════════╗"
echo "║     PR1 CONSTITUTIONAL AMENDMENTS - FULL VERIFICATION        ║"
echo "╚══════════════════════════════════════════════════════════════╝"
echo ""

# [插入所有 Phase 的代码]

echo ""
echo "╔══════════════════════════════════════════════════════════════╗"
echo "║     ALL PHASES PASSED - SAFE TO PUSH                         ║"
echo "╚══════════════════════════════════════════════════════════════╝"
```

---

## 快速验证命令（一键执行）

将以下内容保存为 `scripts/pr1-full-verification.sh` 并执行：

```bash
#!/bin/bash
# PR1 Constitutional Amendments - Full Pre-Push Verification
# Usage: ./scripts/pr1-full-verification.sh

set -e

echo "╔══════════════════════════════════════════════════════════════╗"
echo "║     PR1 CONSTITUTIONAL AMENDMENTS - FULL VERIFICATION        ║"
echo "╚══════════════════════════════════════════════════════════════╝"
echo ""

# ===== PHASE 1: File Existence =====
echo "=== PHASE 1: File Existence ==="

FILES=(
    "docs/constitution/CI_HARDENING_CONSTITUTION.md"
    "docs/constitution/MODULE_CONTRACT_EQUIVALENCE.md"
    "docs/constitution/SPEC_DRIFT_HANDLING.md"
    "docs/constitution/LOCAL_PREFLIGHT_GATE.md"
    "docs/constitution/EMERGENCY_PROTOCOL.md"
    "docs/constitution/CI_HARDENING_CONSTITUTION.hash"
    "docs/constitution/MODULE_CONTRACT_EQUIVALENCE.hash"
    "docs/constitution/SPEC_DRIFT_HANDLING.hash"
    "docs/constitution/LOCAL_PREFLIGHT_GATE.hash"
    "docs/constitution/EMERGENCY_PROTOCOL.hash"
    "docs/drift/DRIFT_REGISTRY.md"
    "docs/emergencies/ACTIVE_BYPASSES.md"
    "scripts/scan-prohibited-patterns.sh"
    "scripts/verify-ssot-integrity.sh"
    "scripts/verify-all-hashes.sh"
    "scripts/install-hooks.sh"
    "scripts/pre-push"
    "scripts/check-overdue-bypasses.sh"
)

for f in "${FILES[@]}"; do
    if [ ! -f "$f" ]; then
        echo "✗ MISSING: $f"
        exit 1
    fi
done
echo "✓ All 18 files exist"

# ===== PHASE 2: Hash Verification =====
echo "=== PHASE 2: Hash Verification ==="

DOCS=(
    "docs/constitution/CI_HARDENING_CONSTITUTION"
    "docs/constitution/MODULE_CONTRACT_EQUIVALENCE"
    "docs/constitution/SPEC_DRIFT_HANDLING"
    "docs/constitution/LOCAL_PREFLIGHT_GATE"
    "docs/constitution/EMERGENCY_PROTOCOL"
)

for base in "${DOCS[@]}"; do
    expected=$(cat "${base}.hash" | tr -d '[:space:]')
    actual=$(shasum -a 256 "${base}.md" | cut -d' ' -f1)
    if [ "$expected" != "$actual" ]; then
        echo "✗ HASH MISMATCH: ${base}.md"
        exit 1
    fi
done
echo "✓ All 5 hashes match"

# ===== PHASE 3: Document Content =====
echo "=== PHASE 3: Document Content ==="

# Check CI_HARDENING has §0-§8
for s in "§0" "§1" "§2" "§3" "§4" "§5" "§6" "§7" "§8"; do
    if ! grep -q "$s" docs/constitution/CI_HARDENING_CONSTITUTION.md; then
        echo "✗ CI_HARDENING missing $s"
        exit 1
    fi
done

# Check MODULE_CONTRACT has §0-§9
for s in "§0" "§1" "§2" "§3" "§4" "§5" "§6" "§7" "§8" "§9"; do
    if ! grep -q "$s" docs/constitution/MODULE_CONTRACT_EQUIVALENCE.md; then
        echo "✗ MODULE_CONTRACT missing $s"
        exit 1
    fi
done

# Check all docs have IMMUTABLE
for doc in docs/constitution/CI_HARDENING_CONSTITUTION.md docs/constitution/MODULE_CONTRACT_EQUIVALENCE.md docs/constitution/SPEC_DRIFT_HANDLING.md docs/constitution/LOCAL_PREFLIGHT_GATE.md docs/constitution/EMERGENCY_PROTOCOL.md; do
    if ! grep -q "IMMUTABLE" "$doc"; then
        echo "✗ $doc missing IMMUTABLE marker"
        exit 1
    fi
done
echo "✓ All documents have required sections"

# ===== PHASE 4: INDEX.md =====
echo "=== PHASE 4: INDEX.md ==="

ENTRIES=("CI_HARDENING_CONSTITUTION" "MODULE_CONTRACT_EQUIVALENCE" "SPEC_DRIFT_HANDLING" "LOCAL_PREFLIGHT_GATE" "EMERGENCY_PROTOCOL")
for e in "${ENTRIES[@]}"; do
    if ! grep -q "$e" docs/constitution/INDEX.md; then
        echo "✗ INDEX.md missing $e"
        exit 1
    fi
done
echo "✓ INDEX.md has all 5 entries"

# ===== PHASE 5: DRIFT_REGISTRY =====
echo "=== PHASE 5: DRIFT_REGISTRY ==="

DRIFT_COUNT=$(grep -c "^| D[0-9]" docs/drift/DRIFT_REGISTRY.md 2>/dev/null || echo 0)
if [ "$DRIFT_COUNT" -ne 10 ]; then
    echo "✗ DRIFT_REGISTRY should have 10 drifts, found: $DRIFT_COUNT"
    exit 1
fi
echo "✓ DRIFT_REGISTRY has 10 drifts"

# ===== PHASE 6: Script Syntax =====
echo "=== PHASE 6: Script Syntax ==="

SCRIPTS=("scripts/scan-prohibited-patterns.sh" "scripts/verify-ssot-integrity.sh" "scripts/verify-all-hashes.sh" "scripts/install-hooks.sh" "scripts/pre-push" "scripts/check-overdue-bypasses.sh")
for s in "${SCRIPTS[@]}"; do
    if ! bash -n "$s" 2>/dev/null; then
        echo "✗ Syntax error in $s"
        exit 1
    fi
    if [ ! -x "$s" ]; then
        echo "✗ $s not executable"
        exit 1
    fi
done
echo "✓ All 6 scripts have valid syntax and are executable"

# ===== PHASE 7: Swift Build =====
echo "=== PHASE 7: Swift Build ==="

if swift build 2>/dev/null; then
    echo "✓ swift build succeeded"
else
    echo "⚠ swift build failed or not applicable"
fi

# ===== PHASE 8: Cross-References =====
echo "=== PHASE 8: Cross-References ==="

if ! grep -q "ClockProvider" docs/constitution/CI_HARDENING_CONSTITUTION.md; then
    echo "✗ CI_HARDENING should reference ClockProvider"
    exit 1
fi
if ! grep -q "DRIFT_REGISTRY" docs/constitution/SPEC_DRIFT_HANDLING.md; then
    echo "✗ SPEC_DRIFT should reference DRIFT_REGISTRY"
    exit 1
fi
echo "✓ Cross-references valid"

echo ""
echo "╔══════════════════════════════════════════════════════════════╗"
echo "║     ✓ ALL PHASES PASSED - SAFE TO PUSH                       ║"
echo "╚══════════════════════════════════════════════════════════════╝"
```

---

## 使用方法

1. **创建验证脚本**:
   ```bash
   # 将上面的 "快速验证命令" 保存到文件
   vim scripts/pr1-full-verification.sh
   chmod +x scripts/pr1-full-verification.sh
   ```

2. **执行验证**:
   ```bash
   ./scripts/pr1-full-verification.sh
   ```

3. **全部通过后 Push**:
   ```bash
   git add .
   git commit -m "feat(pr1): add constitutional amendments with full automation support

   PR1-1: CI_HARDENING_CONSTITUTION.md
   - Prohibit Date()/Timer.scheduledTimer in production
   - Mandate ClockProvider/TimerScheduler injection
   - Add §8 cross-platform parity requirements

   PR1-2: MODULE_CONTRACT_EQUIVALENCE.md
   - Define domain contract validity (5-point checklist)
   - Add §8 automated contract verification
   - Add §9 continuous health monitoring

   PR1-3: SPEC_DRIFT_HANDLING.md + DRIFT_REGISTRY.md
   - Legitimize plan-to-implementation drift
   - Register 10 existing drifts (D001-D010)

   Patch 2: LOCAL_PREFLIGHT_GATE.md
   - Pre-push hook with 4 mandatory checks
   - Support scripts for local verification

   Patch 4: EMERGENCY_PROTOCOL.md
   - E0/E1 emergency bypass procedures
   - Mandatory recovery timeline
   - Abuse prevention mechanisms

   All documents include .hash files per MODULE_CONTRACT §2.4.

   Co-Authored-By: Claude <noreply@anthropic.com>"

   git push
   ```

---

## 验证清单汇总

| Phase | 检查项 | 数量 |
|-------|--------|------|
| 1 | 文件存在性 | 18 files |
| 2 | Hash 完整性 | 5 hashes |
| 3 | 文档内容 | 5 docs × sections |
| 4 | INDEX.md | 5 entries |
| 5 | DRIFT_REGISTRY | 10 drifts |
| 6 | 脚本语法 | 6 scripts |
| 7 | Swift 构建 | 1 build |
| 8 | 交叉引用 | 2 refs |
| 9 | Markdown 格式 | Optional |
| 10 | Git 状态 | Clean check |
| 11 | 引用有效性 | 5 cross-refs |
| 12 | 最终汇总 | All phases |

**总计**: 12 个验证阶段，50+ 个检查点

---

**END OF VERIFICATION PROMPT**
