# Aether3D — 项目当前状态与 iOS 26 渲染卡死问题（给教授的简报）

> 撰写时间：2026-04-28
> 当前设备：iPhone 14 Pro，iOS 26.3.1
> 宿主机：macOS 26.1（Build 25B78），Xcode 26.2（Build 17C52）

---

## 1. 项目是什么

Aether3D 是一个**跨平台（iOS / Android / HarmonyOS / Web）的 3D 高斯泼溅（3DGS）扫描 + 社交 App**，输出标准 **GLB** 格式的三维资产。用户流程：

1. 手机拍一段物体环绕视频（或单帧拍照）；
2. 本地做**质量审核 + 拍摄引导**（模糊 / 亮度 / 运动能量 / 方位覆盖）；
3. 视频后台上传给云端后端（我们自研的 broker + 训练 worker）；
4. 云端跑 3DGS 训练流水线（SLAM3R + 2DGS / MILo / VGGT 对比路径）；
5. App 下载训练出的 GLB，在手机上以近 PBR 画质渲染，并支持社交分享。

前身是一个 iOS-only 的 TestFlight App（仓库位于 `~/Documents/progecttwo/progect2/`，Swift + Metal 原型，已在真机跑通核心流程）。这次的工作是**把前身的 UI 和算法迁移到跨平台架构**，以 Flutter + 自研 C++/Dawn 渲染核为骨架。

---

## 2. 技术栈与架构

```
Aether3D-cross/                       ← 跨平台主仓
├── pocketworld_flutter/              ← Flutter 前端（Dart）
│   ├── lib/                          ← Dart 源码
│   │   ├── main.dart                 ← 入口 + Firebase + AuthGate
│   │   ├── auth/                     ← Firebase Auth 抽象（协议 + Firebase 实现 + Mock）
│   │   ├── pipeline/                 ← 后端通信（broker client / artifact manifest）
│   │   ├── quality/                  ← 拍摄引导 + 质量指标 + 训练收敛度
│   │   ├── dome/                     ← AR 球形拍摄 UI + 方位覆盖图
│   │   ├── ui/                       ← 设计系统 + 页面（Vault / Me / Capture 等）
│   │   ├── aether_ffi.dart           ← 走 dart:ffi 进 C++ 渲染核
│   │   └── aether_prefs.dart         ← 自写 NSUserDefaults 桥（替代 shared_preferences）
│   ├── ios/Runner/                   ← iOS 原生壳
│   │   ├── AppDelegate.swift
│   │   ├── Info.plist
│   │   ├── AetherPrefsPlugin.swift   ← NSUserDefaults MethodChannel
│   │   ├── AetherTexturePlugin.swift ← 外部纹理桥（Flutter ↔ Metal IOSurface）
│   │   └── MetalRenderer.swift
│   └── pubspec.yaml
│
└── aether_cpp/                       ← 跨平台渲染 & 训练核
    ├── src/                          ← C++ 渲染核（Dawn + Metal / Vulkan 后端）
    ├── shaders/wgsl/                 ← WGSL 着色器（PBR / 3DGS / 质量指标）
    └── aether3d_ffi.podspec          ← 以 CocoaPods 暴露给 iOS

progecttwo/                           ← 旧 iOS 单平台原型（参考实现来源）
├── progect2/progect2/                ← Swift + Metal App 原型
│   ├── App/ObjectModeV2/             ← 拍摄模式 2 的完整实现（UI + 引导算法）
│   ├── App/GaussianSplatting/        ← 3DGS 训练 Metal 核
│   ├── App/Shaders/                  ← Metal 着色器源（QualityMetrics / QualityOverlay）
│   ├── Core/Auth/                    ← Firebase Auth 层
│   └── Core/Pipeline/                ← 后端通信（RemoteB1Client 协议 + broker / SSH 实现）
└── control_plane/worker_object_slam3r_surface_v1/
                                      ← 云端训练 worker（Python；SLAM3R → 2DGS/MILo）
```

