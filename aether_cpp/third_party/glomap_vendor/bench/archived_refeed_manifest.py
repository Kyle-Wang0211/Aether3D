#!/usr/bin/env python3
"""archived_refeed_manifest.py — 从存档照片的 sidecar 生成 refeed 台架的 manifest。

[2026-09-08] 配 archived_refeed_bench.mm 使用。拍摄被杀掉的项目 db 是 4096 字节的
malformed 单页(跑完 finalize 的是 41MB / wal=0),`.recover` 抢不出任何表 ——
「开始训练」和「补拍」都建立在"db 里有东西"上,所以都必然 errDb。但照片和每张的
ARKit 位姿/内参完整留在 photos_highres/,重新喂一遍就能救回来。

位姿约定(**每次运行都当场验一遍,不靠记忆**):
  sidecar 的 `extrinsic` = 16 个 double,**列主序 camera-to-world**
  (第 4 个元素恒为 0,正是列主序的证据)。核要的是 CamFromWorld:
      R_cfw = R_c2w^T          t_cfw = -R_c2w^T · t_c2w
本脚本用 official_sfm_fed_frames.jsonl 当**阳性对照**:那个文件自带
`arkitPoseConvention` 明文,写着 "CamFromWorld inverted from ARKit cameraToWorld"。
两边逐帧对拍,误差不达标就**拒绝出 manifest** —— 这处若弄反不会报错,
只会安静地出一朵歪点云。

喂帧顺序 = 按文件名里的**帧序号 N 数值**升序(不是字符串序,更不是 `t`):
  · 字符串序会把 tap-99 排在 tap-129 之后 —— 顺序错了不报错,只让流式匹配的
    时序候选窗(k_neighbors)挑错邻居。
  · `t` 是 ARKit 的 uptime 时钟,**跨会话会归零**。实测本项目:tap-1..182 的
    t≈47901,补拍进来的 tap-203/226/233 t≈2145(相隔 36 分钟、机器重启过)。
    按 t 排会把补拍的三张排到最前面。补拍天然跨会话,所以 t 不能当排序键。
  · N 由采集会话单调发放,补拍时 `maxFrameSeqInNames` 接着往上排(见
    photo_slot_naming.dart),所以 N 是我们自己保证的全局拍摄序,不依赖任何时钟。

usage: archived_refeed_manifest.py <photos_dir> <out_manifest> [--jsonl F]
"""

import argparse
import glob
import json
import math
import os
import re
import sys


def cam_from_world(extrinsic):
    """列主序 camera-to-world 16 元组 → (qwxyz, txyz) 的 CamFromWorld。"""
    e = extrinsic
    # 列主序:第 c 列 = e[4c : 4c+4]。R_c2w[r][c] = e[4c + r]。
    r_c2w = [[e[0], e[4], e[8]], [e[1], e[5], e[9]], [e[2], e[6], e[10]]]
    t_c2w = [e[12], e[13], e[14]]
    # R_cfw = R_c2w^T
    r = [[r_c2w[c][row] for c in range(3)] for row in range(3)]
    t = [-sum(r[i][k] * t_c2w[k] for k in range(3)) for i in range(3)]
    return mat_to_quat(r), t


def mat_to_quat(r):
    """3x3 旋转 → (w,x,y,z)。Shepperd 分支法,避免 trace<0 时开根号丢精度。"""
    tr = r[0][0] + r[1][1] + r[2][2]
    if tr > 0:
        s = math.sqrt(tr + 1.0) * 2
        w = 0.25 * s
        x = (r[2][1] - r[1][2]) / s
        y = (r[0][2] - r[2][0]) / s
        z = (r[1][0] - r[0][1]) / s
    elif r[0][0] > r[1][1] and r[0][0] > r[2][2]:
        s = math.sqrt(1.0 + r[0][0] - r[1][1] - r[2][2]) * 2
        w = (r[2][1] - r[1][2]) / s
        x = 0.25 * s
        y = (r[0][1] + r[1][0]) / s
        z = (r[0][2] + r[2][0]) / s
    elif r[1][1] > r[2][2]:
        s = math.sqrt(1.0 + r[1][1] - r[0][0] - r[2][2]) * 2
        w = (r[0][2] - r[2][0]) / s
        x = (r[0][1] + r[1][0]) / s
        y = 0.25 * s
        z = (r[1][2] + r[2][1]) / s
    else:
        s = math.sqrt(1.0 + r[2][2] - r[0][0] - r[1][1]) * 2
        w = (r[1][0] - r[0][1]) / s
        x = (r[0][2] + r[2][0]) / s
        y = (r[1][2] + r[2][1]) / s
        z = 0.25 * s
    n = math.sqrt(w * w + x * x + y * y + z * z)
    q = [w / n, x / n, y / n, z / n]
    # q 与 -q 是同一个旋转;固定 w>=0 才能和参照逐分量比。
    return [-c for c in q] if q[0] < 0 else q


