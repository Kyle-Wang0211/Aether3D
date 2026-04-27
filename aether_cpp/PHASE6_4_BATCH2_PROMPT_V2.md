# Aether3D PocketWorld — Phase 6.4 Batch 2 实施 Prompt(完整 cold-start handoff)

## 你是谁,任务是什么

你接手 **Aether3D PocketWorld** — 跨平台 3D Gaussian Splatting viewer 的 Phase 6.4 Batch 2 实施。前一会话(Claude Opus 4.7 1M context)已完成 Phase 6.4b stage 2(2-pass 场景渲染:mesh PBR + splat overlay)+ Phase 6.4 cleanup(删 legacy splat-only renderer)+ 1 个 gesture bugfix。当前画面状态:macOS PocketWorld 显示 DamagedHelmet 头盔,60fps 稳定,手势全工作。

你接下来做的事:**Phase 6.4d.1 + 6.4d.2 + 6.4e**(WCG → MetalFX → Lifecycle 持久化)。预计总 13-19h + 3 个用户 verification gate。

---

## 1. 仓库地理(关键!读完才动手)

### 工作仓库(所有改动都在这里)

```text
/Users/kaidongwang/Documents/Aether3D-cross/
├── aether_cpp/                    ← C++ 后端 + WGSL shader + 测试
│   ├── include/aether/...
│   ├── src/...
│   ├── shaders/wgsl/...
│   ├── tools/...                  ← smoke 二进制源码
│   ├── build/                     ← 编译产物(不进 git)
│   ├── PHASE6_PLAN.md             ← 进度日志(必读)
│   ├── PHASE_BACKLOG.md           ← 待办(Phase 6.4f / 6.4d.3 等)
│   └── CMakeLists.txt
└── pocketworld_flutter/
    ├── lib/                       ← Dart UI
    ├── macos/Runner/              ← macOS plugin (Swift)
    ├── ios/Runner/                ← iOS plugin (Swift)
    └── pubspec.yaml
```

**严禁** 在 `~/Documents/progecttwo/.claude/worktrees/...` 任何 worktree 改文件 — 那是 Claude Code 的 sandbox,实际代码不在那里。

### Git 分支

```text
当前分支:feat/flutter-dawn-base
Ahead of origin: 3 commits
```

最近 commits(从新到旧):
```text
71d0296e  bugfix(pocketworld): orbit target follow object position after pan
8de3e2fb  refactor(aether_cpp,pocketworld): Phase 6.4 cleanup — drop legacy splat renderer
d45ec7af  feat(aether_cpp,pocketworld): Phase 6.4b stage 2 — scene IOSurface renderer
09a3afd5  chore(pocketworld): Phase 6.4c verify aid — NSLog matrix translation cols
2ab5f798  feat(aether_cpp): Phase 6.4b stage 1 — GLB loader + Filament PBR shader
0f0f5625  feat(pocketworld): Phase 6.4c — Camera + object transform gestures
1733d0cd  feat(pocketworld): Phase 6.4a steps 3c+5+6 — Swift glue swap + 6.4a' full-matrix FFI
```

---

## 2. 架构总览

```text
┌─────────────────────────────────────────────────────┐
│ Flutter UI (Dart)                                    │
│   main.dart            — Texture widget + 手势 dispatch│
│   orbit_controls.dart  — 相机 OrbitControls (Three.js port)│
│   object_transform.dart — 物体世界变换 (pan + rotate Y)│
│   aether_ffi.dart      — FFI version string (dart:ffi)│
└─────────────────────────────────────────────────────┘
           ↓ MethodChannel("aether_texture")
┌─────────────────────────────────────────────────────┐
│ Native Plugin (Swift)                                │
│   macOS: MainFlutterWindow.swift                     │
│   iOS:   AetherTexturePlugin.swift + MetalRenderer  │
│   - 创建 IOSurface (共享 GPU↔Flutter 内存)          │
│   - dlopen libaether3d_ffi.dylib + dlsym 4 个 C ABI │
│   - displayLink @ 60fps → render_full(view, model)  │
└─────────────────────────────────────────────────────┘
           ↓ C ABI (extern "C")
┌─────────────────────────────────────────────────────┐
│ aether3d_ffi.dylib(libaether3d_ffi.dylib)           │
│   aether_scene_renderer_create(IOSurface, w, h)     │
│   aether_scene_renderer_load_glb(path) → bool       │
│   aether_scene_renderer_render_full(view, model)    │
│   aether_scene_renderer_destroy                      │
└─────────────────────────────────────────────────────┘
           ↓ 内部
┌─────────────────────────────────────────────────────┐
│ scene_iosurface_renderer.cpp(2-pass IOSurface 渲染)│
│   pass 1: mesh_render.wgsl(Filament BRDF)           │
│             写 color + depth                          │
│   pass 2: splat_render.wgsl(splat overlay)          │
│             load color + depth, no depth write       │
│             premultiplied alpha blend                │
└─────────────────────────────────────────────────────┘
           ↓ 通过 GPUDevice 抽象
┌─────────────────────────────────────────────────────┐
│ DawnGPUDevice(对内 dawn_gpu_device.cpp)             │
│   - 内置 Tint + naga_oil → WGSL → MSL/Metal        │
│   - IOSurface 导入 (WGPUFeatureName_SharedTextureMemoryIOSurface)│
│   - 内部 narrow accessor (dawn_gpu_device_internal.h) │
│     给同库 TU 直接拿 WGPU handle (scene 渲染器用)    │
└─────────────────────────────────────────────────────┘
           ↓ 输出
┌─────────────────────────────────────────────────────┐
│ IOSurface(BGRA8 256×256,Phase 6.4d.1 升 RGBA16F)  │
│   ↑ Flutter compositor 直接读(零 copy)              │
└─────────────────────────────────────────────────────┘
```

