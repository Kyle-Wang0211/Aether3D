#!/usr/bin/env python
"""
W1 D3 D5 quality verification — Mac-side DA3-LARGE-1.1 batch inference + viz.

For each RGB frame in the input dir:
  1. Tile-based DA3-LARGE-1.1 inference (4×3 = 12 tiles of 518×518, overlap 32)
     — matches the on-device Swift Tile2KWrapper exactly (same preprocessing,
     same tile layout, same blend weight).
  2. Per-tile inference time + memory usage.
  3. Blend tiles → full-resolution depth + confidence maps.
  4. Compute mean conf, depth range, low-conf %, coverage.
  5. Render visualization PNGs:
     - depth (grayscale, normalized per-frame)
     - conf  (viridis colormap, comparable to user's cloud baseline)

Then generate a multi-frame grid PNG comparing all frames side-by-side
(format mimics user's prior cloud comparison image:
 columns = depth / conf, rows = frames).

Usage:
    python da3_quality_check.py <frames_dir>  [--out OUT_DIR] [--max-frames N] [--compute-units cpuOnly|cpuAndGPU|ALL]

Outputs (under OUT_DIR, default ./da3_quality_out/):
    frame_<idx>_depth.png    — grayscale depth, normalized [near→white, far→black]
    frame_<idx>_conf.png     — viridis colormap confidence
    grid_summary.png         — multi-frame grid (depth + conf per row)
    stats.json               — per-frame stats (mean conf, depth range, timings)
"""
from __future__ import annotations

import argparse
import json
import os
import sys
import time
from pathlib import Path

os.environ.setdefault("KMP_DUPLICATE_LIB_OK", "TRUE")

import coremltools as ct
import matplotlib

matplotlib.use("Agg")  # headless
import matplotlib.pyplot as plt
import numpy as np
from PIL import Image

# ── Constants matching Swift Tile2KWrapper exactly ──────────────────────────
TILE_SIZE = 518
OVERLAP = 32
STRIDE = TILE_SIZE - OVERLAP
EDGE_FLOOR = 0.05
CONF_FLOOR = 0.01
CONF_CAP = 1.0
IMAGENET_MEAN = np.array([0.485, 0.456, 0.406], dtype=np.float32)
IMAGENET_STD = np.array([0.229, 0.224, 0.225], dtype=np.float32)

DEFAULT_MODEL_PATH = Path(
    "/Users/kaidongwang/Developer/Aether3D-cross/pocketworld_flutter/ios/"
    "Runner/Models/DA3-LARGE-1.1-CoreML/DA3LARGE_v11_518.mlpackage"
)


# ── Tile layout — bit-for-bit copy of Swift Tile2KWrapper.makeLayout ────────


def compute_tile_layout(img_w: int, img_h: int) -> dict:
    if img_w == TILE_SIZE:
        nx = 1
    else:
        extra = img_w - TILE_SIZE
        nx = (extra + STRIDE - 1) // STRIDE + 1
    if img_h == TILE_SIZE:
        ny = 1
    else:
        extra = img_h - TILE_SIZE
        ny = (extra + STRIDE - 1) // STRIDE + 1
    tiles = []
    for row in range(ny):
        for col in range(nx):
            x = (img_w - TILE_SIZE) if col == nx - 1 else col * STRIDE
            y = (img_h - TILE_SIZE) if row == ny - 1 else row * STRIDE
            tiles.append({"x": int(x), "y": int(y), "row": row, "col": col})
    return {"nx": nx, "ny": ny, "tiles": tiles, "img_w": img_w, "img_h": img_h}


# ── Per-tile preprocessing — matches Swift cgImageToMLMultiArray ────────────


def preprocess_tile_to_chw(tile_rgb_uint8: np.ndarray) -> np.ndarray:
    """RGB uint8 HW×3 → ImageNet-normalized fp32 (1, 3, H, W)."""
    rgb = tile_rgb_uint8.astype(np.float32) / 255.0
    rgb = (rgb - IMAGENET_MEAN) / IMAGENET_STD
    chw = np.transpose(rgb, (2, 0, 1))
    return chw[np.newaxis, :, :, :].astype(np.float32)


# ── Edge weight matrix — pre-computed once per tile size ────────────────────


def _build_edge_weight_matrix() -> np.ndarray:
    """Matches Swift edgeFade × edgeFade + floor 0.05."""
    coords = np.arange(TILE_SIZE)
    dist = np.minimum(coords, TILE_SIZE - 1 - coords)
    in_overlap = dist < OVERLAP
    t = np.clip(dist / OVERLAP, 0.0, 1.0)
    edge_fade = np.sin(np.pi / 2 * t) ** 2
    edge_fade = np.where(in_overlap, edge_fade, 1.0)
    # 2D = outer product
    w = np.outer(edge_fade, edge_fade).astype(np.float32)
    return np.maximum(EDGE_FLOOR, w)


