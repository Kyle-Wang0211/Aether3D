#!/usr/bin/env python
"""
Extract N evenly-spaced curated frames from a capture .mov using the
.curated.json metadata (video_timestamp_sec per curated frame).

Usage:
    python extract_curated_frames.py <mov> <curated_json> <out_dir> [--n 6]
"""
from __future__ import annotations

import argparse
import json
import subprocess
import sys
from pathlib import Path


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("mov")
    parser.add_argument("curated_json")
    parser.add_argument("out_dir")
    parser.add_argument("--n", type=int, default=6)
    args = parser.parse_args()

    out_dir = Path(args.out_dir)
    out_dir.mkdir(parents=True, exist_ok=True)

    with open(args.curated_json) as f:
        data = json.load(f)
    frames = data["frames"]
    total = len(frames)
    print(f"[extract] curated.json has {total} frames")

    if total < args.n:
        # Use all curated frames
        sample_idx = list(range(total))
    else:
        # Evenly spaced, 0 + last + middle steps
        sample_idx = [round(i * (total - 1) / (args.n - 1)) for i in range(args.n)]

    print(f"[extract] sampling indices: {sample_idx}")

    for out_i, frame_idx in enumerate(sample_idx):
        frame = frames[frame_idx]
        ts = frame["video_timestamp_sec"]
        uuid = frame["frame_uuid"][:8]
        out_path = out_dir / f"frame_{out_i:02d}_idx{frame_idx:03d}_t{ts:.3f}.jpg"

        # ffmpeg with seek BEFORE input is fast but less accurate.
        # For accuracy, put -ss AFTER -i. We want both fast + accurate
        # so use -ss before -i for fast seek to keyframe, then -ss again
        # after if needed. For our purposes, fast seek is fine since
        # we're picking sample frames, not exact ones.
        cmd = [
            "ffmpeg", "-y",
            "-ss", f"{ts:.4f}",
            "-i", args.mov,
            "-frames:v", "1",
            "-q:v", "2",  # high quality JPEG
            str(out_path),
        ]
        print(f"[extract] frame {out_i+1}/{len(sample_idx)} idx={frame_idx} ts={ts:.3f}s uuid={uuid}")
        result = subprocess.run(cmd, capture_output=True, text=True)
        if result.returncode != 0:
            print(f"  ERROR: ffmpeg failed: {result.stderr[-300:]}", file=sys.stderr)
            return 1
        size_kb = out_path.stat().st_size / 1024
        print(f"  → {out_path.name} ({size_kb:.0f} KB)")

    print(f"\n[extract] DONE. {len(sample_idx)} frames in {out_dir}/")
    return 0


if __name__ == "__main__":
    sys.exit(main())