- **前端框架**：Flutter（目前 master 3.44.0-1.0.pre-294，Engine 06de99b49bfe），Dart 3.13.0
- **渲染核**：自研 C++ + Dawn + WGSL，iOS 上走 Metal，macOS 上走 Metal，Android/Web 上走 Vulkan/WebGPU。通过 `dart:ffi` 以及 `AetherTexturePlugin`（外部纹理 + IOSurface 共享）接入 Flutter。
- **登录**：Firebase Auth（邮箱 / 手机 OTP 双路），Mock 实现作为 Preview / 测试 / 未配置 Firebase 时的 fallback。
- **后端**：自研 HTTP broker（`BackgroundUploadBrokerClient`），承担视频上传 + 任务调度 + 成品分发；备路 SSH/SFTP 直连（`DanishGoldenRemoteB1Client`）和纯本地 stub。
- **3DGS 训练**：云端 Python worker（SLAM3R pose + 2DGS/MILo 表面重建），输出带 SHA256 校验清单的 GLB 成品。

---

## 3. 当前进度（Phase 6.x）

| 阶段 | 状态 | 说明 |
|---|---|---|
| 6.4a | 已完成 | WGSL 着色器烘焙 + IOSurface FFI；全矩阵 FFI 打通 |
| 6.4b | 已完成 | GLB 加载器 + Filament 风格 PBR 着色；场景级 IOSurface 渲染器（mesh PBR + splat 叠加） |
| 6.4c | 已完成 | 相机 + 物体变换手势；四元数弧球（原先 polar/azimuth 在 180° 锁死，已重写） |
| 6.4d.1 | 已完成 | 广色域 + RGBA16F IOSurface |
| 6.4d.2 | 已完成 | DRS 动态分辨率 + MetalFX 上采样 + 设备分级 |
| 6.4e | 已完成 | 生命周期观察器 + 内存压力处理 + 状态持久化（v1→v2，四元数存储） |
| 6.4x | 已完成 | `aether_cpp` / `pocketworld` 共享渲染策略边界重构 |
| **Phase A** | **进行中** | **UI 重做：黑白极简风格，两个底 Tab（仓库 / 我的），FAB 进入拍摄；抽干 Swift 原型的 UI + 算法到 Flutter/WGSL** |

Phase A 已经落地的代码：

- **设计系统**（`lib/ui/design_system.dart`）：黑白极简色板 + spacing / radii / text styles / gradients tokens；附带 `DesignInspector` 开发覆盖层。
- **主界面**（`lib/ui/app_shell.dart`, `vault_page.dart`, `me_page.dart`）：两 Tab + 瀑布流作品集 + 个人页；仿 TestFlight 原型结构。
- **拍摄模式选择**（`capture_mode_selection_page.dart`）：远程 / 新远程 / 本地三选一。
- **拍摄页**（`capture_page.dart`）：DomeView + QualityDebugOverlay + 引导提示 + 录制控件 + 相机预览占位。
- **Auth 层**（`lib/auth/` 共 8 个文件）：完整移植 Swift `Core/Auth`，包含 `AuthService` 协议、Firebase 实现、Mock 实现、`CurrentUser` 状态机、`AuthScope` InheritedWidget、Firebase 初始化 helper 和显式 `FirebaseOptions`。
- **Pipeline 层**（`lib/pipeline/`）：broker 配置从 `dart-define` 读取、`ArtifactManifest` SHA256 校验、JobStatus / RemoteB1Client 协议。
- **Quality / Guidance**（`lib/quality/`）：`ObjectModeV2GuidanceEngine` 的 Dart 移植（硬拒 blur/dark/bright/occupancy + 软降级 redundant/low_texture/weak_quality 计数），`QualityDebugOverlay` Widget（omega/variance 色彩反馈），`LocalPreviewProductProfile` 阶段异常检测。
- **Dome / AR**（`lib/dome/`）：AR pose 抽象接口 + 平台插件 skeleton（MethodChannel）+ Mock pose provider + `CoverageMap` + `DomeView`（CustomPainter 2D 近似球面 wedge）。
- **WGSL 着色器**（`aether_cpp/shaders/wgsl/`）：`quality_metrics_blur.wgsl` / `quality_metrics_brightness.wgsl` / `quality_metrics_motion.wgsl`，从 Metal 原版移植。

