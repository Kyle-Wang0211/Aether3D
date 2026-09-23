# SplatDataCache 越过设备生命周期的 use-after-free —— 调查记录

> **这是待办记录,不是修复。** 本文不改任何生产代码。
> 写于 2026-09-23,行号一律取提交 `ea4f9a88`(分支 `perf/splat-vertex-expansion`)。
> 工作树当时正在churn(见文末「写作时的工作树状态」),**不要按工作树的行号读本文**。

## 1. 机制(已逐条查实)

| 事实 | 出处(`ea4f9a88`) |
|---|---|
| `SplatData` 存的是**裸 `::aether::render::GPUDevice*`**,析构时 `device->destroy_buffer(...)` | `aether_cpp/src/pocketworld/scene_iosurface_renderer.cpp:665-682` |
| `data->device = &dev;` —— 裸指针在这里被写入 | 同上 `:2195` |
| `SplatDataCache::instance()` 是**函数局部 static**,活到进程结束,`kStrongCap_ = 3` 强持有最多 3 个 `shared_ptr<SplatData>` | 同上 `:741-743`、`:762` |
| `GPUBufferHandle` 只是 `uint32_t id`,**零所有权语义**,离开发它的设备毫无意义 | `aether_cpp/include/aether/render/gpu_resource.h:210-213` |
| `GPUDevice` 是纯虚接口 + `virtual ~GPUDevice() = default`,**我们这层没有引用计数** | `aether_cpp/include/aether/render/gpu_device.h:34-36` |
| `~DawnGPUDevice` 先把 `buffers_` 里每个 buffer `wgpuBufferDestroy` + `wgpuBufferRelease` 并 `buffers_.clear()`,**再** `wgpuDeviceRelease` | `aether_cpp/src/render/dawn_gpu_device.cpp:553-559`、`:582` |
| 设备在**最后一个 renderer 销毁时**被释放 | `aether_cpp/src/pocketworld/dawn_device_singleton.cpp`(`dawn_singleton_release()` 在 refcount 归零时 `device_ref().reset()`) |

**结构成因**:底层 Dawn 本来是引用计数的(`wgpuXAddRef/Release`),但我们这层抽象把它**擦成了一个整数句柄**;于是 `SplatDataCache` 这个进程级 static 能活得比设备久,而它手里的 `uint32_t id` 在新设备上毫无意义。

设备销毁的时机由 **live renderer 数**决定,缓存的存活时机由 **LRU** 决定,**两者没有任何耦合** —— 这就是 bug 的全部。

## 2. 两条更正(与先前转述不同,请以本节为准)

### 2.1 ❌「既是 UAF 又是重复释放(double free)」—— 不成立,只是 UAF

`DawnGPUDevice::destroy_buffer` 开头就是查表保护:

```cpp
// dawn_gpu_device.cpp:670-673
void destroy_buffer(GPUBufferHandle handle) noexcept override {
    std::lock_guard<std::mutex> lock(mutex_);
    auto it = buffers_.find(handle.id);
    if (it == buffers_.end()) return;      // ← 陈旧 id 在这里就返回了
```

而 `~DawnGPUDevice` 已经 `buffers_.clear()`。所以**即便设备对象还活着**,拿陈旧 id 调 `destroy_buffer` 也只会查不到然后返回,**不会**二次 `wgpuBufferRelease`。

真正致命的是**在已析构的 `DawnGPUDevice` 对象上调成员函数**:`std::lock_guard` 锁的是已释放的 `mutex_`,`buffers_.find` 查的是已释放的 `unordered_map`。**这是纯粹的 use-after-free,不是 double free。** 修法叙述里不要再写 double free。

### 2.2 ✅ `DecodedSplatCache` **不受影响,不需要修**

`DecodedSplatData`(`scene_iosurface_renderer.cpp:789-797`)是**纯 CPU**:

```cpp
struct DecodedSplatData {
    std::vector<::aether::splat::GaussianParams> gaussians;
    std::vector<float> sh_rest;
    std::uint32_t sh_degree{0};
    float bounds_min_pre[3]; float bounds_max_pre[3]; bool has_bounds_pre;
};
```

