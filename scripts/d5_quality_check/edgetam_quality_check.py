#!/usr/bin/env python
"""
W2 D1 mask quality verification — Mac-side EdgeTAM 3-stage CoreML inference + viz.

For each RGB frame in the input dir:
  1. Resize to 1024×1024 (EdgeTAM image_encoder input size).
  2. Stage 1: image_encoder → vision_features, high_res_feat_0, high_res_feat_1.
  3. Stage 2: prompt_encoder with single-point prompt at image center (dome
     capture convention: subject is always centered).
  4. Stage 3: mask_decoder → 3 mask hypotheses (256×256) + 3 IoU predictions.
  5. Pick best hypothesis by IoU, apply sigmoid → [0, 1] foreground probability.
  6. Render mask + alpha overlay on original frame.

Then generate a multi-frame grid PNG: rows = frames, cols = [original, mask
heatmap, overlay].

Matches the iOS Swift EdgeTAMWrapper exactly (same prompt point default,
same hypothesis selection, same sigmoid). Used for off-device quality
validation on real dome captures before/after EdgeTAM CoreML conversion
sanity-check.

Usage:
    python edgetam_quality_check.py <frames_dir> [--out OUT_DIR] [--max-frames N]

Outputs (under OUT_DIR, default ./edgetam_quality_out/):
    frame_<idx>_mask.png      — 256×256 grayscale mask probability
    frame_<idx>_overlay.png   — original + red-tinted mask overlay
    grid_summary.png          — multi-frame grid (original | mask | overlay per row)
    stats.json                — per-frame stats (foreground%, IoU, timings)
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

# ── Constants matching Swift EdgeTAMWrapper exactly ─────────────────────────
INPUT_SIZE = 1024     # image_encoder input dim
EMBED_SPATIAL = 64    # vision_features H/W
EMBED_DIM = 256
MASK_OUT_SIZE = 256   # mask_decoder output
N_HYPOTHESES = 3      # SAM 2 mask decoder hypothesis count

DEFAULT_MODEL_DIR = Path(
    "/Users/kaidongwang/Developer/Aether3D-cross/pocketworld_flutter/ios/"
    "Runner/Models/EdgeTAM-CoreML"
)


# ── Image preprocessing ────────────────────────────────────────────────────


def preprocess_image_for_encoder(img: Image.Image) -> Image.Image:
    """Resize to 1024×1024 RGB. CoreML image_encoder handles normalization
    internally (per the conversion spec)."""
    return img.convert("RGB").resize((INPUT_SIZE, INPUT_SIZE), Image.BILINEAR)


# ── Helpers for fp16 model I/O ──────────────────────────────────────────────


def to_fp32(arr) -> np.ndarray:
    """coremltools may return fp16 ndarrays for fp16-precision models."""
    return np.asarray(arr).astype(np.float32)


# ── image_pe load ────────────────────────────────────────────────────────────


def load_image_pe(bin_path: Path) -> np.ndarray:
    """4 MB fp32 file → (1, 256, 64, 64) ndarray. EdgeTAM bundles the positional
    encoding offline because the prompt_encoder doesn't emit it."""
    raw = np.fromfile(str(bin_path), dtype=np.float32)
    expected = 1 * EMBED_DIM * EMBED_SPATIAL * EMBED_SPATIAL
    if raw.size != expected:
        raise ValueError(
            f"image_pe.bin size mismatch: got {raw.size}, expected {expected}"
        )
    return raw.reshape((1, EMBED_DIM, EMBED_SPATIAL, EMBED_SPATIAL))


# ── EdgeTAM 3-stage inference ───────────────────────────────────────────────