EDGE_WEIGHT = _build_edge_weight_matrix()


# ── Inference + blend one frame ──────────────────────────────────────────────


def infer_frame(image_path: Path, model: ct.models.MLModel) -> dict:
    img = Image.open(image_path).convert("RGB")
    img_w, img_h = img.size
    layout = compute_tile_layout(img_w, img_h)
    img_arr = np.array(img)  # (H, W, 3) uint8

    tile_records = []
    for i, tile in enumerate(layout["tiles"]):
        x, y = tile["x"], tile["y"]
        tile_rgb = img_arr[y : y + TILE_SIZE, x : x + TILE_SIZE]
        if tile_rgb.shape != (TILE_SIZE, TILE_SIZE, 3):
            raise ValueError(
                f"Tile {i} at ({x}, {y}) has shape {tile_rgb.shape}, "
                f"expected ({TILE_SIZE}, {TILE_SIZE}, 3). Image size {img.size}, layout {layout['nx']}x{layout['ny']}."
            )
        input_arr = preprocess_tile_to_chw(tile_rgb)
        t0 = time.time()
        out = model.predict({"image": input_arr})
        elapsed_ms = (time.time() - t0) * 1000.0
        depth = np.asarray(out["depth"]).astype(np.float32).squeeze()  # (518, 518)
        conf = np.asarray(out["depth_conf"]).astype(np.float32).squeeze()
        tile_records.append(
            {
                "x": x, "y": y, "row": tile["row"], "col": tile["col"],
                "ms": elapsed_ms,
                "depth_min": float(depth.min()),
                "depth_max": float(depth.max()),
                "conf_min": float(conf.min()),
                "conf_max": float(conf.max()),
                "depth": depth,
                "conf": conf,
            }
        )

    # Blend
    blend_depth = np.zeros((img_h, img_w), dtype=np.float32)
    blend_conf_acc = np.zeros((img_h, img_w), dtype=np.float32)
    blend_w = np.zeros((img_h, img_w), dtype=np.float32)

    blend_t0 = time.time()
    for tr in tile_records:
        x, y = tr["x"], tr["y"]
        depth_t = tr["depth"]
        conf_t = tr["conf"]
        conf_weight = np.clip(conf_t - 1.0, CONF_FLOOR, CONF_CAP)
        w = conf_weight * EDGE_WEIGHT
        blend_depth[y : y + TILE_SIZE, x : x + TILE_SIZE] += depth_t * w
        blend_conf_acc[y : y + TILE_SIZE, x : x + TILE_SIZE] += conf_t * w
        blend_w[y : y + TILE_SIZE, x : x + TILE_SIZE] += w
    blend_ms = (time.time() - blend_t0) * 1000.0

    mask = blend_w > 0
    blend_depth_norm = np.zeros_like(blend_depth)
    blend_conf_norm = np.zeros_like(blend_conf_acc)
    blend_depth_norm[mask] = blend_depth[mask] / blend_w[mask]
    blend_conf_norm[mask] = blend_conf_acc[mask] / blend_w[mask]

    coverage = float(mask.sum()) / (img_w * img_h)
    d_valid = blend_depth_norm[mask]
    c_valid = blend_conf_norm[mask]
    low_conf_pct = float((c_valid < 1.1).sum()) / max(1, c_valid.size) * 100.0

    return {
        "image_path": str(image_path),
        "img_w": img_w,
        "img_h": img_h,
        "layout": {k: v for k, v in layout.items() if k != "tiles"},
        "n_tiles": len(tile_records),
        "tile_ms_avg": float(np.mean([t["ms"] for t in tile_records])),
        "tile_ms_max": float(np.max([t["ms"] for t in tile_records])),
        "tile_ms_total": float(sum(t["ms"] for t in tile_records)),
        "blend_ms": blend_ms,
        "coverage": coverage,
        "depth_min": float(d_valid.min()) if d_valid.size else 0.0,
        "depth_max": float(d_valid.max()) if d_valid.size else 0.0,
        "depth_mean": float(d_valid.mean()) if d_valid.size else 0.0,
        "conf_mean": float(c_valid.mean()) if c_valid.size else 0.0,
        "conf_min": float(c_valid.min()) if c_valid.size else 0.0,
        "conf_max": float(c_valid.max()) if c_valid.size else 0.0,
        "low_conf_pct": low_conf_pct,
        "blend_depth": blend_depth_norm,
        "blend_conf": blend_conf_norm,
        "mask": mask,
    }


# ── Visualization ────────────────────────────────────────────────────────────


