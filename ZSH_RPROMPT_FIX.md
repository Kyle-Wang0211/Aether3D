# ZSH RPROMPT 修复方案

## 问题描述
Cursor/VSCode 终端中出现错误：`__vsc_preexec:3: RPROMPT: parameter not set`

## 修复方案
在 `.zshenv`（zsh 最早加载的配置文件）中初始化所有提示相关变量，确保 VSCode/Cursor 的 hooks 在执行时这些变量已定义。

---

## 最少可执行命令序列（复制粘贴即可）

```bash
# 1. 创建 ~/.zshenv 并设置 RPROMPT 等变量
cat > ~/.zshenv << 'EOF'
# ============================================================================
# VSCode/Cursor zsh hook hardening (EARLIEST LOAD - .zshenv)
# WHY: Prevent __vsc_preexec from failing with "RPROMPT: parameter not set"
#      when set -u (nounset) is enabled. This file loads BEFORE .zshrc,
#      ensuring VSCode/Cursor hooks always have these variables defined.
# ============================================================================

# Ensure all prompt variables are defined (even if empty) to prevent
# set -u failures in VSCode/Cursor zsh hooks that execute before .zshrc loads
: "${RPROMPT:=}"
: "${RPS1:=}"
: "${PROMPT_COMMAND:=}"
: "${PROMPT:=}"
: "${PS1:=}"

# Explicitly export empty values to prevent any undefined variable errors
export RPROMPT RPS1 PROMPT_COMMAND PROMPT PS1
EOF

# 2. 如果 ZDOTDIR 被设置，也在那里创建 .zshenv
if [ -n "$ZDOTDIR" ] && [ "$ZDOTDIR" != "$HOME" ]; then
  mkdir -p "$ZDOTDIR"
  cat > "$ZDOTDIR/.zshenv" << 'EOF'
# ============================================================================
# VSCode/Cursor zsh hook hardening (EARLIEST LOAD - .zshenv)
# WHY: Prevent __vsc_preexec from failing with "RPROMPT: parameter not set"
#      when set -u (nounset) is enabled. This file loads BEFORE .zshrc,
#      ensuring VSCode/Cursor hooks always have these variables defined.
# ============================================================================

# Ensure all prompt variables are defined (even if empty) to prevent
# set -u failures in VSCode/Cursor zsh hooks that execute before .zshrc loads
: "${RPROMPT:=}"
: "${RPS1:=}"
: "${PROMPT_COMMAND:=}"
: "${PROMPT:=}"
: "${PS1:=}"

# Explicitly export empty values to prevent any undefined variable errors
export RPROMPT RPS1 PROMPT_COMMAND PROMPT PS1
EOF
  echo "✅ 已创建 $ZDOTDIR/.zshenv"
else
  echo "✅ 已创建 ~/.zshenv (ZDOTDIR 未设置或与 HOME 相同)"
fi
```

---

## 验证命令序列（复制粘贴即可）

```bash
# 验证修复是否生效（连续运行 10 次，要求零错误）

echo "=========================================="
echo "验证修复：连续运行 10 次测试"
echo "=========================================="

# 测试 1: git status -sb
echo ""
echo "测试 1: git status -sb (10 次)"
ERROR_COUNT=0
for i in {1..10}; do
  OUTPUT=$(zsh -c 'git status -sb 2>&1' 2>&1)
  if echo "$OUTPUT" | grep -qi "__vsc_preexec.*RPROMPT.*parameter not set"; then
    echo "❌ 第 $i 次运行发现错误"
    ERROR_COUNT=$((ERROR_COUNT + 1))
  fi
done
[ $ERROR_COUNT -eq 0 ] && echo "✅ git status -sb: 10/10 通过" || echo "❌ git status -sb: $ERROR_COUNT 次失败"

# 测试 2: git diff --stat
echo ""
echo "测试 2: git diff --stat (10 次)"
ERROR_COUNT=0
for i in {1..10}; do
  OUTPUT=$(zsh -c 'git diff --stat 2>&1' 2>&1)
  if echo "$OUTPUT" | grep -qi "__vsc_preexec.*RPROMPT.*parameter not set"; then
    echo "❌ 第 $i 次运行发现错误"
    ERROR_COUNT=$((ERROR_COUNT + 1))
  fi
done
[ $ERROR_COUNT -eq 0 ] && echo "✅ git diff --stat: 10/10 通过" || echo "❌ git diff --stat: $ERROR_COUNT 次失败"

# 测试 3: python3 -c 'print(1)'
echo ""
echo "测试 3: python3 -c 'print(1)' (10 次)"
ERROR_COUNT=0
for i in {1..10}; do
  OUTPUT=$(zsh -c 'python3 -c "print(1)" 2>&1' 2>&1)
  if echo "$OUTPUT" | grep -qi "__vsc_preexec.*RPROMPT.*parameter not set"; then
    echo "❌ 第 $i 次运行发现错误"
    ERROR_COUNT=$((ERROR_COUNT + 1))
  fi
done
[ $ERROR_COUNT -eq 0 ] && echo "✅ python3: 10/10 通过" || echo "❌ python3: $ERROR_COUNT 次失败"

# 测试 4: swift test --filter PIZ
echo ""
echo "测试 4: swift test --filter PIZ (10 次)"
ERROR_COUNT=0
for i in {1..10}; do
  OUTPUT=$(zsh -c 'swift test --filter PIZ 2>&1 | head -5' 2>&1)
  if echo "$OUTPUT" | grep -qi "__vsc_preexec.*RPROMPT.*parameter not set"; then
    echo "❌ 第 $i 次运行发现错误"
    ERROR_COUNT=$((ERROR_COUNT + 1))
  fi
done
[ $ERROR_COUNT -eq 0 ] && echo "✅ swift test: 10/10 通过" || echo "❌ swift test: $ERROR_COUNT 次失败"

echo ""
echo "=========================================="
echo "验证完成"
echo "=========================================="
```

---

## 验收标准
✅ 以上验证命令连续运行 10 次，报错出现次数为 0

## 技术说明

### 为什么使用 .zshenv？
- `.zshenv` 是 zsh 最早加载的配置文件，在所有其他配置文件之前加载
- 即使是非交互式 shell 也会加载 `.zshenv`
- VSCode/Cursor 的 `__vsc_preexec` hook 可能在 `.zshrc` 加载之前执行，因此必须在 `.zshenv` 中设置

### 为什么检查 ZDOTDIR？
- 如果 `$ZDOTDIR` 被设置，zsh 会从 `$ZDOTDIR` 目录加载配置文件，而不是 `$HOME`
- 为了确保修复在所有情况下生效，需要同时检查并设置 `$ZDOTDIR/.zshenv`

### 修复原理
- 使用 `: "${RPROMPT:=}"` 语法确保变量被定义（即使值为空字符串）
- 这种方式在 `set -u`（nounset）模式下也能正常工作
- 显式 export 确保变量在子 shell 中也可用