def infer_frame(
    image_path: Path,
    image_encoder: ct.models.MLModel,
    prompt_encoder: ct.models.MLModel,
    mask_decoder: ct.models.MLModel,
    image_pe: np.ndarray,
) -> dict:
    img_pil = Image.open(image_path).convert("RGB")
    orig_w, orig_h = img_pil.size

    # Stage 1: image encoder.
    img_1024 = preprocess_image_for_encoder(img_pil)
    t0 = time.time()
    enc_out = image_encoder.predict({"image": img_1024})
    enc_ms = (time.time() - t0) * 1000.0
    vision_features = to_fp32(enc_out["vision_features"])
    high_res_feat_0 = to_fp32(enc_out["high_res_feat_0"])
    high_res_feat_1 = to_fp32(enc_out["high_res_feat_1"])

    # Stage 2: prompt encoder. Default prompt = image center mapped to 1024 coords.
    prompt_x = INPUT_SIZE / 2.0
    prompt_y = INPUT_SIZE / 2.0
    point_coords = np.zeros((1, 4, 2), dtype=np.float32)
    point_coords[0, 0, 0] = prompt_x
    point_coords[0, 0, 1] = prompt_y
    point_labels = np.zeros((1, 4), dtype=np.float32)
    point_labels[0, 0] = 1.0   # foreground
    point_labels[0, 1] = -1.0  # ignore
    point_labels[0, 2] = -1.0
    point_labels[0, 3] = -1.0
    boxes = np.zeros((1, 4), dtype=np.float32)
    mask_input = np.zeros((1, 1, MASK_OUT_SIZE, MASK_OUT_SIZE), dtype=np.float32)

    t0 = time.time()
    prompt_out = prompt_encoder.predict({
        "point_coords": point_coords,
        "point_labels": point_labels,
        "boxes": boxes,
        "mask_input": mask_input,
    })
    prompt_ms = (time.time() - t0) * 1000.0
    sparse_embeddings = to_fp32(prompt_out["sparse_embeddings"])  # (1, 5, 256)
    dense_embeddings = to_fp32(prompt_out["dense_embeddings"])    # (1, 256, 64, 64)

    # Slice sparse to (1, 1, 256) — first sparse embedding = the single point.
    sparse_first = sparse_embeddings[:, :1, :]

    # Stage 3: mask decoder.
    multimask_flag = np.array([1.0], dtype=np.float32)
    t0 = time.time()
    dec_out = mask_decoder.predict({
        "image_embeddings": vision_features,
        "image_pe": image_pe,
        "sparse_prompt_embeddings": sparse_first,
        "dense_prompt_embeddings": dense_embeddings,
        "high_res_feat_0": high_res_feat_0,
        "high_res_feat_1": high_res_feat_1,
        "multimask_output": multimask_flag,
    })
    dec_ms = (time.time() - t0) * 1000.0
    masks_logits = to_fp32(dec_out["masks"])    # (1, 3, 256, 256)
    iou_pred = to_fp32(dec_out["iou_pred"]).reshape(-1)  # (3,)

    # Pick best hypothesis by IoU.
    best_idx = int(np.argmax(iou_pred))
    best_iou = float(iou_pred[best_idx])

    # Extract chosen plane + sigmoid (numerically stable form, matches C++).
    plane = masks_logits[0, best_idx]  # (256, 256)
    pos = plane >= 0
    mask = np.zeros_like(plane)
    mask[pos] = 1.0 / (1.0 + np.exp(-plane[pos]))
    neg = ~pos
    ex = np.exp(plane[neg])
    mask[neg] = ex / (1.0 + ex)

    fg_pct = float(np.sum(mask > 0.5)) / mask.size * 100.0
    mean_prob = float(mask.mean())
    max_prob = float(mask.max())

    return {
        "image_path": str(image_path),
        "orig_w": orig_w,
        "orig_h": orig_h,
        "enc_ms": enc_ms,
        "prompt_ms": prompt_ms,
        "dec_ms": dec_ms,
        "iou_pred": [float(v) for v in iou_pred],
        "best_idx": best_idx,
        "best_iou": best_iou,
        "fg_pct": fg_pct,
        "mean_prob": mean_prob,
        "max_prob": max_prob,
        "mask": mask,           # (256, 256) fp32 [0, 1]
        "img_pil": img_pil,     # original for overlay
    }


# ── Visualization ────────────────────────────────────────────────────────────


def save_mask_grayscale(mask: np.ndarray, out_path: Path) -> None:
    """Save mask as grayscale PNG. mask values [0, 1] → uint8 [0, 255]."""
    norm = (mask * 255.0).clip(0, 255).astype(np.uint8)
    Image.fromarray(norm, mode="L").save(out_path)