---

## 4. 卡住的问题：**iOS 26.3.1 上 Flutter 首帧无法 rasterize**

### 4.1 现象（最关键的一条）

从桌面图标点开 App → **白屏闪 1 秒 → 黑屏永远不动**。从 Xcode 点 Run（debug / release 都试过）→ **同样**白 → 允许本地网络 → 黑，永远不亮。

控制台日志看到的最后几行：

```
Dart execution mode: JIT
flutter: The Dart VM service is listening on http://127.0.0.1:51396/...
11.15.0 - [FirebaseCore][I-COR000005] No app has been configured yet.
[AetherTexture] thermal=nominal targetFps=60 source=init
flutter: [AET-SMOKE] Dart main entered
flutter: [AET-SMOKE] inside runZonedGuarded
flutter: [AET-SMOKE] ensureInitialized done, about to runApp
flutter: [AET-SMOKE] runApp returned
flutter: [AET-SMOKE] first frame PAINTED
```

注意：**只看到 `first frame PAINTED`，永远不打 `first frame RASTERIZED`**。
早先还能看到：
```
fopen failed for data file: errno = 2 (No such file or directory)
Errors found! Invalidating cache...
```
这是 Impeller shader library 加载失败的典型特征。

### 4.2 诊断结论（通过 SMOKE log 逐层排除）

| 层 | 是否正常 | 证据 |
|---|---|---|
| iOS `UIApplicationMain` | 正常 | LLDB attach 成功，`AppDelegate.didFinishLaunching` 执行完成 |
| Flutter Engine 起身 | 正常 | `Dart VM service is listening` 打出来 |
| Dart `main()` | 正常 | `Dart main entered` 打出来 |
| `WidgetsFlutterBinding.ensureInitialized()` | 正常 | `ensureInitialized done` 打出来 |
| `runApp()` 执行 | 正常 | `runApp returned` 打出来 |
| Widget tree 构建 + layout + **paint** | 正常 | `first frame PAINTED` 打出来（这个 hook 是 `WidgetsBinding.instance.addPostFrameCallback`） |
| **GPU 线程 rasterize**（Metal/Skia drawable commit） | **失败** | `waitUntilFirstFrameRasterized` 回调**永远不触发**，屏幕黑 |
| 没有 crash / abort | — | 进程一直活着，UI 线程还在打别的日志 |

**结论：UI 线程活、GPU 线程 hang**。Flutter engine 把 widget tree 栅格化到 Metal drawable 这一步挂住了，既没 crash 也没 fallback，就是一个静默的 GPU thread hang。

### 4.3 已排除的原因

我们用**不断缩小 App 范围 + 统一的 SMOKE log** 的方法已经排除了以下全部可能：

1. **不是 App 业务代码**。把所有页面移掉，只留一个**红屏 MaterialApp**（纯 `Container(color: Colors.red)`），仍然黑。
2. **不是 Firebase**。完全注释 `firebase_core` / `firebase_auth`（Pod 也不装），仍然黑。
3. **不是 `aether3d_ffi`**。把 `aether_cpp` FFI 初始化全删，仍然黑。
4. **不是我们的 `AetherTexturePlugin` / `AetherPrefsPlugin`**。都注释掉，仍然黑。
5. **不是 `shared_preferences`**。已经用自写的 `AetherPrefsPlugin` + `AetherPrefs` dart 完全替代。
6. **不是 `SceneDelegate` / Scene 生命周期**。删掉 `SceneDelegate.swift`，回到标准 `FlutterAppDelegate` 管理 engine 和 window，并在 `Info.plist` 中按 iOS 26 要求补齐 `UIApplicationSceneManifest`，无改善。
7. **不是 zone mismatch**。`WidgetsFlutterBinding.ensureInitialized()` 和 `runApp()` 在同一个 `runZonedGuarded` callback 内。
8. **不是 Impeller 开关未生效**。Flutter `flutter_tools/lib/src/ios/plist_parser.dart` 里确认 key 名就是 `FLTEnableImpeller`。在 `Info.plist` 设 `FLTEnableImpeller = false`，走 Skia fallback，仍然黑。
9. **不是 Flutter stable 版本 bug**。升到 **master `3.44.0-1.0.pre-294`（2026-04-27 的 commit `61fca76dd5`）**，并重新 `flutter clean` + `pod install`，仍然黑。
10. **不是签名 / 安装方式**。从 Xcode Run、`flutter run --debug`、`flutter install --release`、`devicectl install` 都试过，表现完全一致。设备还有一个反常信号：Springboard 上这个 App 旁边那个「新安装」的蓝点**一直不消失**，每次点开它都把自己当作全新安装的 App —— 说明 iOS 从来没有记录一次成功的 first launch 完成事件。

