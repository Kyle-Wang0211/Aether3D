# PR4 CI Fix Prompt - CaptureProfile.swift 文件损坏修复

## 问题诊断

### CI 错误日志
```
/home/runner/work/Aether3D/Aether3D/Core/Constants/CaptureProfile.swift:2:2: error: expressions are not allowed at the top level
1 | //
2 | pr/4-capture-recording
  | `- error: expressions are not allowed at the top level
3 | //  CaptureProfile.swift
4 | //  Aether3D
```

### 根本原因

远程仓库中的 `Core/Constants/CaptureProfile.swift` 文件**头部被损坏**：
- 第 2 行变成了 `pr/4-capture-recording`（分支名）
- 这不是有效的 Swift 代码，导致编译失败

### 可能原因
1. Git filter 或 hook 意外修改了文件
2. 推送过程中文件损坏
3. 某种自动化脚本错误插入了分支名

---

## 修复步骤

### Step 1: 检查本地文件状态

```bash
# 查看本地文件头部
head -20 Core/Constants/CaptureProfile.swift
```

**期望输出**：
```swift
//
//  CaptureProfile.swift
//  Aether3D
//
//  PR#4 Capture Recording Enhancement
//
// ============================================================================
// CONSTITUTIONAL CONTRACT - DO NOT EDIT WITHOUT RFC
// Contract Version: PR4-CAPTURE-1.1
// States: N/A | Warnings: 32 | QualityPresets: 6 | ResolutionTiers: 7
// ============================================================================

import Foundation
```

**如果第 2 行是 `pr/4-capture-recording`，本地文件也损坏了。**

### Step 2A: 如果本地文件正确

直接重新推送：

```bash
# 方法 1: 修改提交并强制推送
git add Core/Constants/CaptureProfile.swift
git commit --amend --no-edit
git push --force-with-lease origin pr/4-capture-recording

# 方法 2: 创建新提交修复
git add Core/Constants/CaptureProfile.swift
git commit -m "fix(pr4): repair corrupted CaptureProfile.swift header

The file header was corrupted during push, causing CI build failure.
This commit restores the correct Swift file header.

Co-Authored-By: Claude <noreply@anthropic.com>"
git push origin pr/4-capture-recording
```

### Step 2B: 如果本地文件也损坏

需要重新创建文件。以下是**完整正确的文件内容**：

```swift
//
//  CaptureProfile.swift
//  Aether3D
//
//  PR#4 Capture Recording Enhancement
//
// ============================================================================
// CONSTITUTIONAL CONTRACT - DO NOT EDIT WITHOUT RFC
// Contract Version: PR4-CAPTURE-1.1
// States: N/A | Warnings: 32 | QualityPresets: 6 | ResolutionTiers: 7
// ============================================================================

import Foundation

/// Capture profile for different scanning scenarios
public enum CaptureProfile: UInt8, Codable, CaseIterable, Equatable {
    case standard = 1
    case smallObjectMacro = 2
    case largeScene = 3
    case proMacro = 4           // NEW: Pro-level macro scanning
    case cinematicScene = 5     // NEW: Cinematic capture mode

    /// Recommended settings for each profile
    public var recommendedSettings: ProfileSettings {
        switch self {
        case .standard:
            return ProfileSettings(
                minTier: .t1080p,
                preferredFps: 30,
                preferHDR: true,
                focusMode: .continuousAuto,
                scanPattern: .orbital
            )
        case .smallObjectMacro:
            return ProfileSettings(
                minTier: .t4K,
                preferredFps: 60,
                preferHDR: true,
                focusMode: .macro,
                scanPattern: .closeUp
            )
        case .largeScene:
            return ProfileSettings(
                minTier: .t4K,
                preferredFps: 30,
                preferHDR: true,
                focusMode: .continuousAuto,
                scanPattern: .walkthrough
            )
        case .proMacro:
            return ProfileSettings(
                minTier: .t4K,
                preferredFps: 60,
                preferHDR: true,
                focusMode: .macroLocked,
                scanPattern: .turntable
            )
        case .cinematicScene:
            return ProfileSettings(
                minTier: .t4K,
                preferredFps: 24,
                preferHDR: true,
                focusMode: .rackFocus,
                scanPattern: .dolly
            )
        }
    }
}

/// Profile settings configuration
public struct ProfileSettings: Codable, Equatable {
    public let minTier: ResolutionTier
    public let preferredFps: Int
    public let preferHDR: Bool
    public let focusMode: FocusMode
    public let scanPattern: ScanPattern

    public init(minTier: ResolutionTier, preferredFps: Int, preferHDR: Bool, focusMode: FocusMode, scanPattern: ScanPattern) {
        self.minTier = minTier
        self.preferredFps = preferredFps
        self.preferHDR = preferHDR
        self.focusMode = focusMode
        self.scanPattern = scanPattern
    }
}

/// Focus mode for capture
public enum FocusMode: String, Codable, CaseIterable, Equatable {
    case continuousAuto
    case macro
    case macroLocked
    case rackFocus
    case infinity
}

/// Scan pattern for 3D reconstruction
public enum ScanPattern: String, Codable, CaseIterable, Equatable {
    case orbital      // Circle around object
    case closeUp      // Detailed surface scan
    case walkthrough  // Move through space
    case turntable    // Object on turntable
    case dolly        // Cinematic camera movement
}
```

### Step 3: 验证修复

```bash
# 本地构建验证
swift build

# 检查文件头部（必须不包含分支名）
head -5 Core/Constants/CaptureProfile.swift
# 期望输出:
# //
# //  CaptureProfile.swift
# //  Aether3D
# //
# //  PR#4 Capture Recording Enhancement

# 推送后等待 CI
git push origin pr/4-capture-recording
```

---

## 检查其他文件

虽然 CI 只报告了 `CaptureProfile.swift` 的错误，但最好检查所有新文件：

```bash
# 检查所有 PR4 新文件的头部
head -5 Core/Constants/CaptureQualityPreset.swift

# 验证不包含分支名
grep -l "pr/4-capture-recording" Core/Constants/*.swift
# 期望: 无输出（没有文件包含分支名）
```

---

## 根因调查（可选）

如果问题反复出现，检查：

```bash
# 检查 git hooks
ls -la .git/hooks/

# 检查 git attributes
cat .gitattributes

# 检查是否有 smudge/clean filter
git config --list | grep filter
```

---

## 预期结果

修复后，CI 应该：
1. ✅ Preflight (Phase 0.5 guardrails) - PASS
2. ✅ Test & Lint - PASS
3. ✅ PIZ Tests (macOS-15) - PASS
4. ✅ PIZ Tests (ubuntu-22.04) - PASS
5. ✅ PIZ Cross-Platform Comparison - PASS
6. ✅ PIZ Sealing Evidence Generation - PASS
7. ✅ PIZ Final Gate - PASS
8. ✅ CI Gate - PASS

---

**END OF FIX PROMPT**