---

## 3. 文件清单(改动 / 阅读时定位)

### 3.1 C++ 后端(`aether_cpp/`)

#### 公共 header
| 路径 | 作用 |
|---|---|
| `include/aether/pocketworld/scene_iosurface_renderer.h` | C ABI(create/destroy/load_glb/render_full) |
| `include/aether/pocketworld/glb_loader.h` | cgltf + stb_image GLB 加载器 |
| `include/aether/render/gpu_device.h` | 跨后端 GPUDevice 虚抽象 |
| `include/aether/render/gpu_resource.h` | **GPUTextureFormat 枚举(6.4d.1 改这里加 RGBA16F)** |
| `include/aether/render/dawn_gpu_device.h` | DawnGPUDevice 工厂入口 |
| `include/aether/render/runtime_backend.h` | kDawn 枚举 |

#### 内部源
| 路径 | 作用 |
|---|---|
| `src/pocketworld/scene_iosurface_renderer.cpp` | **核心 ~1000 LOC**:2-pass mesh + splat 渲染 |
| `src/pocketworld/dawn_device_singleton.{h,cpp}` | refcounted Dawn device 单例 |
| `src/pocketworld/glb_loader.cpp` | GLB 解析 + 纹理上传 |
| `src/render/dawn_gpu_device.cpp` | DawnGPUDevice 实现(~3000 LOC,**6.4d.1 改 to_wgpu_format / dawn_import_iosurface_texture**) |
| `src/render/dawn_gpu_device_internal.h` | 私有 header(同库 TU 拿 WGPU handle) |
| `src/render/metal_gpu_device.cpp` | Metal 后端(**6.4d.1 必须同步加 to_mtl_format case**) |
| `src/render/dawn_iosurface.cpp` | IOSurface 导入实现 |

#### WGSL shaders(6.4d.1 不动)
| 路径 |
|---|
| `shaders/wgsl/mesh_render.wgsl` — Filament PBR(Cook-Torrance + GGX) |
| `shaders/wgsl/splat_render.wgsl` — Gaussian splat 渲染(vert+frag instanced quads) |
| `shaders/wgsl/baked/wgsl_sources.cpp(.h)` — CMake 生成,baked 进 binary |

#### Build / 文档
| 路径 |
|---|
| `CMakeLists.txt` — 主构建 |
| `PHASE6_PLAN.md` — 进度日志(必读 "Active execution log" 章节) |
| `PHASE_BACKLOG.md` — Phase 6.4f / 6.4d.3 / 其他 |
| `build/libaether3d_ffi.dylib` — 编译产物(macOS) |
| `build/test_assets/DamagedHelmet.glb` — 测试资源(KhronosGroup glTF-Sample-Models) |

#### Smokes(已 24/24 PASS,运行须从 repo 根目录)
- `tools/aether_dawn_*_smoke.cpp` — 16 个 WGSL kernel 烟测
- `tools/aether_dawn_gpu_device_smoke.cpp` — production-path GPUDevice
- `tools/aether_dawn_baked_wgsl_smoke.cpp` — bake pipeline
- `tools/aether_glb_loader_smoke.cpp` — GLB 加载
- `tools/aether_mesh_render_compile_smoke.cpp` — PBR shader 编译
- `tools/aether_version_test.cpp` — version FFI

#### 已删除(Phase 6.4 cleanup `8de3e2fb`)
```text
~~include/aether/pocketworld/splat_iosurface_renderer.h~~
~~src/pocketworld/splat_iosurface_renderer.cpp~~
~~tools/aether_splat_iosurface_renderer_smoke.cpp~~
```

### 3.2 Flutter UI(`pocketworld_flutter/`)

| 路径 | 作用 |
|---|---|
| `lib/main.dart` | 主屏(Texture widget + GestureDetector + LifecycleObserver 接入点 6.4e) |
| `lib/orbit_controls.dart` | OrbitControls Dart 实现 |
| `lib/object_transform.dart` | 物体世界变换(pan + rotate Y) |
| `lib/aether_ffi.dart` | Dart `dart:ffi` 加载 dylib 取 version string |
| `pubspec.yaml` | Dart 依赖(**6.4e 起手要加 shared_preferences**) |
| `macos/Runner/MainFlutterWindow.swift` | macOS plugin(SharedNativeTexture + AetherTexturePlugin)— **6.4d.1/d.2/e 都改** |
| `macos/Runner/README_FFI.md` | macOS FFI 故障诊断 |
| `ios/Runner/MetalRenderer.swift` | iOS Phase 5 Metal 路径(Phase 6.4 没动) |
| `ios/Runner/AetherTexturePlugin.swift` | iOS plugin lifecycle hook 占位 |
| `ios/Runner/aether3d_ffi.podspec` | iOS dylib pod 元数据 |