**无设备指针、无 GPU 句柄**,析构不碰设备。并且全文件的函数局部 static **只有两个**(`:741-743` 的 `SplatDataCache` 与 `:840-842` 的 `DecodedSplatCache`),没有第三个需要排查。

⇒ **待修范围是一个 cache,不是两个。** 将来捡起这件事的人不必重查这一步。

## 3. 触达性:**未定**。两个方向的断言都不成立

这一节是本文最要紧的部分 —— 不要在没查之前把它当成已知。

### ❌ 不能说「社区 feed 里把卡全划走再划回来就会崩」

社区 feed 发出去的是 **mesh(GLB)**,而 `SplatDataCache` 只长在 **splat** 那条路上:全文件 `SplatDataCache::instance()` 只有两处,`:2101` 的 `get` 与 `:2225` 的 `put`,都在 `build_splat_scene_from_gaussians` 内。走 GLB 的路**根本不碰这个 cache**。

此前的「划走再划回来」说法是从上一个 agent 的报告里转述的,**未经验证,现予撤回**。

### ❌ 也不能说「splat 路是死代码所以不用管」

- `aether_scene_renderer_load_ply_capped`(`scene_iosurface_renderer.cpp:3407-3414`)**不是桩**,函数体直接 `return load_ply_into_renderer(r, ply_path, max_splats, max_sh_degree);`。
- Dart 侧 `pocketworld_flutter/lib/ui/community/viewer_impl.dart:325-326` 那句「Phase 6.4f stub: SceneBridge.loadPly calls the native C ABI which **currently returns false**」是**过期注释**,与上面的 C ABI 实现矛盾。

### ⚠️ 「机制已证实」≠「生产可达」—— 两个会话在这里有分歧

另一个会话(`aether_dawn_scene_splat_smoke is red on macOS host`)主张第 4 节那条 Dawn validation error
**就是**「生产可达」的证实。本文不采纳这个推论,理由:

那条错误是在**冒烟工具**里产生的,而该工具自己显式地把一个 `.ply` 喂进 splat 那条路(`load_ply`)。
它证实的是「**一旦走进 `build_splat_scene_from_gaussians`,销毁→重建→同 key 命中就会拿到属于旧设备的
handle**」—— 也就是**机制**为真,且不必等进程退出就能摸到。这一条我自己独立复现过(rc=134),不含糊。

但它**没有**回答「出货 app 会不会走进那条路」。二者是不同的命题,不能互相顶替。

### ⇒ 真正待查的一个具体问题

**出货的作品里,有没有任何一件会被分类成 `plyGsplat`(而不是 `plyMesh`),从而真的走进 `build_splat_scene_from_gaussians`?**

答案是 yes,则这是出货 app 里够得着的 UAF;答案是 no,则只剩进程退出期的崩溃(仍然卡着 CI 闸,仍然要修,
只是优先级不同)。**这一步留给将来,本轮不查。** 查法:看资产分类那一步在什么条件下产出 `plyGsplat`,
再对出货作品清单跑一遍。

## 4. 复现与实测

进程退出期那条(`~SplatDataCache` → `~SplatData` → 已释放设备):

```
EXC_BAD_ACCESS (code=1, address=0x1030)
frame #0: std::__1::__shared_ptr_emplace<SplatData, ...>::__on_zero_shared()
```

shell 看到 139 / signal 11。因为静态析构跑在 stdio 的 atexit flush **之前**,它还会吃掉缓冲的 stdout —— 冒烟打印的判决在管道/文件里(即 CI 里)**全部不可见**。

不退出进程那条(销毁 → 重建 → 同资产命中),2026-09-23 实测:

```
--- phase2: device was torn down; rebuilding + cache hit ---
[Aether3D][scene_renderer] build_splat_scene: cache HIT key='ply|…|0|3' (refcount=3)
[Aether3D][Dawn] UNCAPTURED ERROR type=Validation (2)
  msg=[Buffer "splat.global_from_compact_gid"] usage (Storage(read-write)|Storage(read-only))
      includes writable usage and another usage in the same synchronization scope.
```

退出码 **134**(设备错误闸 abort)。缓存键是 `ext|path|mtime|max_splats|max_sh_degree`(`:3037-3062` 的 `make_cache_key`),**不含任何设备身份**,所以设备换了一个、键仍然命中。

