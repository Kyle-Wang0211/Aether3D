# Stage 3 — 渐进式交付(progressive delivery)身份闸 · 2026-09-15

目标:稠密点云边推理边出点。`pwdense_run2(..., chunk, ...)` 每融合完**一个参考帧**就立刻把该帧的
xyz/rgb 交给 app(依赖序:该帧自己的视图 + 它的 nsrc 个源视图都推完就融),而**最终 `out_ply`
与今天逐字节相同**。

## 改了什么

| 文件 | sha256 | 改动 |
|---|---|---|
| `src/dense/dense_fuse_pack.h`  | `4c7d45d1ad16272a50412aea3db988ae903a7eb5cb80222fc445a72ec3e7a8d0` | 拆出 `FusePack` / `fuse_pack_frame` / `FusePlyWriter` / `FuseScheduler` / spill |
| `src/dense/dense_fuse_pack.cc` | `867ca4351e741ad5162321240142910a2c3c985172ec74fd53e5dc8f2c0bb23c` | 同上;`fuse_pack()` 入口保留,改为在这些件上面的一层循环 |
| `src/dense/dense_pipeline.h`   | `09368d01c5a8f8fd6a6162031cd5bc070c59bbbd48d191f4a81dec8cb6fb8477` | `dense_chunk_fn` + 5 参 `dense_run`,4 参旧签名保留为 inline 重载 |
| `src/dense/dense_pipeline.cc`  | `e7d97dc6515c17cb8d4e068ca758d30c54467c47886a588dc4ef92eb5d33fda6` | 推理循环里插入调度/融合/交付/落盘;末尾按**帧序**装配 PLY |
| `src/dense/pwdense_c.cc`       | `5de55c0f01a4c6e733c4f234d67eb128bd76cf5c760dff14c68c9bc78193b771` | `pwdense_run2`;`pwdense_run` = run2(chunk=NULL) |
| `src/dense/pwdense_c_sim.c`    | `f1c1eedfed1058ae11d2ee386792a1e4fe72b01ec9b42e262c22323a27bb59bb` | 模拟器桩导出 `pwdense_run2`,返回 -1 |
| `src/dense/test_progressive.cc`| `7fc518e1511c755228c0927b68bf8ea597b53761152cfe7aa1dfb386a42a6dcb` | 新增主机闸(含阴性对照) |
| `src/dense/dense_fuse.{h,cc}`  | `49ff565e…` / `fbfe7c0a…` | **未改**(算术一行没动) |

关键设计:**融合顺序 ≠ 写盘顺序**。每帧融完落 `work_dir/fused_<f>.bin`,最后按 f0..f1 帧序装配;
`FusePackStats` 的 FNV 折叠与三个 frac 的 float64 求和也一律在帧序里做,所以位数不变。
`chunk == NULL` 走的仍是 Stage-3 之前那条路径(`fuse_pack()` 整段),一行没动。

## 闸 —— 命令与输出

主机构建(同 Stage 2:自编 OpenCV 4.0.1 `~/Developer/opencv-401-build-mac`,`-ffp-contract=off -fno-fast-math`):

```
clang++ -std=c++20 -O2 -ffp-contract=off -fno-fast-math -Wall -Wextra \
  -I$SRC -I$OCVB -I$OCVS/include -I$OCVS/modules/core/include -I$OCVS/modules/imgproc/include \
  $SRC/dense_fuse.cc $SRC/dense_fuse_pack.cc $SRC/test_progressive.cc -o test_progressive \
  $OCVB/lib/libopencv_imgproc.a $OCVB/lib/libopencv_core.a -lz -framework Accelerate
```

### 改动前的基准(pristine `dense_fuse_pack.cc` sha256 `7d793e0549d72cb335883646a833639a3b2a37eb59cb3d0ad90c3388af90b31d`)