### 3.3 用户级 memory(读这些拿用户偏好)

```text
/Users/kaidongwang/.claude/projects/-Users-kaidongwang-Documents-progecttwo/memory/
├── MEMORY.md                                  ← index
├── project_aether3d_scope.md                  ← app-only,质量 >> 灵活性
├── project_aether3d_paths.md                  ← 路径 / 构建配置
└── project_aether3d_arch_decision.md          ← Flutter UI + Dawn GPU + aether_cpp
```

---

## 4. 当前状态

### 4.1 已完成

| Phase | 描述 | Commit |
|---|---|---|
| 6.0–6.3 | Dawn iOS 解禁 + DawnGPUDevice + Brush WGSL 适配 | (pre-history) |
| 6.4a | IOSurface FFI 链路 + Swift glue 切换 | `1733d0cd` |
| 6.4b stage 1 | GLB loader + Filament PBR shader | `2ab5f798` |
| 6.4c | 相机 + 物体变换手势 + 全矩阵 FFI | `0f0f5625` |
| 6.4b stage 2 | scene IOSurface renderer(mesh + splat 双 pass) | `d45ec7af` |
| 6.4 cleanup | 删 legacy splat-only renderer + 注释 nit | `8de3e2fb` |
| post-cleanup bugfix | orbit target 跟 object position 同步 | `71d0296e` |

### 4.2 当前可视画面

- DamagedHelmet 渲染清晰,60fps 稳定
- 单指拖 → orbit 旋转头盔 ✅
- 双指捏 → 头盔缩放 ✅
- 双指同向拖 → 头盔平移(orbit target 自动跟随)✅
- 4 个 splat 钉在屏幕中心 (128, 128) — **不响应手势,Phase 6.4f scope,不要碰**
- IOSurface 格式:**BGRA8Unorm 256×256**(stage 2 默认,**6.4d.1 升 RGBA16F**)
- 24/24 smokes PASS,build 0 warnings

### 4.3 决策钉子(锁定,严禁回归)

钉子 1-22(继承 Phase 6.4 v3),关键几条:
- **2** App-only,不做"任意视频"兜底,质量 >> 灵活性
- **11** 不加用户引导 / tutorial / onboarding 动画
- **17** Apple 不允许后台 GPU 渲染 — 切后台 = pause displayLink + 持久化
- **18** 静默失败 = catastrophe(silent = catastrophe rule)

新增钉子 23-30(本次 Batch 2 新加,你必须遵守):
- **23** Framebuffer format 自适应(RGBA16F 旗舰 / BGRA8 兜底),不锁单一 format
- **24** DRS 自动化(60fps target,hysteresis,5-frame 最低样本)
- **25** MetalFX 上采样(macOS 13+ / iOS 16+,A14+ / M1+),simple blit 兜底
- **26** 设备 tier detection 在 Swift 侧,通过 method channel 传 C++/Dart
- **27** Lifecycle 通过 Dart `AppLifecycleState` 主导,native plugin 跟随
- **28** State 持久化用 SharedPreferences,key 带版本号(`v1`)
- **29** Memory pressure 触发 GPU 释放 + 持久化保留,resume 时 lazy reload
- **30** Background download / training checkpoint 接口现在 stub(Phase 7 实施)

---

## 5. 你接下来要做的事

### 5.1 高层执行顺序

```text
你现在
  ↓
[6.4d.1] WCG + RGBA16F IOSurface (~4-6h)
  ↓
[user verification gate](色彩饱和度对比 sRGB 提升 / 老设备 fallback OK)
  ↓
[6.4d.2] DRS + MetalFX + 设备 tier (~6-8h)
  - 第一动作:MetalFX 互操作 smoke(~30min,验证 Dawn↔Swift IOSurface fence)
  - smoke PASS 才做完整集成
  ↓
[user verification gate](DRS 突发负载 1s 内回稳;MetalFX 1080p→4K 上采样)
  ↓
[6.4e] Lifecycle + Persistence (~3-5h)
  - 起手:flutter pub add shared_preferences
  ↓
[user verification gate](切后台秒回;orbit/obj state 持久化)
  ↓
Phase 6.4f / Final iOS port(不在你范围,user 单开 phase)
```

**总:~13-19h + 3 个 verification gate**

### 5.2 Phase 6.4d.1 — Wide Color Gamut + RGBA16F IOSurface

#### 起手必读
```text
aether_cpp/include/aether/render/gpu_resource.h               (改这里加新 enum)
aether_cpp/src/render/dawn_gpu_device.cpp                     (改 to_wgpu_format + dawn_import_iosurface_texture)
aether_cpp/src/render/metal_gpu_device.cpp                    (必须同步加 to_mtl_format case,否则 -Werror=switch 编不过!)
aether_cpp/src/pocketworld/scene_iosurface_renderer.cpp       (改 rt_desc.color_format)
pocketworld_flutter/macos/Runner/MainFlutterWindow.swift      (改 SharedNativeTexture init 选 pixel format)
```

#### 实施步骤

