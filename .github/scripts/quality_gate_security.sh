#!/bin/bash
# quality_gate_security.sh
# 安全质量门检查脚本
# 符合 v8.2 IRONCLAD: 零占位符容忍

set -e

echo "=========================================="
echo "Aether3D v8.2 IRONCLAD 安全质量门检查"
echo "=========================================="

SOURCES_DIR="Sources"
FAILED=0

# 检查1: hashValue滥用
echo ""
echo "检查1: hashValue滥用..."
HASHVALUE_COUNT=$(grep -rn "\.hashValue" --include="*.swift" "$SOURCES_DIR" | grep -v "Test" | wc -l | tr -d ' ')
if [ "$HASHVALUE_COUNT" -gt 0 ]; then
    echo "❌ 发现 $HASHVALUE_COUNT 处 hashValue 滥用:"
    grep -rn "\.hashValue" --include="*.swift" "$SOURCES_DIR" | grep -v "Test"
    FAILED=1
else
    echo "✅ 无 hashValue 滥用"
fi

# 检查2: Simplified/Placeholder注释
echo ""
echo "检查2: Simplified/Placeholder代码..."
SIMPLIFIED_COUNT=$(grep -rn "Simplified\|Placeholder" --include="*.swift" "$SOURCES_DIR" | grep -v "Test\|\.md" | wc -l | tr -d ' ')
if [ "$SIMPLIFIED_COUNT" -gt 0 ]; then
    echo "❌ 发现 $SIMPLIFIED_COUNT 处简化/占位符代码:"
    grep -rn "Simplified\|Placeholder" --include="*.swift" "$SOURCES_DIR" | grep -v "Test\|\.md"
    FAILED=1
else
    echo "✅ 无简化/占位符代码"
fi

# 检查3: return true/false 安全检查
echo ""
echo "检查3: 假安全检查..."
FAKE_CHECK=$(grep -rn "return true\|return false" --include="*.swift" "$SOURCES_DIR" | grep -i "detect\|valid\|check\|verify" | grep -v "Test" | wc -l | tr -d ' ')
if [ "$FAKE_CHECK" -gt 0 ]; then
    echo "⚠️ 发现 $FAKE_CHECK 处可疑的安全检查返回值 (请人工确认):"
    grep -rn "return true\|return false" --include="*.swift" "$SOURCES_DIR" | grep -i "detect\|valid\|check\|verify" | grep -v "Test"
fi

# 检查4: Double.random占位符
echo ""
echo "检查4: Double.random占位符..."
RANDOM_COUNT=$(grep -rn "Double\.random\|Int\.random" --include="*.swift" "$SOURCES_DIR" | grep -i "placeholder\|simplified" | wc -l | tr -d ' ')
if [ "$RANDOM_COUNT" -gt 0 ]; then
    echo "❌ 发现 $RANDOM_COUNT 处随机数占位符:"
    grep -rn "Double\.random\|Int\.random" --include="*.swift" "$SOURCES_DIR" | grep -i "placeholder\|simplified"
    FAILED=1
else
    echo "✅ 无随机数占位符"
fi

# 检查5: Data()返回占位符
echo ""
echo "检查5: Data()返回占位符..."
DATA_PLACEHOLDER=$(grep -rn "return Data()" --include="*.swift" "$SOURCES_DIR" | grep -i "placeholder" | wc -l | tr -d ' ')
if [ "$DATA_PLACEHOLDER" -gt 0 ]; then
    echo "❌ 发现 $DATA_PLACEHOLDER 处 Data() 返回占位符:"
    grep -rn "return Data()" --include="*.swift" "$SOURCES_DIR" | grep -i "placeholder"
    FAILED=1
else
    echo "✅ 无 Data() 返回占位符"
fi

# 检查6: CryptoKit使用
echo ""
echo "检查6: CryptoKit使用情况..."
CRYPTOKIT_COUNT=$(grep -rn "import CryptoKit" --include="*.swift" "$SOURCES_DIR" | wc -l | tr -d ' ')
echo "ℹ️ 找到 $CRYPTOKIT_COUNT 个文件使用 CryptoKit"

# 总结
echo ""
echo "=========================================="
if [ "$FAILED" -eq 1 ]; then
    echo "❌ 安全质量门检查失败"
    echo "请修复上述问题后重新提交"
    exit 1
else
    echo "✅ 安全质量门检查通过"
    exit 0
fi
