# Firebase Auth 迁移 — TestFlight 版 Handoff

**状态**：`xcodebuild iphonesimulator Debug` **BUILD SUCCEEDED** ✅
**分支**：`feat/firebase-auth`（基于 `codex/scan-stability-fix`）
**未提交**：所有改动在工作区，没有 commit（等你 review）

---

## 改了哪些文件

### 新增

| 路径 | 作用 |
|---|---|
| `Core/Auth/AuthModels.swift` | `InternalUserID`, `AuthenticatedUser` 值类型 |
| `Core/Auth/AuthError.swift` | provider-agnostic 错误类型 |
| `Core/Auth/AuthService.swift` | Auth 协议（UI 不直接碰 Firebase） |
| `Core/Auth/FirebaseAuthService.swift` | Firebase SDK 实现（`#if canImport(FirebaseAuth)`） |
| `Core/Auth/MockAuthService.swift` | 无 Firebase 时的回退（previews / 未链接 SDK 场景） |
| `Core/Auth/CurrentUser.swift` | `@MainActor ObservableObject`，SwiftUI 接口 |
| `App/Auth/AuthRootView.swift` | 登录页根 View（登录/注册 × 邮箱/手机号） |
| `App/Auth/AuthSharedViews.swift` | `AuthField`, `AuthPrimaryButtonLabel` |
| `App/Auth/EmailSignInView.swift` | 邮箱登录 + 注册 |
| `App/Auth/PhoneSignInView.swift` | 手机号 + OTP 两步流程 |
| `GoogleService-Info.plist` | **已 gitignored**，bundle ID `com.kyle.Aether3D` |
| `scripts/add_auth_files_to_xcodeproj.rb` | 一次性脚本，已跑过；保留方便以后新加 Auth 文件 |

### 修改

| 文件 | 改动 |
|---|---|
| `Package.swift` | 加了 `firebase-ios-sdk` 依赖；`Aether3DCore` target 链 `FirebaseAuth` 产品 |
| `App/Aether3DApp.swift` | 加 `AuthGateView`：bootstrapping → `AuthRootView` → `HomePage` 三态切换；`AppAuthFactory` 决定用 Firebase 还是 Mock |
| `App/Home/ScanRecordStore.swift` | `init(userID: String? = nil)` — 非空时路径改成 `Documents/Aether3D/users/<uid>/`，彻底隔离不同账号 |
| `App/Home/HomeViewModel.swift` | 新增 `bindToUser(_:)`，切换到 user-scoped store |
| `App/Home/HomePage.swift` | 注入 `@EnvironmentObject currentUser`；`.onAppear` 触发 `bindToUser`；header 右上角加小头像 → Menu（显示用户名 + 退出登录）；`.confirmationDialog` 确认退出 |
| `Aether3DApp.xcodeproj/project.pbxproj` | 通过 ruby 脚本加了 4 个 Auth Swift 源 + plist 资源到 app target |

### 没动

- 所有 `Core/Pipeline/`、`Core/NativeRender/`、`aether_cpp/` — 算法 / 后端代码 0 行改动
- `App/Capture/`、`App/Scan/`、`App/ObjectModeV2/` 等业务 view — 0 行改动
- `AetherAppShell`（line 437 of HomePage.swift）— 没改，沿用原来的 tab 切换
- Bundle ID、TeamID、证书、App Store Connect 配置 — 没动

---

## 架构铁律（保持迁移能力）

1. **UI 代码永远只碰 `AuthenticatedUser.id`**（类型是 `InternalUserID`）。不要在任何 view 里写 `.uid` 或 `Auth.auth().currentUser?.uid`。
2. **`FirebaseAuthService.swift` 是唯一知道 Firebase 存在的 Swift 文件**。如果将来换 Auth0/Clerk/自研后端，只改这一个文件 + `AppAuthFactory`。业务 view、HomeViewModel、ScanRecordStore、HomePage 全部不用动。
3. **`MockAuthService` 在生产不可用**。`AppAuthFactory` 只在 `canImport(FirebaseAuth)` 失败时回退到它（比如误删了 Firebase SPM）。