**Step 1** — `gpu_resource.h` 加新枚举:
```cpp
enum class GPUTextureFormat : uint8_t {
    kInvalid = 0,
    kBGRA8Unorm,
    kRGBA8Unorm,
    kRGBA16Float,         // ← 新加
    kBGR10A2Unorm,        // ← 新加(可选,低优先级)
    kDepth32Float,
    kDepth32Float_Stencil8,
    // ...
};
```

**Step 2** — `dawn_gpu_device.cpp` 的 `to_wgpu_format` 加 case:
```cpp
case GPUTextureFormat::kRGBA16Float:   return WGPUTextureFormat_RGBA16Float;
case GPUTextureFormat::kBGR10A2Unorm:  return WGPUTextureFormat_BGR10A2Unorm;
```

**Step 3** — **关键**`metal_gpu_device.cpp` 同步加 `to_mtl_format` case(否则编不过):
```cpp
case GPUTextureFormat::kRGBA16Float:   return MTLPixelFormatRGBA16Float;
case GPUTextureFormat::kBGR10A2Unorm:  return MTLPixelFormatBGR10A2Unorm;
```

**Step 4** — `dawn_import_iosurface_texture` 改成接受 format 参数:
- 当前硬编码 BGRA8Unorm → 改成参数
- 验证 IOSurface descriptor format 与 Dawn texture format 匹配,不匹配 abort

**Step 5** — Swift 侧 `MainFlutterWindow.swift` 选 pixel format:
```swift
let pixelFormat: OSType
switch deviceTier {
case .flagship, .high: pixelFormat = kCVPixelFormatType_64RGBAHalf  // 8 bytes/pixel
case .mid:             pixelFormat = kCVPixelFormatType_32BGRA       // 兜底 sRGB
}

let surfaceProps: [CFString: Any] = [
    kIOSurfaceWidth: width,
    kIOSurfaceHeight: height,
    kIOSurfacePixelFormat: pixelFormat,
    kIOSurfaceBytesPerElement: pixelFormat == kCVPixelFormatType_64RGBAHalf ? 8 : 4,
]
```

**Step 6** — CAMetalLayer Display P3 + EDR(MainFlutterWindow.swift):
```swift
metalLayer.colorspace = CGColorSpace(name: CGColorSpace.displayP3)
if deviceTier.supportsEDR {
    metalLayer.wantsExtendedDynamicRangeContent = true
}
```

**Step 7** — macOS 设备 tier 检测(只 macOS,iOS 留给 Final iOS port):
```swift
import Foundation

func detectMacOSTier() -> String {
    var size = 0
    sysctlbyname("hw.model", nil, &size, nil, 0)
    var model = [CChar](repeating: 0, count: size)
    sysctlbyname("hw.model", &model, &size, nil, 0)
    let modelStr = String(cString: model)
    // 简单分类
    if modelStr.contains("Mac15") || modelStr.contains("Mac16") { return "flagship" }
    if modelStr.contains("Mac14") || modelStr.contains("MacBookPro18") { return "high" }
    return "mid"
}
```
**注意:** macOS 没有 UIDevice。iOS 路径(UIDevice.modelIdentifier)**6.4d.1 不做**,留给 Final iOS port。

**Step 8** — Pipeline cache 隔离:
`scene_iosurface_renderer.cpp` 创建 RenderPipeline 时 `rt_desc.color_format` 必须用 device tier 选定的 format。

**Step 9** — WGSL shaders 不动:
`splat_render.wgsl` / `mesh_render.wgsl` 都返回 `vec4f`(浮点),Tint 自动适配 framebuffer format。

**Step 10** — 写新 smoke `aether_cpp/tools/aether_dawn_iosurface_rgba16f_smoke.cpp`:
- 创建 RGBA16Float 格式 IOSurface
- DawnGPUDevice import → 渲染一帧 → readback → 验证浮点值(非全 0,非 NaN)
- 加进 `CMakeLists.txt`(参考已有 IOSurface 相关 smoke pattern)

#### 6.4d.1 DoD

- ☐ macOS 上 RGBA16F IOSurface 工作(头盔色彩饱和度对比 sRGB 截图明显提升)
- ☐ 不支持 RGBA16F 环境 fallback 到 BGRA8Unorm + 日志(silent 失败 = catastrophe)
- ☐ Display P3 colorspace 启用,EDR 旗舰开启
- ☐ `cmake --build` 0 warning 0 error(metal_gpu_device.cpp switch 完整)
- ☐ 新 smoke `aether_dawn_iosurface_rgba16f_smoke` PASS
- ☐ 现有 24 个 smoke 0 回归
- ☐ 单独 commit:`feat(aether_cpp,pocketworld): Phase 6.4d.1 — WCG + RGBA16F IOSurface`
- ☐ 等 user verification gate

### 5.3 Phase 6.4d.2 — DRS + MetalFX + 完整 tier detection

#### **第一动作(必做):MetalFX 互操作 smoke(~30 min)**

写一个最小 swift smoke(独立于 Dawn):
1. 启动最小 Metal context
2. 创建 IOSurface(640×360 RGBA16F)
3. Metal 直接渲染纯红到 IOSurface
4. MetalFX 上采样到第二个 IOSurface(1280×720)
5. 截图第二个 IOSurface,验证 = 红色

**目的:** 确认 Swift / Metal / MetalFX / IOSurface 链路本身工作,不掺 Dawn。