def save_depth_png(depth: np.ndarray, out_path: Path) -> None:
    """Normalize depth per-frame then save as grayscale PNG (near = white)."""
    d_min, d_max = depth.min(), depth.max()
    if d_max - d_min < 1e-6:
        norm = np.zeros_like(depth, dtype=np.uint8)
    else:
        # DA3 outputs relative depth; smaller = closer (in DA-V2/V3 convention).
        # Invert so near (small depth) renders as bright white in PNG (typical
        # "depth map" visualization, matches Swift Tile2KWrapper output).
        inv = (d_max - depth) / (d_max - d_min)
        norm = (inv * 255.0).clip(0, 255).astype(np.uint8)
    Image.fromarray(norm, mode="L").save(out_path)


def save_conf_viridis_png(conf: np.ndarray, mask: np.ndarray, out_path: Path,
                          vmin: float | None = None, vmax: float | None = None) -> None:
    """Confidence map with viridis colormap (matches user's cloud-baseline format)."""
    fig, ax = plt.subplots(figsize=(conf.shape[1] / 100, conf.shape[0] / 100), dpi=100)
    masked = np.where(mask, conf, np.nan)
    im = ax.imshow(masked, cmap="viridis", vmin=vmin, vmax=vmax,
                   interpolation="nearest")
    ax.axis("off")
    plt.colorbar(im, ax=ax, fraction=0.046, pad=0.04)
    ax.set_title(f"mean conf: {np.nanmean(masked):.3f}", fontsize=10)
    plt.tight_layout()
    plt.savefig(out_path, dpi=100, bbox_inches="tight", facecolor="white")
    plt.close(fig)


def render_grid_summary(results: list[dict], out_path: Path) -> None:
    """6-row × 2-col grid: rows=frames, cols=[depth, conf-viridis]. Mimics user's
    cloud-baseline reference image (frame 0/15/30/45/60/75 × 4 models),
    except we only have 1 model so 2 cols suffice."""
    n = len(results)
    fig_h = 2.5 * n
    fig, axes = plt.subplots(n, 2, figsize=(8, fig_h))
    if n == 1:
        axes = axes[np.newaxis, :]

    for i, res in enumerate(results):
        depth = res["blend_depth"]
        conf = res["blend_conf"]
        mask = res["mask"]
        frame_name = Path(res["image_path"]).stem

        # Depth (grayscale, "near=bright")
        d_min, d_max = depth.min(), depth.max()
        d_inv = np.where(mask, (d_max - depth) / max(d_max - d_min, 1e-6), 0)
        axes[i, 0].imshow(d_inv, cmap="gray")
        axes[i, 0].axis("off")
        axes[i, 0].set_title(f"{frame_name} depth   range [{d_min:.2f}, {d_max:.2f}]", fontsize=9)

        # Conf (viridis)
        c_masked = np.where(mask, conf, np.nan)
        im = axes[i, 1].imshow(c_masked, cmap="viridis")
        axes[i, 1].axis("off")
        axes[i, 1].set_title(f"DA3-LARGE-1.1 local — mean conf {res['conf_mean']:.3f}", fontsize=9)
        plt.colorbar(im, ax=axes[i, 1], fraction=0.046, pad=0.04)

    fig.suptitle(
        "W1 D3 D5 — DA3-LARGE-1.1 local CoreML on real PocketWorld capture\n"
        "yellow = high confidence (trust depth), purple = low (mask out)",
        fontsize=11
    )
    plt.tight_layout(rect=[0, 0, 1, 0.97])
    plt.savefig(out_path, dpi=120, bbox_inches="tight", facecolor="white")
    plt.close(fig)


# ── Main ─────────────────────────────────────────────────────────────────────