---

## 怎么测

### 在模拟器上测（最快）

1. Xcode 打开 `/Users/kaidongwang/Documents/Aether3D/Aether3DApp.xcodeproj`
2. Scheme: Aether3DApp，simulator 选 iPhone 15 或 16
3. ⌘R 运行
4. 看到登录页 → 手机号 → 填 `+1 216-225-4438` / `123456` → 登录
5. 进 HomePage，右上角小头像点开 → "退出登录" → 回登录页

### 验证账号隔离

1. 用邮箱 A 登录 → 拍几个 scan → 退出
2. 用邮箱 B 登录 → 应该**看不到** A 的 scan
3. 退出重新登录 A → A 的 scan 还在
4. 本地文件系统应该是：
   ```
   Documents/Aether3D/users/<firebase-uid-A>/scans.json
   Documents/Aether3D/users/<firebase-uid-B>/scans.json
   ```

### 老版本数据咋办？

Pre-auth 用户（现在 TestFlight 上的真实用户）的 scan 数据在 `Documents/Aether3D/scans.json`（没有 `users/<uid>/` 前缀）。登录后他们**看不到这些旧 scan**。

如果你要保留老数据，需要写个迁移：第一次登录后，如果 `Documents/Aether3D/scans.json` 存在且 `users/<uid>/` 为空，把它 move 进去。我**没做这个迁移**——你确认要做再说，因为要考虑 "用户想重装 app 换账号" 等场景的取舍。

---

## 已知待办（非阻塞）

1. **APNs 配置**：手机号真实 SMS 验证需要 Firebase Console → Project Settings → Cloud Messaging → APNs Authentication Key。现在测试号码不依赖这个，**但正式发布前必须配**，不然真用户注册不了。
2. **Apple Sign In**：审核 App Store 时如果有第三方登录，Apple 要求同时提供 Apple Sign In。我们现在只有邮箱 + 手机号（都是"自建"），**按 App Store 审核规则不需要 Apple Sign In**。如果你以后加 Google/WeChat 登录，需要同时加 Apple Sign In。
3. **旧数据迁移**（上面说过）
4. **空 scan 列表 UI**：新用户首次登录看到的是空 gallery，原来那个 "尚无扫描作品" empty state 是沿用的，不用改。
5. **UI 改动 review**：HomePage header 右上角我加了个小 person icon（Menu）。title 还是居中的（用 Color.clear 32×32 占位平衡）。你不喜欢可以挪位置或换图标。

---

## 恢复你之前的 WIP

```bash
cd /Users/kaidongwang/Documents/Aether3D
git checkout codex/scan-stability-fix
git stash pop    # 把你的 ObjectModeV2CaptureView 改动 pop 回来
```

Merge 到主线时建议：
```bash
git checkout feat/firebase-auth
git rebase codex/scan-stability-fix  # 或 main，看你 release 流程
```

---

## 如果想关掉 Firebase 回退到 Mock

单行改 `Package.swift`：
```swift
// .package(url: "https://github.com/firebase/firebase-ios-sdk", from: "10.29.0"),
```
注释掉 Firebase 依赖，再删 `Aether3DCore` target 里的 `FirebaseAuth` 产品行。
Build 后 `#if canImport(FirebaseAuth)` 全部变 false，`AppAuthFactory` 自动回退到 `MockAuthService`。**业务代码 0 行改动。**

---

## 提交

**我没 commit 任何东西**（按你的一贯做法）。你 review 之后：

```bash
git add -A
git status      # 确认只有 auth 相关文件 + plist
# plist 已在 .gitignore（全局 pattern "**/GoogleService-Info.plist"）
git commit -m "feat(auth): add Firebase-backed email + phone sign-in"
```