- smoke FAIL → 排查 Apple API 用法,fix 后 retry
- smoke PASS → 进 Part 1

放在 `pocketworld_flutter/macos/Runner/SmokeTests/MetalFXInteropSmoke.swift`(或类似位置),从 Xcode 跑或 Swift CLI 跑都行。

#### Part 1 — DRS Controller

新文件 `aether_cpp/include/aether/pocketworld/drs_controller.h`:

```cpp
namespace aether::pocketworld {

class DrsController {
public:
    void on_frame_done(float frame_ms);
    void render_size_for(uint32_t native_w, uint32_t native_h,
                         uint32_t* out_w, uint32_t* out_h) const;
    float current_scale() const { return current_scale_; }

private:
    static constexpr int kRollingWindow = 30;
    static constexpr float kTargetMs = 16.6f;       // 60fps
    static constexpr float kMinScale = 0.5f;
    static constexpr float kMaxScale = 1.0f;
    static constexpr float kDecayRate = 0.05f;      // 降快(每帧 -5%)
    static constexpr float kRecoveryRate = 0.02f;   // 升慢(每帧 +2%)
    static constexpr float kHysteresisHigh = 1.1f;  // 超出 110% 才降
    static constexpr float kHysteresisLow = 0.9f;   // 低于 90% 才升

    std::array<float, kRollingWindow> recent_;
    int idx_ = 0;
    int filled_ = 0;
    float current_scale_ = 1.0f;
};

inline void DrsController::on_frame_done(float frame_ms) {
    recent_[idx_] = frame_ms;
    idx_ = (idx_ + 1) % kRollingWindow;
    if (filled_ < kRollingWindow) ++filled_;
    if (filled_ < 5) return;  // 至少 5 帧再决策

    float sum = 0;
    for (int i = 0; i < filled_; ++i) sum += recent_[i];
    float avg = sum / filled_;

    if (avg > kTargetMs * kHysteresisHigh) {
        current_scale_ = std::max(kMinScale, current_scale_ - kDecayRate);
    } else if (avg < kTargetMs * kHysteresisLow && current_scale_ < kMaxScale) {
        current_scale_ = std::min(kMaxScale, current_scale_ + kRecoveryRate);
    }
}

inline void DrsController::render_size_for(uint32_t native_w, uint32_t native_h,
                                          uint32_t* out_w, uint32_t* out_h) const {
    *out_w = static_cast<uint32_t>(native_w * current_scale_);
    *out_h = static_cast<uint32_t>(native_h * current_scale_);
    // align to 8 for shader workgroup compatibility
    *out_w = (*out_w + 7) & ~7u;
    *out_h = (*out_h + 7) & ~7u;
}

}  // namespace aether::pocketworld
```

#### Part 2 — Intermediate IOSurface 集成

`scene_iosurface_renderer` 维护 2 个 IOSurface:
- `intermediate_iosurface`(render_w × render_h,DRS 调整,Dawn 渲染目标)
- `display_iosurface`(iosurface_w × iosurface_h,Flutter 读取)

每帧:
1. `DRS.render_size_for()` 决定 render_w/h
2. 若 size 变了 → 重建 intermediate_iosurface
3. Dawn 渲染到 intermediate
4. Swift 收 method channel `upsample(intermediate, display)` → MetalFX 上采样
5. Flutter compositor 读 display

**fence 同步关键:** Dawn 提交 + `wgpuQueueOnSubmittedWorkDone` 后,Swift 才能 encode MetalFX。否则 race condition → 撕裂。

#### Part 3 — MetalFX Swift wrapper

新文件 `pocketworld_flutter/macos/Runner/MetalFXUpsampler.swift`:

```swift
import MetalFX

@available(macOS 13.0, iOS 16.0, *)
class MetalFXUpsampler {
    private let device: MTLDevice
    private var scaler: MTLFXSpatialScaler?
    private var lastInputSize: (Int, Int) = (0, 0)
    private var lastOutputSize: (Int, Int) = (0, 0)

    init(device: MTLDevice) { self.device = device }

    func encode(commandBuffer: MTLCommandBuffer,
                input: MTLTexture, output: MTLTexture) {
        let inSize = (input.width, input.height)
        let outSize = (output.width, output.height)
        if scaler == nil || inSize != lastInputSize || outSize != lastOutputSize {
            let desc = MTLFXSpatialScalerDescriptor()
            desc.inputWidth = input.width
            desc.inputHeight = input.height
            desc.outputWidth = output.width
            desc.outputHeight = output.height
            desc.colorTextureFormat = .rgba16Float
            desc.outputTextureFormat = .rgba16Float
            desc.colorProcessingMode = .perceptual
            scaler = desc.makeSpatialScaler(device: device)
            lastInputSize = inSize
            lastOutputSize = outSize
            if scaler == nil {
                NSLog("[MetalFXUpsampler] makeSpatialScaler returned nil")
                return
            }
        }
        guard let scaler = scaler else { return }
        scaler.colorTexture = input
        scaler.outputTexture = output
        scaler.encode(commandBuffer: commandBuffer)
    }
}
```

兜底:`@available(macOS 13.0, *)` guard,旧系统用 simple bilinear blit(WGSL vert+frag 全屏 quad)。

#### Part 4 — DeviceCapabilities struct