def quat_err(a, b):
    """两个单位四元数的角度差(弧度),对 q/-q 同一性免疫。"""
    d = abs(sum(x * y for x, y in zip(a, b)))
    return 2.0 * math.acos(max(-1.0, min(1.0, d)))


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("photos_dir")
    ap.add_argument("out_manifest")
    ap.add_argument("--jsonl", default=None,
                    help="official_sfm_fed_frames.jsonl(阳性对照;缺省自动在 "
                         "photos_dir 及其父目录里找)")
    ap.add_argument("--max-quat-err", type=float, default=1e-4,
                    help="与 fed_frames 参照的最大允许角差(弧度)")
    args = ap.parse_args()

    jpegs = sorted(glob.glob(os.path.join(args.photos_dir, "*.jpg")))
    if not jpegs:
        sys.exit("no *.jpg under %s" % args.photos_dir)

    rows = []
    rejected = []
    for jpg in jpegs:
        side = jpg[:-4] + ".json"
        if not os.path.exists(side):
            rejected.append((jpg, "缺 sidecar"))
            continue
        try:
            j = json.load(open(side))
        except Exception as exc:  # noqa: BLE001 - 逐张留痕,不整批中断
            rejected.append((jpg, "sidecar 解析失败: %s" % exc))
            continue
        ext = j.get("extrinsic")
        intr = j.get("intrinsics_fxfycxcy")
        w, h, t = j.get("image_w"), j.get("image_h"), j.get("t")
        if not (isinstance(ext, list) and len(ext) == 16):
            rejected.append((jpg, "extrinsic 不是 16 元组"))
            continue
        if not (isinstance(intr, list) and len(intr) == 4):
            rejected.append((jpg, "缺 intrinsics_fxfycxcy"))
            continue
        if not isinstance(w, int) or not isinstance(h, int):
            rejected.append((jpg, "缺 image_w/image_h"))
            continue
        if not isinstance(t, (int, float)) or not math.isfinite(t):
            rejected.append((jpg, "缺时间戳 t"))
            continue
        m = re.search(r"-(\d+)\.jpg$", os.path.basename(jpg))
        if m is None:
            rejected.append((jpg, "文件名里读不出帧序号(期望 *-<N>.jpg)"))
            continue
        seq = int(m.group(1))
        q, tv = cam_from_world([float(x) for x in ext])
        rows.append({"path": os.path.abspath(jpg), "w": w, "h": h,
                     "fx": intr[0], "fy": intr[1], "cx": intr[2],
                     "cy": intr[3], "q": q, "t": tv, "capture_t": float(t),
                     "seq": seq, "ext": [float(x) for x in ext]})

    # ── 阳性对照:约定必须当场验,不能靠"我记得是这样" ────────────────────
    ref_path = args.jsonl
    if ref_path is None:
        for cand in (os.path.join(args.photos_dir, "official_sfm_fed_frames.jsonl"),
                     os.path.join(os.path.dirname(os.path.abspath(args.photos_dir)),
                                  "official_sfm_fed_frames.jsonl")):
            if os.path.exists(cand):
                ref_path = cand
                break
    if ref_path is None or not os.path.exists(ref_path):
        sys.exit("找不到 official_sfm_fed_frames.jsonl —— 没有参照就无法验证位姿"
                 "约定,拒绝出 manifest(用 --jsonl 指定)")

    by_name = {os.path.basename(r["path"]): r for r in rows}
    checked = 0
    worst = 0.0
    best_wrong = math.inf  # 阴性对照里**最好**的一张,用来证明对照有区分力
    for line in open(ref_path):
        line = line.strip()
        if not line:
            continue
        rec = json.loads(line)
        name = os.path.basename(rec.get("jpegPath", ""))
        ref_q = rec.get("arkitCamFromWorldQwxyz")
        if name not in by_name or not ref_q:
            continue
        ref_q = [float(x) for x in ref_q]
        err = quat_err(by_name[name]["q"], ref_q)
        # 阴性对照:把 extrinsic 当成"本身就是 CamFromWorld"(即不求逆)。
        # 若这条也很准,说明对照根本区分不了两种解释,判据是空转的 ——
        # 判据必须先过阳性/阴性对照,才配当判据。
        e = by_name[name]["ext"]
        wrong_q = mat_to_quat([[e[0], e[4], e[8]],
                               [e[1], e[5], e[9]],
                               [e[2], e[6], e[10]]])
        wrong_err = quat_err(wrong_q, ref_q)
        checked += 1
        worst = max(worst, err)
        best_wrong = min(best_wrong, wrong_err)
        print("PARITY %-24s inverted=%.9f  not-inverted=%.9f  (rad)"
              % (name, err, wrong_err))
    if checked == 0:
        sys.exit("参照文件里没有一条能和照片对上 —— 对照空转,拒绝出 manifest")
    if worst > args.max_quat_err:
        sys.exit("位姿约定对照失败:最大角差 %.9f rad > %.9f" % (worst, args.max_quat_err))
    if best_wrong <= worst * 10 + 1e-6:
        sys.exit("阴性对照没拉开差距(错解释最好 %.9f vs 正解释最差 %.9f)——"
                 "对照无区分力,拒绝出 manifest" % (best_wrong, worst))
    print("PARITY_OK checked=%d worst_err=%.9f rad;阴性对照最好也差 %.6f rad(ref=%s)"
          % (checked, worst, best_wrong, os.path.basename(ref_path)))

    rows.sort(key=lambda r: (r["seq"], r["capture_t"], r["path"]))
    with open(args.out_manifest, "w") as f:
        f.write("# 喂帧序 = 文件名帧序号 N 升序(ARKit t 跨会话归零,不可当排序键)\n")
        f.write("# path w h fx fy cx cy qw qx qy qz tx ty tz capture_t\n")
        for r in rows:
            f.write("%s %d %d %.10f %.10f %.10f %.10f %.12f %.12f %.12f %.12f "
                    "%.10f %.10f %.10f %.9f\n"
                    % (r["path"], r["w"], r["h"], r["fx"], r["fy"], r["cx"],
                       r["cy"], r["q"][0], r["q"][1], r["q"][2], r["q"][3],
                       r["t"][0], r["t"][1], r["t"][2], r["capture_t"]))
    print("WROTE %s rows=%d rejected=%d" % (args.out_manifest, len(rows),
                                            len(rejected)))
    for jpg, why in rejected:
        print("REJECTED %s: %s" % (os.path.basename(jpg), why))


if __name__ == "__main__":
    main()