def save_overlay(img: Image.Image, mask: np.ndarray, out_path: Path,
                 alpha: float = 0.45) -> None:
    """Overlay red-tinted mask on original image. Mask is 256×256; resize to
    image dims (nearest) for the overlay (final dome capture pipeline will
    use bilinear via aether_bilinear_resize, but for viz purposes nearest is
    fine — the qualitative subject region remains clear)."""
    orig_w, orig_h = img.size
    mask_img = Image.fromarray(
        (mask * 255.0).clip(0, 255).astype(np.uint8), mode="L"
    ).resize((orig_w, orig_h), Image.BILINEAR)
    rgb = img.convert("RGB")
    rgb_arr = np.asarray(rgb, dtype=np.float32)
    mask_arr = np.asarray(mask_img, dtype=np.float32) / 255.0
    # Red tint where mask is high.
    red_tint = np.zeros_like(rgb_arr)
    red_tint[..., 0] = 255.0
    blended = rgb_arr * (1.0 - alpha * mask_arr[..., None]) \
        + red_tint * (alpha * mask_arr[..., None])
    out = blended.clip(0, 255).astype(np.uint8)
    Image.fromarray(out, mode="RGB").save(out_path)


def render_grid_summary(results: list[dict], out_path: Path) -> None:
    """N-row × 3-col grid: rows=frames, cols=[original 1920x1080, mask 256x256, overlay]."""
    n = len(results)
    fig_h = 2.0 * n
    fig, axes = plt.subplots(n, 3, figsize=(10, fig_h))
    if n == 1:
        axes = axes[np.newaxis, :]

    for i, res in enumerate(results):
        frame_name = Path(res["image_path"]).stem

        # Col 0: original.
        axes[i, 0].imshow(res["img_pil"])
        axes[i, 0].axis("off")
        axes[i, 0].set_title(f"{frame_name}", fontsize=9)

        # Col 1: mask heatmap (viridis, comparable to DA3 conf viz convention).
        im = axes[i, 1].imshow(res["mask"], cmap="viridis", vmin=0, vmax=1)
        axes[i, 1].axis("off")
        axes[i, 1].set_title(
            f"mask 256×256  IoU={res['best_iou']:.3f}  fg={res['fg_pct']:.1f}%",
            fontsize=9,
        )
        plt.colorbar(im, ax=axes[i, 1], fraction=0.046, pad=0.04)

        # Col 2: overlay on resized-down original (for readability in grid).
        orig_w, orig_h = res["img_pil"].size
        mask_resized = np.asarray(
            Image.fromarray(
                (res["mask"] * 255.0).clip(0, 255).astype(np.uint8), mode="L"
            ).resize((orig_w, orig_h), Image.BILINEAR),
            dtype=np.float32,
        ) / 255.0
        rgb_arr = np.asarray(res["img_pil"].convert("RGB"), dtype=np.float32)
        red_tint = np.zeros_like(rgb_arr)
        red_tint[..., 0] = 255.0
        alpha = 0.45
        blended = rgb_arr * (1.0 - alpha * mask_resized[..., None]) \
            + red_tint * (alpha * mask_resized[..., None])
        axes[i, 2].imshow(blended.clip(0, 255).astype(np.uint8))
        axes[i, 2].axis("off")
        axes[i, 2].set_title("subject mask overlay (red)", fontsize=9)

    fig.suptitle(
        "W2 D1 — EdgeTAM mask on real PocketWorld dome capture (center prompt)",
        fontsize=11,
    )
    plt.tight_layout(rect=[0, 0, 1, 0.97])
    plt.savefig(out_path, dpi=120, bbox_inches="tight", facecolor="white")
    plt.close(fig)


# ── Main ─────────────────────────────────────────────────────────────────────