`aether_cpp/include/aether/pocketworld/device_capabilities.h`:

```cpp
namespace aether::pocketworld {

enum class DeviceTier : uint8_t {
    kFlagship,      // M3+
    kHigh,          // M1-M2
    kMid,           // older Apple Silicon / Intel
    kAndroidHigh,   // Phase 8
    kAndroidLow,    // Phase 8
    kWeb,           // Phase 8
    kUnknown,
};

struct DeviceCapabilities {
    DeviceTier tier;
    uint32_t native_display_w;
    uint32_t native_display_h;
    uint32_t base_render_w;
    uint32_t base_render_h;
    bool wcg_supported;
    bool edr_supported;
    bool metalfx_supported;
    int target_fps;
};

DeviceCapabilities detect_capabilities();
}
```

Swift 侧 `detectMacOSTier()`(6.4d.1 已写)扩展返回完整 capability dict,通过 method channel `getDeviceCapabilities` 传给 Dart + C++。

#### 6.4d.2 DoD

- ☐ MetalFX 互操作 smoke PASS
- ☐ DRS 突发负载(快速转视角)1s 内调到稳定 60fps,无明显画质跳变
- ☐ MetalFX 1080p → 4K 上采样工作,关闭对照 quality 一致或更好
- ☐ macOS 设备 tier detection 工作(Console 看 "tier: flagship/high/mid")
- ☐ 老设备 fallback(disable MetalFX,DRS 0.75x)工作
- ☐ 现有 25 smoke 0 回归
- ☐ 单独 commit:`feat(aether_cpp,pocketworld): Phase 6.4d.2 — DRS + MetalFX + tier detection`

### 5.4 Phase 6.4e — Lifecycle / 状态持久化 / 秒恢复

#### **起手第一步**

```bash
cd /Users/kaidongwang/Documents/Aether3D-cross/pocketworld_flutter
flutter pub add shared_preferences
```

#### Part 1 — Dart Lifecycle Observer

新文件 `pocketworld_flutter/lib/lifecycle_observer.dart`:

```dart
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'dart:convert';

import 'orbit_controls.dart';
import 'object_transform.dart';

class LifecycleObserver with WidgetsBindingObserver {
  static const _channel = MethodChannel('aether_texture');
  static const _orbitKey = 'pocketworld.orbit_state.v1';
  static const _objectKey = 'pocketworld.object_state.v1';

  final OrbitControls orbit;
  final ObjectTransform obj;
  final VoidCallback onStateChanged;
  bool _disposed = false;

  LifecycleObserver({
    required this.orbit,
    required this.obj,
    required this.onStateChanged,
  }) {
    WidgetsBinding.instance.addObserver(this);
    restore();
  }

  void dispose() {
    if (_disposed) return;
    _disposed = true;
    WidgetsBinding.instance.removeObserver(this);
    save();
  }

  Future<void> save() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_orbitKey, jsonEncode({
        'distance': orbit.distance,
        'azimuth': orbit.azimuth,
        'polar': orbit.polar,
        'targetX': orbit.target.x,
        'targetY': orbit.target.y,
        'targetZ': orbit.target.z,
      }));
      await prefs.setString(_objectKey, jsonEncode({
        'positionX': obj.position.x,
        'positionY': obj.position.y,
        'positionZ': obj.position.z,
        'rotationY': obj.rotationY,
      }));
    } catch (e) {
      debugPrint('[LifecycleObserver] save error: $e');
    }
  }

  Future<void> restore() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final orbitJson = prefs.getString(_orbitKey);
      if (orbitJson != null) {
        final m = jsonDecode(orbitJson) as Map<String, dynamic>;
        orbit.distance = (m['distance'] as num).toDouble();
        orbit.azimuth = (m['azimuth'] as num).toDouble();
        orbit.polar = (m['polar'] as num).toDouble();
        orbit.target.x = (m['targetX'] as num).toDouble();
        orbit.target.y = (m['targetY'] as num).toDouble();
        orbit.target.z = (m['targetZ'] as num).toDouble();
      }
      final objectJson = prefs.getString(_objectKey);
      if (objectJson != null) {
        final m = jsonDecode(objectJson) as Map<String, dynamic>;
        obj.position.x = (m['positionX'] as num).toDouble();
        obj.position.y = (m['positionY'] as num).toDouble();
        obj.position.z = (m['positionZ'] as num).toDouble();
        obj.rotationY = (m['rotationY'] as num).toDouble();
      }
      onStateChanged();
    } catch (e) {
      debugPrint('[LifecycleObserver] restore error: $e');
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    debugPrint('[LifecycleObserver] state: $state');
    switch (state) {
      case AppLifecycleState.inactive:
      case AppLifecycleState.paused:
      case AppLifecycleState.hidden:
        save();
        _channel.invokeMethod('pauseRendering').catchError((e) {
          debugPrint('[LifecycleObserver] pauseRendering error: $e');
        });
        break;
      case AppLifecycleState.resumed:
        _channel.invokeMethod('resumeRendering').catchError((e) {
          debugPrint('[LifecycleObserver] resumeRendering error: $e');
        });
        break;
      case AppLifecycleState.detached:
        save();
        break;
    }
  }
}
```

`main.dart` 集成:

```dart
late final LifecycleObserver _lifecycle;

@override
void initState() {
  super.initState();
  // ... 已有
  _lifecycle = LifecycleObserver(
    orbit: _orbit,
    obj: _object,
    onStateChanged: () => setState(() {}),
  );
  _requestTexture();
}

@override
void dispose() {
  _lifecycle.dispose();
  // ... 已有 dispose
  super.dispose();
}
```

#### Part 2 — Native Plugin Lifecycle Hooks

`MainFlutterWindow.swift` method channel handler 加:
```swift
case "pauseRendering":
    // displayLink.isPaused = true 同步,但 enqueued frame 可能在 GPU 上,
    // 需要 wait_until_completed 兜底确保 Dawn submit 完成才安全
    self.displayLink?.isPaused = true
    NSLog("[AetherTexturePlugin] paused")
    result(nil)
case "resumeRendering":
    self.displayLink?.isPaused = false
    NSLog("[AetherTexturePlugin] resumed")
    result(nil)
```

iOS plugin(`AetherTexturePlugin.swift`)同样,加 `applicationDidReceiveMemoryWarning`:
```swift
func applicationDidReceiveMemoryWarning(_ application: UIApplication) {
    NSLog("[AetherTexturePlugin] memory warning — releasing GPU")
    if let renderer = self.sceneRenderer {
        aether_scene_renderer_destroy(renderer)
        self.sceneRenderer = nil
    }
    self.iosurface = nil
}

func applicationDidBecomeActive(_ application: UIApplication) {
    if self.sceneRenderer == nil {
        NSLog("[AetherTexturePlugin] reconstructing renderer after memory pressure")
        recreateRenderer()
    }
    self.displayLink?.isPaused = false
}
```

macOS 没有 memory warning 等价 hook,**跳过 Part 3 在 macOS 上**(注释说明)。

#### Part 4 — BGURLSession + Training Checkpoint stub(Phase 7 接口 freeze)

新文件:
- `aether_cpp/include/aether/pocketworld/background_download.h`
- `aether_cpp/src/pocketworld/background_download.cpp`(stub + 日志)
- `aether_cpp/include/aether/pocketworld/training_checkpoint.h`
- `aether_cpp/src/pocketworld/training_checkpoint.cpp`(stub + 日志)

接口示例(全 stub,日志,Phase 6.7 / 7 真做):
```cpp
namespace aether::pocketworld {

enum class DownloadStatus : uint8_t {
    kPending, kInProgress, kCompleted, kFailed,
};

struct BackgroundDownloadHandle { uint64_t id; };

BackgroundDownloadHandle start_background_download(
    const std::string& url, const std::string& destination_path);
DownloadStatus query_download_status(BackgroundDownloadHandle handle);
void cancel_download(BackgroundDownloadHandle handle);

}
```

实现:
```cpp
BackgroundDownloadHandle start_background_download(...) {
    std::fprintf(stderr,
        "[background_download] STUB — Phase 6.7 will implement BGURLSession\n");
    return BackgroundDownloadHandle{0};
}
```

加进 `CMakeLists.txt` `AETHER_FFI_SOURCES`。

#### 6.4e DoD

- ☐ macOS 上切到 dock(NSApplicationDidResignActive)→ 1 秒后切回 → 场景秒恢复(orbit/obj state 完全同步,无 reload)
- ☐ App kill 重启后,SharedPreferences 持久化的 orbit/obj state 自动 restore
- ☐ Console 看到 `[LifecycleObserver]` 日志在 inactive/paused/resumed 触发
- ☐ Flutter `AppLifecycleState` 与 native plugin lifecycle 完全对齐(无状态漂移)
- ☐ App Store 审核合规预检(无后台 GPU 渲染,无非法 background mode 声明)
- ☐ BGURLSession + Training checkpoint 接口 stub 落地
- ☐ 单独 commit:`feat(pocketworld): Phase 6.4e — Lifecycle observer + memory pressure + persistence`

---

## 6. 不要做的事(scope 漂移防御)

- ❌ **8K 上采样实施**(Phase 6.4d.3,Batch 2 不在范围)
- ❌ **Android 平台 detection / FSR2**(Phase 8 真机灰度)
- ❌ **Web 端 WCG 实施**(Phase 8 WebGPU 跨平台)
- ❌ **真实 BGURLSession 完整下载流程**(Phase 6.7)
- ❌ **真实 training checkpoint 序列化**(Phase 7)
- ❌ **后台 GPU 渲染**(Apple 拒绝,决策钉子 17)
- ❌ **物理惯性 / damping**(Phase 7 polish)
- ❌ **三指 / 长按手势**(Phase 7)
- ❌ **删除 splat_render.wgsl**(Phase 6.4f 还会用)
- ❌ **重构 Phase 6.4a/b/c 已落地代码**(Batch 2 不动 working 代码)
- ❌ **添加用户引导 / tutorial / onboarding 动画**(决策钉子 11)
- ❌ **让 splat 跟手势走**(Phase 6.4f scope,你别碰)
- ❌ **iOS UIDevice tier detection**(Final iOS port 阶段)

---

## 7. 验证流程(每个 phase 完成时跑这个)