| 臂 | 点数 | digest | PLY sha256 |
|---|---|---|---|
| subpack8 refs 0-7 | 2,471,581 | `462447d96490ff94` | `2d8c6072fd509c7257e4437c303576c9ea60516f0668df7b8404924b7abdcd21` |
| subpack8 refs 0-7 + 选择框 | 344,960 | `b2204ef83a0f729b` | `e25ef2047e748d433c6d9ac592df23ad4dc4c32d574c7e9fb0b03ae6b2b3eb53` |
| fixture97 全 97 帧 | 22,021,292 | `a3a205ab797d2610` | `64443b5b936aba9cfb588afd32238eb20edecd2cb5df065de8dcabb10574c138` |

出处自洽:`462447d96490ff94` **等于** `subpack8/hash_host.txt` 里认证的 `HALL 462447d96490ff94 frames 0-7 mode 1`;
22,021,292 **等于** 官方 Python 参考 `ref_off/summary.json` 的 `{"points": 22021292}`。

### 改动后

```
test_progressive <pack> <out> --refs 0-7        --expect-sha 2d8c6072…cd21
test_progressive <pack> <out> --refs 0-7 --box  --expect-sha e25ef204…eb53
test_progressive <pack> <out>                   --expect-sha 64443b5b…c138
```

每次都跑 5 条臂:`legacy`(旧 `fuse_pack` 入口)、`perframe`(新分解,帧序驱动)、
`progressive × {ascending, reverse, shuffled}`(调度器驱动,三种合成推理序)。

- **全部 15 条臂的 PLY sha256 与改动前的基准逐字节相同**,`FusePackStats`(points / 三个 frac 的
  float64 位 / digest / frame_digest 序列)全部相同。
- 三种推理序下 `delivery order != frame order` 都成立 —— 交付确实是乱序的,装配确实在重排。
- chunk 点数合计 == PLY 头里的 `element vertex`(2,471,581 / 344,960 / 22,021,292)。
- 每个 ref 恰好融合一次;每次交付前独立位图校验「自己 + 9 个源视图」都已标记推完。

### 阴性对照(证明这把尺子不是瞎的)

`--neg-delivery-order` 把渐进臂改成**按交付序**装配,其余不变:

| 臂 | digest | sha256 |
|---|---|---|
| ascending | `0eb9515f24dc621c` | `da0eb4f40a0acaf597f8bd1f6dd22c361dbc6a83312ec406e6808d2027dd7455` |
| reverse   | `b62dd6ae915f32d8` | `b936155c5233249ce7749930e497be8c19b32ca175486cab932c4e3429b6b474` |
| shuffled  | `3d93e7136a710170` | `4517cff2c609357890c584e54d5f78578deb7070f8e014b9394a248ddea1fdf7` |

三个 sha 全变,`photo_frac` 末位也从 `0.89571691442418977` 漂到 `…88` —— 即 float64 求和顺序本身就
是可观测量,帧序装配不是装饰。另外 `--expect-sha` 喂错值时程序确实报 🔴 并 exit 1。

### 端到端:真正的 `dense_run()`,两种调度对拍

上面那把闸只跑 `dense_fuse_pack`。再用主机桩(`dense_runner_stub.cc`:不跑 ORT,按 `pm_stage1`
指纹把认证 pack 的 depth/conf 行回放回去;`make_noise` 是从 `dense_runner.cc` 原样 sed 出来的文本)
把**真的 `dense_pipeline.cc`** 跑两遍 —— 会话表 → 解码 97 张原图 → 建 pack → 调度 → 融合 → 装配:

| refs | 臂 | 点数 | digest | PLY sha256 |
|---|---|---|---|---|
| 8 | `chunk=NULL` | 2,471,581 | `a06d40ef5bd770b8` | `453ef485e7c377df76839bf2567bbc65a0ef8a469f9eb0aea1d7d60c5f847f62` |
| 8 | `chunk!=NULL` | 2,471,581 | `a06d40ef5bd770b8` | 同上,`cmp` 逐字节相同 |
| 97 | `chunk=NULL` | 22,021,292 | `37e0dd4ec68f6b2b` | `511fb862afb0af43871bcd2191b68c3a28ae04122804f0ba252ac2865355fea3` |
| 97 | `chunk!=NULL` | 22,021,292 | `37e0dd4ec68f6b2b` | 同上,`cmp` 逐字节相同 |

