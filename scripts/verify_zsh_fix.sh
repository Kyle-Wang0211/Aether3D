#!/bin/zsh
# ============================================================================
# 验证 zsh RPROMPT 修复脚本
# 用途：验证 __vsc_preexec:3: RPROMPT: parameter not set 错误已完全消除
# ============================================================================

set -e

ERROR_COUNT=0
TOTAL_RUNS=10

echo "=========================================="
echo "开始验证 zsh RPROMPT 修复"
echo "=========================================="
echo ""

# 验证 .zshenv 存在
if [ ! -f ~/.zshenv ]; then
    echo "❌ 错误: ~/.zshenv 不存在"
    exit 1
fi
echo "✅ ~/.zshenv 存在"

# 验证 RPROMPT 在 .zshenv 中定义
if ! grep -q "RPROMPT" ~/.zshenv; then
    echo "❌ 错误: ~/.zshenv 中未找到 RPROMPT 定义"
    exit 1
fi
echo "✅ ~/.zshenv 包含 RPROMPT 定义"

# 检查 ZDOTDIR
if [ -n "$ZDOTDIR" ] && [ "$ZDOTDIR" != "$HOME" ]; then
    if [ ! -f "$ZDOTDIR/.zshenv" ]; then
        echo "⚠️  警告: ZDOTDIR=$ZDOTDIR 但 $ZDOTDIR/.zshenv 不存在"
    else
        echo "✅ $ZDOTDIR/.zshenv 存在"
    fi
fi

echo ""
echo "=========================================="
echo "运行 $TOTAL_RUNS 次验证测试"
echo "=========================================="
echo ""

for i in {1..$TOTAL_RUNS}; do
    echo "--- 第 $i 次运行 ---"
    
    # 测试 1: git status -sb
    OUTPUT=$(zsh -c 'source ~/.zshenv 2>&1; git status -sb 2>&1' 2>&1)
    if echo "$OUTPUT" | grep -q "__vsc_preexec.*RPROMPT.*parameter not set"; then
        echo "❌ git status -sb 失败: 发现 RPROMPT 错误"
        ERROR_COUNT=$((ERROR_COUNT + 1))
    fi
    
    # 测试 2: git diff --stat
    OUTPUT=$(zsh -c 'source ~/.zshenv 2>&1; git diff --stat 2>&1' 2>&1)
    if echo "$OUTPUT" | grep -q "__vsc_preexec.*RPROMPT.*parameter not set"; then
        echo "❌ git diff --stat 失败: 发现 RPROMPT 错误"
        ERROR_COUNT=$((ERROR_COUNT + 1))
    fi
    
    # 测试 3: python3 -c 'print(1)'
    OUTPUT=$(zsh -c 'source ~/.zshenv 2>&1; python3 -c "print(1)" 2>&1' 2>&1)
    if echo "$OUTPUT" | grep -q "__vsc_preexec.*RPROMPT.*parameter not set"; then
        echo "❌ python3 失败: 发现 RPROMPT 错误"
        ERROR_COUNT=$((ERROR_COUNT + 1))
    fi
    
    # 测试 4: swift test --filter PIZ
    OUTPUT=$(zsh -c 'source ~/.zshenv 2>&1; swift test --filter PIZ 2>&1 | head -5' 2>&1)
    if echo "$OUTPUT" | grep -q "__vsc_preexec.*RPROMPT.*parameter not set"; then
        echo "❌ swift test 失败: 发现 RPROMPT 错误"
        ERROR_COUNT=$((ERROR_COUNT + 1))
    fi
done

echo ""
echo "=========================================="
echo "验证结果"
echo "=========================================="
echo "总运行次数: $TOTAL_RUNS"
echo "错误次数: $ERROR_COUNT"
echo ""

if [ $ERROR_COUNT -eq 0 ]; then
    echo "✅ 验证通过：所有测试均无 RPROMPT 错误"
    exit 0
else
    echo "❌ 验证失败：发现 $ERROR_COUNT 个错误"
    exit 1
fi