```bash
# 1. C++ build(必须 0 warning 0 error)
cd /Users/kaidongwang/Documents/Aether3D-cross/aether_cpp/build
cmake --build .

# 2. C++ smoke 全跑(从 repo 根)
cd /Users/kaidongwang/Documents/Aether3D-cross
pass=0; fail=0
for s in aether_cpp/build/aether_*; do
  if [ -x "$s" ] && [ -f "$s" ]; then
    "$s" > /tmp/smoke_$(basename $s).log 2>&1 && pass=$((pass+1)) || fail=$((fail+1))
  fi
done
echo "PASS=$pass FAIL=$fail"
# 期望:
#   6.4d.1 完成时:25/0(原 24 + 新 rgba16f smoke)
#   6.4d.2 完成时:25/0(MetalFX smoke 是 swift,不算 C++ smoke)
#   6.4e 完成时:25/0

# 3. Flutter macOS 验证(user 跑,你不跑)
cd /Users/kaidongwang/Documents/Aether3D-cross/pocketworld_flutter
flutter run -d macos
# user 对照 DoD 检查
```

每个 phase 单独 commit,phase 之间等 user verification gate PASS 才进下一个。

---

## 8. 风险矩阵

| 风险 | 严重度 | 缓解 |
|---|---|---|
| RGBA16F IOSurface 在某些 Dawn 版本不支持 | 中 | 启动时 cap detection,失败 fallback BGRA8 + 日志 abort 警告(silent = catastrophe) |
| MetalFX 在 macOS 13- 不可用 | 中 | `@available(macOS 13.0, *)` guard + simple blit fallback |
| DRS 抖动(scene 变化导致 scale 来回调) | 中 | hysteresis 阈值(高 110% 才降,低 90% 才升)+ 5 帧最低样本(钉子 24) |
| Dawn ↔ MetalFX IOSurface fence 同步 | **高** | 6.4d.2 起手 smoke 先单独验证;Dawn waitUntilCompleted 后 Swift 才 encode |
| Memory pressure 时持久化失败(磁盘满) | 低 | 持久化失败立即 abort + 日志 |
| Lifecycle hook 与 displayLink pause 时序错(渲染线程还在跑) | 中 | `displayLink.isPaused = true` 同步,但 enqueued frame 可能已在 GPU,需 `wait_until_completed` 兜底 |
| SharedPreferences 序列化 schema 升级不兼容 | 低 | key 用版本号(`v1`),新版本检测到 v1 数据可选迁移或丢弃 |
| metal_gpu_device.cpp switch 漏 case → -Werror=switch 编不过 | **高** | 6.4d.1 实施清单 step 3 显式标注 |

---

## 9. Communication 格式(每个 phase 完成报告用这个)

```text
🎯 Phase 6.4{X} 完成 — {commit_hash}

✅ DoD passed:
  - {DoD item 1}
  - {DoD item 2}
  ...

📊 Numbers:
  - LOC added: ~{N}
  - LOC deleted: ~{N}
  - New files: {list}
  - Tests passing: {N}/{N}
  - 60fps stable: yes/no
  - 其他相关指标(DRS scale 范围 / MetalFX 启用)

🔍 Open questions / risks for review:
  - {anything that needs user attention}

➡ Next: {Phase 6.4{Y} or Verification Gate}
```

---

## 10. 起手第一动作

1. **读 `/Users/kaidongwang/Documents/Aether3D-cross/aether_cpp/PHASE6_PLAN.md`**(确认目前进度)
2. **读 `aether_cpp/PHASE_BACKLOG.md`**(确认 Phase 6.4f / 6.4d.3 占位,**不要触碰**)
3. **读 `aether_cpp/src/pocketworld/scene_iosurface_renderer.cpp`**(理解 2-pass 架构,~1000 LOC)
4. **读 `aether_cpp/src/render/dawn_gpu_device.cpp`** 的 `to_wgpu_format` + `dawn_import_iosurface_texture`
5. **读 `aether_cpp/src/render/metal_gpu_device.cpp`** 的 `to_mtl_format`(确认 switch 全集)
6. **读 `pocketworld_flutter/macos/Runner/MainFlutterWindow.swift`** 的 SharedNativeTexture init
7. **起手 6.4d.1 Step 1**(GPUTextureFormat 枚举扩展)
8. 完整闭环 → smoke → commit → 等 user verification gate
9. PASS 后进 6.4d.2,**6.4d.2 起手做 MetalFX 互操作 smoke**(~30 min)
10. PASS 后进 6.4e,**起手 `flutter pub add shared_preferences`**

不要跳步,不要并行 d.1/d.2/e。每 phase 单独 commit,中间 verification gate 必须 PASS 才下一个。

---

## 11. 可信度声明

我(prompt 作者,Claude Opus 4.7 1M context)在前一会话经过 user 直接验证:
- Phase 6.4b stage 2 视觉效果(头盔 + splat 共存)— PASS
- Phase 6.4 cleanup 视觉无回归 — PASS
- orbit-target-follow-object bugfix 修好双指 → 单指过渡 — PASS

3 个 commit ahead of origin,user 暂不 push,等 Batch 2 全部完成后一起 push。

每条决策钉子 23-30 经过 user 8 项 review accept(P1-P3 全 fix)。如果实施时遇到与本 prompt 矛盾的真实约束,**stop + 跟 user 同步**,不要私自调整。

---

**End of handoff prompt**