### 4.4 我们的判断

**高度怀疑是 Flutter Engine 的 Metal 渲染后端（Impeller 以及 Skia fallback）与 iOS 26.3.1 存在二进制层面的不兼容**。支持这个判断的线索：

- `fopen failed for data file: errno = 2` 指向 Impeller 在 iOS 26 沙箱下找不到 shader library bundle 路径（iOS 26 对 bundle 资源路径规则有调整）。
- Impeller hang 后切 Skia 同样不亮，说明问题不在 Impeller 本身，而在 Flutter 的 Metal drawable commit 路径（两个后端共用）。
- 社区里有零散的 iOS 26 beta 期间 Flutter 首帧 hang 的报告，但没有 3.41 stable 的官方修复记录。
- iPhone 14 Pro 真机 + iOS 26.3.1 这个组合在我们 2026-04 的测试窗口恰好是 iOS 26 的第一次点版本更新之后。

---

## 5. 我们试过的方案（都没解决）

| # | 尝试 | 结果 |
|---|---|---|
| 1 | `WidgetsFlutterBinding.ensureInitialized()` 顺序修复 | 解决了 zone 问题但没修好首帧 |
| 2 | `Podfile` 加 `use_modular_headers!` + `use_frameworks! :linkage => :static` | 解决了 `SharedPreferencesPlugin` 的 `swift_getObjectType` crash |
| 3 | 完全替换掉 `shared_preferences` → 自写 `AetherPrefsPlugin` | crash 彻底消失，但仍黑屏 |
| 4 | 重写 `AppDelegate.swift` 回归 Flutter 官方模板；删 `SceneDelegate.swift` | `FlutterViewController` 初始化不再崩 |
| 5 | `Info.plist` 加 `NSLocalNetworkUsageDescription`、`UIApplicationSceneManifest` | 允许本地网络对话框正确出现，但允许后仍黑 |
| 6 | Dart 侧把 Firebase 初始化放到**非阻塞**后台 + 10s 超时 fallback 到 Mock | Dart 主线程不再被阻，日志证实 `runApp` 立即返回，但仍黑 |
| 7 | Xcode `flutter clean` + 全量重 build + 重签名，解决 `objective_c.framework` codesign 校验错误 | build 通过，仍黑 |
| 8 | `Info.plist` 设 `FLTEnableImpeller = false`（走 Skia） | 仍黑 |
| 9 | 把所有业务代码剥光，只保留一个 `MaterialApp(home: Scaffold(backgroundColor: Colors.red))` | 仍黑 |
| 10 | Flutter 切到 master 3.44.0（engine `06de99b49bfe`） | 仍黑 |

---

## 6. 想请教教授的问题