97 帧那场交付序开头是 `1 16 19 45 31 30 47 48 49 …`,**帧 0 排在第 40 位才交付**,而 PLY 一字不差。
`FusePackStats` 连 97 个 `frame_digest` 的顺序都相同。装配后 `fused_*.bin` 全部清掉。

自洽检查:主机会话表逐字节重现了 `ref_off/pack/cams.f32`,所以桩的行映射是恒等的。

### 内存(97 帧满场,`/usr/bin/time -l` peak memory footprint)

| 臂 | peak memory footprint | maximum RSS |
|---|---|---|
| `chunk=NULL` | 541,984,640 B (517 MB) | 1,949,417,472 B |
| `chunk!=NULL` | 528,041,568 B (504 MB) | 1,255,374,848 B |

渐进臂**没有更高**(低 13 MB),远在 +150 MB 之内:落盘策略让同时在内存里的只有一帧的点。
代价是 `work_dir` 里临时多 330 MB 磁盘(装配后删除)。

### 顺带回归

- `make_noise` 只由 `(seed, frame_id)` 决定:把 `dense_runner.cc` 里的函数文本原样抽出来跑,12 个
  frame_id 以升序/逆序/打乱三种顺序生成,**0 个摘要不同**;阴性对照「不同 frame_id 给不同噪声」
  0 碰撞。推理顺序本身也没动(`for (int v : infer)` 原样)。
- `test_box`(选择框闸)在重构后的 `dense_fuse_pack` 上重建,输出与 2026-09-15 认证记录 `diff` 全同。
- 4 参 `dense_run(job, progress, user, stats)` 仍能解析(设备 parity bench
  `ios_dense_bench/dense_bench_main.cc:76` 用的就是它)。
- `dense_pipeline.cc` / `pwdense_c.cc` / `pwdense_c_sim.c` / `test_fuse.cc` / `test_box.cc`
  在 `-Wall -Wextra` 下零告警。

## 已知风险 / 未做

1. **`_pwdense_run2` 还没进导出表。** `experiments/dense_ondevice_2026-09-15/tools/build_pwdense_xcframeworks.sh:21`
   的 `exports.txt` 只写了 5 个符号;不加 `_pwdense_run2`,新框架里 Dart 拿不到它。该脚本在
   `pocketworld_research_benchmarks`(另一个 git 仓),本次没动。
2. **没上真机。** 以上全部是主机闸;xcframework 由你重建。设备侧 Dawn/WebGPU 只影响 Stage 1 的
   depth/conf,不影响本次改的调度与装配,但推理与融合现在会**同时**占内存(ORT session 不再提前
   释放),手机上的 jetsam 余量需要真机确认。
3. **取消路径会留下 `fused_*.bin`**。chunk 返回非 0 时直接返回 1,残留文件留给 `work_dir` 的清理方。
4. **认证 pack 的 rgb.u8 不是产品的颜色**(与本次改动无关,但会误导后来人):
   `fuse_ref_dump.py:34` 读的是 `fx_official/rgb/*.jpg` —— 已经是 768×576 的**二次编码 JPEG**,
   `.resize()` 是空操作。产品路径解的是 4032×3024 原图再按 Pillow 逐字节 resize。实测颜色字节
   ~70% 不同、最大差 38,而 **depth 逐字节相同**、点数也完全相同(22,021,292)。所以几何摘要不受
   影响,只有 `hv(rgb)` 让合成 digest 不同 —— 这正是端到端那两行 digest 与 fixture 闸不同的原因。
   谁要拿这个 pack 去对颜色,先看这条。
