#!/usr/bin/env python3
"""Generate synthetic_smoke.ply — 100 deterministic Gaussians for Phase 6 dev iteration.

Per Phase 6 v2 plan (decision B): a tiny, deterministic 3DGS scene that loads in
< 100 ms so the inner loop of "tweak shader → reload → see result" stays fast.
Mip-NeRF 360 garden takes seconds + hundreds of MB; this loads instantly.

Layout: 5×5×4 grid (100 Gaussians) of opaque colored splats, SH degree 0
(DC color only), unit-axis-aligned scales, no rotation.

Output goes to stdout (redirect to file). Run from repo root:

    python3 scripts/gen_synthetic_smoke_ply.py \\
        > aether_cpp/test_data/splat/synthetic_smoke.ply

The output format follows the standard 3DGS .ply convention used by:
  - INRIA's gaussian-splatting reference impl
  - Brush
  - MetalSplatter
  - gsplat-rs
  - Polycam exports

Float32 little-endian throughout. Per-Gaussian fields:
  position (x, y, z)               — 3 floats
  normal (nx, ny, nz)              — 3 floats (set to 0; unused by viewers)
  DC color (f_dc_0, f_dc_1, f_dc_2) — 3 floats (SH degree 0)
  opacity                          — 1 float (logit of opacity)
  scale (scale_0, scale_1, scale_2) — 3 floats (log-scale)
  rotation (q_w, q_x, q_y, q_z)    — 4 floats (unit quaternion)
                                   = 17 floats / 68 bytes per Gaussian.

Color is derived from grid position: x → red, y → green, z → blue, all in [0.2, 1.0].
SH-degree-0 DC color in 3DGS .ply is stored in [-2.0, 2.0]-ish range
(Brush/INRIA convention: linear color ≈ DC * SH_C0 + 0.5 where SH_C0 ≈ 0.282);
we just store sensible DC values that decode to vivid grid colors.
"""

import struct
import sys

GRID_X, GRID_Y, GRID_Z = 5, 5, 4
TOTAL = GRID_X * GRID_Y * GRID_Z  # 100
SPACING = 0.4  # world-units between grid points
SCALE_LOG = -3.0  # exp(-3) ≈ 0.05 world units per axis (small-ish blobs)
OPACITY_LOGIT = 1.4  # sigmoid(1.4) ≈ 0.80


def emit_header():
    fields = [
        ("x", "float"), ("y", "float"), ("z", "float"),
        ("nx", "float"), ("ny", "float"), ("nz", "float"),
        ("f_dc_0", "float"), ("f_dc_1", "float"), ("f_dc_2", "float"),
        ("opacity", "float"),
        ("scale_0", "float"), ("scale_1", "float"), ("scale_2", "float"),
        ("rot_0", "float"), ("rot_1", "float"), ("rot_2", "float"), ("rot_3", "float"),
    ]
    sys.stdout.write("ply\n")
    sys.stdout.write("format binary_little_endian 1.0\n")
    sys.stdout.write(
        "comment synthetic_smoke for Phase 6 dev iteration "
        "(deterministic 5x5x4 grid; see scripts/gen_synthetic_smoke_ply.py)\n"
    )
    sys.stdout.write(f"element vertex {TOTAL}\n")
    for name, ty in fields:
        sys.stdout.write(f"property {ty} {name}\n")
    sys.stdout.write("end_header\n")
    sys.stdout.flush()


def emit_body():
    # Switch to binary mode for the body.
    out = sys.stdout.buffer
    for ix in range(GRID_X):
        for iy in range(GRID_Y):
            for iz in range(GRID_Z):
                # Position: centered grid, [-2, +2] x-range, [-2, +2] y-range, [-1.5, +1.5] z-range
                x = (ix - (GRID_X - 1) * 0.5) * SPACING
                y = (iy - (GRID_Y - 1) * 0.5) * SPACING
                z = (iz - (GRID_Z - 1) * 0.5) * SPACING

                # Normal — unused by viewers, write zero. Some old viewers expect non-zero,
                # so write a unit-z fallback. Doesn't affect Gaussian rendering.
                nx, ny, nz = 0.0, 0.0, 1.0

                # DC color (SH degree 0). Linearly map grid position to RGB via
                # DC = (rgb - 0.5) / SH_C0 where SH_C0 = 0.282094791773878
                # Using simpler convention: direct DC values producing visible colors.
                # The 3DGS pipeline applies: rgb = DC * SH_C0 + 0.5 → DC = (rgb - 0.5) / SH_C0
                SH_C0 = 0.282094791773878
                r_lin = 0.2 + 0.8 * (ix / max(GRID_X - 1, 1))
                g_lin = 0.2 + 0.8 * (iy / max(GRID_Y - 1, 1))
                b_lin = 0.2 + 0.8 * (iz / max(GRID_Z - 1, 1))
                dc0 = (r_lin - 0.5) / SH_C0
                dc1 = (g_lin - 0.5) / SH_C0
                dc2 = (b_lin - 0.5) / SH_C0

                opacity = OPACITY_LOGIT  # logit; viewer applies sigmoid

                # Scale: log-space, identical on all 3 axes → small spheres
                s0 = s1 = s2 = SCALE_LOG

                # Rotation: identity quaternion (w, x, y, z) = (1, 0, 0, 0)
                qw, qx, qy, qz = 1.0, 0.0, 0.0, 0.0

                packed = struct.pack(
                    "<17f",
                    x, y, z,
                    nx, ny, nz,
                    dc0, dc1, dc2,
                    opacity,
                    s0, s1, s2,
                    qw, qx, qy, qz,
                )
                out.write(packed)


def main() -> int:
    emit_header()
    emit_body()
    return 0


if __name__ == "__main__":
    sys.exit(main())