1. **Flutter 3.41 / 3.44 与 iOS 26.3.1 是否存在已知的渲染后端兼容问题？** 我们查到的 Impeller / Skia 在 iOS 26 上的 issue 多数是 beta 时期的 shader library 路径问题，但 3.41 stable 和 master 都没修。教授或实验室有没有在其他 Flutter 项目上遇到过相同现象？
2. **有没有更彻底的绕路方案？** 我们考虑过但没执行的几条路：
   - (a) 把 Flutter engine 源码自己编一份，回退 Metal 后端到 Flutter 3.27（iOS 26 pre-GA 时期还能跑）；
   - (b) 用 `view factories` 直接把原生 `CAMetalLayer` 塞进 Flutter widget tree，让 Flutter UI thread 只负责布局，所有像素都由我们自己的 Metal renderer 画（代价是 Flutter Material 控件的像素也得我们自己合成）；
   - (c) 短期放弃 Flutter iOS，先在 Android / macOS 上做完所有 UI，把 iOS 推到 Flutter 官方修好 iOS 26 之后再回来。
3. **iOS 26 对 App bundle 资源路径 / sandbox fopen 的具体规则变动**是什么？`fopen failed for data file: errno = 2` 是否有公开的 release note 说明？
4. **有没有更便于诊断的工具**可以看 Flutter engine 的 GPU 线程栈（不是 Dart 栈）？我们已经有 Xcode 的 LLDB，但 GPU thread hang 的时候 LLDB 只能看到 mach 级别的线程等锁，看不到 Flutter engine C++ 层 rasterizer 里挂在哪一行。

---

## 7. 本地文件位置速查

| 作用 | 路径 |
|---|---|
| 跨平台主仓 | `~/Documents/Aether3D-cross/` |
| Flutter 前端 | `~/Documents/Aether3D-cross/pocketworld_flutter/` |
| Flutter 入口（含 SMOKE log） | `~/Documents/Aether3D-cross/pocketworld_flutter/lib/main.dart` |
| iOS 原生壳 | `~/Documents/Aether3D-cross/pocketworld_flutter/ios/Runner/` |
| 自研 C++ 渲染核 | `~/Documents/Aether3D-cross/aether_cpp/` |
| WGSL 着色器 | `~/Documents/Aether3D-cross/aether_cpp/shaders/wgsl/` |
| 旧 iOS 原型（UI / 算法参考） | `~/Documents/progecttwo/progect2/progect2/` |
| 云端训练 worker | `~/Documents/progecttwo/control_plane/worker_object_slam3r_surface_v1/` |
| Phase 计划文档 | `~/Documents/Aether3D-cross/aether_cpp/PHASE6_PLAN.md` 等 |
| 迁移 backlog（Swift → Dart/WGSL 清单） | `~/Documents/Aether3D-cross/pocketworld_flutter/PORTING_BACKLOG.md` |
| 本文（给教授的简报） | `~/Documents/Aether3D-cross/pocketworld_flutter/HANDOFF_TO_ADVISOR.md` |

---

## 8. 环境快照（便于教授复现）

- **macOS**：26.1（25B78）
- **Xcode**：26.2（17C52）
- **Flutter**：3.44.0-1.0.pre-294（channel master，revision `61fca76dd5`）
- **Dart**：3.13.0-70.0.dev
- **iOS 设备**：iPhone 14 Pro（iPhone15,2），**iOS 26.3.1**
- **Firebase**：firebase_core 3.15.2，firebase_auth 5.7.0
- **CocoaPods**：1.16.2
- **C++ 渲染核**：Dawn + 自研 Filament 风格 PBR + 3DGS splat overlay，通过 IOSurface 共享到 Flutter 外部纹理

---

## 9. 一句话总结给教授

> 我们的跨平台 App 的 Dart / Flutter widget 层和 iOS 原生层都已经打通并且首帧已经 paint 成功，**但 Flutter engine 的 GPU 线程在 iOS 26.3.1 上始终无法完成第一次 Metal drawable commit，屏幕恒为黑色**；已经排除了所有业务代码、Firebase、FFI、shared_preferences、SceneDelegate、Impeller 开关、Flutter 版本（stable 3.41 与 master 3.44 均复现）等可能，判断是 Flutter 渲染后端与 iOS 26.3.1 的底层不兼容。请问教授有什么排查方向或备选方案？