def main() -> int:
    parser = argparse.ArgumentParser(
        description="EdgeTAM batch mask inference + viz on real RGB frames."
    )
    parser.add_argument("frames_dir", help="Directory containing .jpg/.png frames")
    parser.add_argument("--out", default="./edgetam_quality_out", help="Output dir")
    parser.add_argument(
        "--max-frames", type=int, default=6,
        help="Max frames to process (default 6, matches DA3 quality grid)",
    )
    parser.add_argument(
        "--compute-units", default="cpuOnly",
        choices=["cpuOnly", "cpuAndGPU", "cpuAndNeuralEngine", "ALL"],
    )
    parser.add_argument("--model-dir", default=str(DEFAULT_MODEL_DIR))
    args = parser.parse_args()

    frames_dir = Path(args.frames_dir)
    out_dir = Path(args.out)
    out_dir.mkdir(parents=True, exist_ok=True)

    frames = sorted([
        p for p in frames_dir.iterdir()
        if p.suffix.lower() in {".jpg", ".jpeg", ".png"}
    ])
    if not frames:
        print(f"[EdgeTAM-D5] no frames in {frames_dir}", file=sys.stderr)
        return 1
    print(f"[EdgeTAM-D5] found {len(frames)} frames in {frames_dir}")

    if len(frames) > args.max_frames:
        idxs = np.linspace(0, len(frames) - 1, args.max_frames, dtype=int)
        frames = [frames[i] for i in idxs]
        print(f"[EdgeTAM-D5] subsampled to {len(frames)} frames: "
              f"{[f.name for f in frames]}")

    model_dir = Path(args.model_dir)
    cu_map = {
        "cpuOnly": ct.ComputeUnit.CPU_ONLY,
        "cpuAndGPU": ct.ComputeUnit.CPU_AND_GPU,
        "cpuAndNeuralEngine": ct.ComputeUnit.CPU_AND_NE,
        "ALL": ct.ComputeUnit.ALL,
    }
    cu = cu_map[args.compute_units]
    print(f"[EdgeTAM-D5] loading 3-stage EdgeTAM from {model_dir} "
          f"(compute_units={args.compute_units})")

    t_load = time.time()
    image_encoder = ct.models.MLModel(
        str(model_dir / "edgetam_image_encoder.mlpackage"), compute_units=cu
    )
    prompt_encoder = ct.models.MLModel(
        str(model_dir / "edgetam_prompt_encoder.mlpackage"), compute_units=cu
    )
    mask_decoder = ct.models.MLModel(
        str(model_dir / "edgetam_mask_decoder.mlpackage"), compute_units=cu
    )
    image_pe = load_image_pe(model_dir / "edgetam_image_pe.float32.bin")
    print(f"[EdgeTAM-D5] 3 models + image_pe loaded in {time.time() - t_load:.2f}s")

    results: list[dict] = []
    for i, frame_path in enumerate(frames):
        print(f"[EdgeTAM-D5] [{i + 1}/{len(frames)}] {frame_path.name}", flush=True)
        try:
            res = infer_frame(
                frame_path, image_encoder, prompt_encoder, mask_decoder, image_pe
            )
        except Exception as e:
            print(f"[EdgeTAM-D5] FAILED on {frame_path.name}: {e}",
                  file=sys.stderr)
            continue
        results.append(res)
        print(
            f"[EdgeTAM-D5]   enc {res['enc_ms']:.0f}ms  prompt {res['prompt_ms']:.0f}ms  "
            f"dec {res['dec_ms']:.0f}ms  IoU=[{res['iou_pred'][0]:.3f}, "
            f"{res['iou_pred'][1]:.3f}, {res['iou_pred'][2]:.3f}]  "
            f"picked {res['best_idx']} ({res['best_iou']:.3f})  "
            f"fg {res['fg_pct']:.1f}%  mean_prob {res['mean_prob']:.3f}"
        )

        # Per-frame artifacts.
        mask_out = out_dir / f"frame_{i:02d}_{frame_path.stem}_mask.png"
        overlay_out = out_dir / f"frame_{i:02d}_{frame_path.stem}_overlay.png"
        save_mask_grayscale(res["mask"], mask_out)
        save_overlay(res["img_pil"], res["mask"], overlay_out)

    if results:
        grid_path = out_dir / "grid_summary.png"
        render_grid_summary(results, grid_path)
        print(f"[EdgeTAM-D5] wrote grid summary → {grid_path}")

    stats = []
    for res in results:
        s = {k: v for k, v in res.items() if k not in {"mask", "img_pil"}}
        stats.append(s)
    stats_path = out_dir / "stats.json"
    stats_path.write_text(json.dumps(stats, indent=2))
    print(f"[EdgeTAM-D5] wrote stats → {stats_path}")

    if results:
        mean_iou = float(np.mean([r["best_iou"] for r in results]))
        mean_fg = float(np.mean([r["fg_pct"] for r in results]))
        mean_enc = float(np.mean([r["enc_ms"] for r in results]))
        mean_dec = float(np.mean([r["dec_ms"] for r in results]))
        print(
            f"\n[EdgeTAM-D5] ======== W2 D1 EdgeTAM mask quality summary ========\n"
            f"  frames processed: {len(results)} / {len(frames)}\n"
            f"  avg picked IoU:   {mean_iou:.3f}  (lower = SAM 2 less confident; "
            f"dome capture without explicit prompt expects ~0.5-0.8)\n"
            f"  avg foreground %: {mean_fg:.1f}\n"
            f"  avg enc/dec ms:   {mean_enc:.0f} / {mean_dec:.0f}\n"
            f"  output dir:       {out_dir.resolve()}"
        )

    return 0


if __name__ == "__main__":
    sys.exit(main())