def main() -> int:
    parser = argparse.ArgumentParser(description="DA3-LARGE-1.1 batch inference + viz on real RGB frames.")
    parser.add_argument("frames_dir", help="Directory containing .jpg/.png frames")
    parser.add_argument("--out", default="./da3_quality_out", help="Output directory")
    parser.add_argument("--max-frames", type=int, default=6,
                        help="Max frames to process (default 6, matches cloud baseline grid)")
    parser.add_argument("--compute-units", default="cpuOnly",
                        choices=["cpuOnly", "cpuAndGPU", "cpuAndNeuralEngine", "ALL"])
    parser.add_argument("--model-path", default=str(DEFAULT_MODEL_PATH))
    parser.add_argument("--baseline-conf", type=float, default=None,
                        help="Optional cloud baseline mean conf for fidelity check "
                        "(e.g., 1.694 for 纸袋). Omit if no baseline available.")
    args = parser.parse_args()

    frames_dir = Path(args.frames_dir)
    out_dir = Path(args.out)
    out_dir.mkdir(parents=True, exist_ok=True)

    # Discover frames
    frames = sorted(
        [p for p in frames_dir.iterdir() if p.suffix.lower() in {".jpg", ".jpeg", ".png"}]
    )
    if not frames:
        print(f"[D5] no frames in {frames_dir}", file=sys.stderr)
        return 1
    print(f"[D5] found {len(frames)} frames in {frames_dir}")

    # Subsample to max-frames evenly across the sequence (mimics cloud baseline:
    # frame 0, 15, 30, 45, 60, 75 from a 90-frame capture).
    if len(frames) > args.max_frames:
        idxs = np.linspace(0, len(frames) - 1, args.max_frames, dtype=int)
        frames = [frames[i] for i in idxs]
        print(f"[D5] subsampled to {len(frames)} frames: {[f.name for f in frames]}")

    cu_map = {
        "cpuOnly": ct.ComputeUnit.CPU_ONLY,
        "cpuAndGPU": ct.ComputeUnit.CPU_AND_GPU,
        "cpuAndNeuralEngine": ct.ComputeUnit.CPU_AND_NE,
        "ALL": ct.ComputeUnit.ALL,
    }
    print(f"[D5] loading model from {args.model_path} with compute_units={args.compute_units}")
    t_load = time.time()
    model = ct.models.MLModel(args.model_path, compute_units=cu_map[args.compute_units])
    print(f"[D5] model loaded in {time.time() - t_load:.2f}s")

    results: list[dict] = []
    for i, frame_path in enumerate(frames):
        print(f"[D5] [{i + 1}/{len(frames)}] {frame_path.name}", flush=True)
        try:
            res = infer_frame(frame_path, model)
        except Exception as e:
            print(f"[D5] FAILED on {frame_path.name}: {e}", file=sys.stderr)
            continue
        results.append(res)
        print(
            f"[D5]   tiles={res['n_tiles']}  tile_ms avg={res['tile_ms_avg']:.0f} "
            f"max={res['tile_ms_max']:.0f}  total={res['tile_ms_total']:.0f}  "
            f"blend={res['blend_ms']:.0f}  cov={res['coverage']:.3%}  "
            f"depth=[{res['depth_min']:.3f},{res['depth_max']:.3f}] mean={res['depth_mean']:.3f}  "
            f"conf=mean {res['conf_mean']:.3f} range [{res['conf_min']:.3f},{res['conf_max']:.3f}]  "
            f"low-conf {res['low_conf_pct']:.1f}%"
        )

        # Per-frame PNGs
        depth_out = out_dir / f"frame_{i:02d}_{frame_path.stem}_depth.png"
        conf_out = out_dir / f"frame_{i:02d}_{frame_path.stem}_conf.png"
        save_depth_png(res["blend_depth"], depth_out)
        save_conf_viridis_png(res["blend_conf"], res["mask"], conf_out)

    # Grid summary
    if results:
        grid_path = out_dir / "grid_summary.png"
        render_grid_summary(results, grid_path)
        print(f"[D5] wrote grid summary → {grid_path}")

    # Stats JSON (drop big arrays)
    stats = []
    for res in results:
        s = {k: v for k, v in res.items() if k not in {"blend_depth", "blend_conf", "mask"}}
        stats.append(s)
    stats_path = out_dir / "stats.json"
    stats_path.write_text(json.dumps(stats, indent=2))
    print(f"[D5] wrote stats → {stats_path}")

    if results:
        all_conf_mean = float(np.mean([r["conf_mean"] for r in results]))
        all_conf_stdev = float(np.std([r["conf_mean"] for r in results]))
        avg_depth_mean = float(np.mean([r["depth_mean"] for r in results]))
        avg_low_conf = float(np.mean([r["low_conf_pct"] for r in results]))

        print(
            f"\n[D5] ======== W1 D3 D5 quality summary ========\n"
            f"  frames processed: {len(results)} / {len(frames)}\n"
            f"  avg mean conf across frames: {all_conf_mean:.3f}  (stddev {all_conf_stdev:.3f})\n"
            f"  avg depth mean: {avg_depth_mean:.3f}\n"
            f"  avg low-conf pixels (conf<1.1): {avg_low_conf:.1f}%\n"
            f"  cross-frame conf consistency: {'GOOD' if all_conf_stdev < 0.3 else 'NOISY'} "
            f"(stddev {all_conf_stdev:.3f} {'< 0.3' if all_conf_stdev < 0.3 else '>= 0.3'})"
        )
        if args.baseline_conf is not None:
            delta = abs(all_conf_mean - args.baseline_conf)
            print(
                f"  cloud-baseline mean conf: {args.baseline_conf:.3f}\n"
                f"  fidelity vs baseline: |Δ| = {delta:.3f}  "
                f"({'✓ PASS' if delta < 0.5 else '⚠️ DIFF — investigate'})"
            )
        print(f"  output dir: {out_dir.resolve()}")

    return 0


if __name__ == "__main__":
    sys.exit(main())