> ⚠️ 上面这段 `phase2` 观测跑的是当时工作树里**另一个会话未提交的**冒烟工具,不是 `ea4f9a88` 的版本。
> ⚠️ 报的那个 buffer(`splat.global_from_compact_gid`)是**逐 renderer 的 scratch**,不是缓存里的 `SplatData` buffer。
> 「陈旧句柄 id 在新设备上与别的 live buffer 撞号,于是两个 binding 解析到同一块 buffer」**只是假设,未经证实**。

## 5. 修法方向(**不要现在选,不要现在写实现**)

按本项目铁律「找官网代码直接复刻,禁止任何自研」,要复刻的是**所有权模型**,候选(将来须给出文件 + 行号):

1. **Dawn / WebGPU 自己的引用计数对象模型** —— `webgpu_cpp.h` 的 RAII 句柄、`wgpuXAddRef/Release` 约定。**我们底层已经在用它,是上层把它擦成了整数句柄。** 这条最贴近病因。
2. **Brush**(splat 部分的来源,Apache-2.0,`3edecbb2fe79d3e2c87eeab85b15e0b1dd10d486`)—— Rust,生命周期由编译器保证 ⇒ 它**结构上不可能有这个 bug**;对应的 C++ 写法该是什么,本身就是一条信息。
3. **Filament**(树里有,thermion 那条)—— 资源/缓存怎么绑到 engine 生命周期。

读完若**没有**任何上游模式可对应,**停下来报告,不要自己发明一个**。

### 一条硬约束(选修法时必须满足)

`aether_cpp/src/pocketworld/dawn_device_singleton.h` 的契约白纸黑字写着:

> when the last renderer is destroyed, the device is released so memory-pressure recovery
> (background → foreground after iOS suspended) gets a **fresh device** on next acquire.

⇒ **让 `SplatData` 去 pin 住设备(acquire/release)的写法违反这条契约**:设备将永不销毁,内存压力恢复拿不到 fresh device,且 viewer 关掉之后还会驻留最多 3 × 150–180 MB 的 splat buffer(`kStrongCap_` 注释按 iPhone 12 的 ~1.3 GB 预算定的 cap)。
缓存的生命周期应当**收进设备的生命周期里**,而不是反过来。

## 6. 写作时的工作树状态(2026-09-23)

- 分支 `perf/splat-vertex-expansion`,HEAD = `ea4f9a88`。
- **另一个会话**(`aether_dawn_scene_splat_smoke is red on macOS host`)当时正在同一棵树里改生产代码 ——
  `src/pocketworld/dawn_device_singleton.{cpp,h}`(teardown hook 表)与 `scene_iosurface_renderer.cpp`
  (`SplatDataCache::clear()` + `call_once` 注册 hook),以及 `tools/aether_dawn_scene_splat_smoke.mm`
  (553 → 672 行,已自行加了 phase2 回归用例)。**全部未提交。**
  该会话自述已验:打 fix 后 phase1/phase2 逐像素相同(9978 px,drift 0.0000%),sort 与 sh1 各 10/10 rc=0。
  **本文未复核这组数字。** 其 patch 副本放在该会话的 scratchpad `handoff/` 下
  (`01_production_splatdatacache_uaf_fix.patch`、`02_smoke_phase2_regression_and_argv.patch`)。
  其修法方向与本文第 5 节那条硬约束一致(清 cache,而不是让 `SplatData` 钉住设备)。
- 本次按用户指示**停手**:未改 `src/` 下任何文件,只新增本文。谁落地那份 fix 由用户拍板。
- ⚠️ `aether_cpp/third_party/glomap_vendor/iosapp/GlomapBench.xcodeproj/project.pbxproj` 是**先于本轮存在**的未合并路径,会挡住 `git commit`;用临时 `GIT_INDEX_FILE` + `commit-tree` + `update-ref` 绕过,**不要去「顺手解决」别人的冲突**。
- ⚠️ 不要用 `git checkout -- aether_cpp/src` 做清理:`aether_cpp/src` 下当时有 **21 条别人的未提交改动**(`dense/` 十个文件等),会被一并抹掉。
