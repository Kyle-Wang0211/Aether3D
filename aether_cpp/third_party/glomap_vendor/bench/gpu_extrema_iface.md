# GPU DoG + extremum-test output interface (S1)

Shared contract between `shaders/wgsl/sift_dog_extrema_test.wgsl` (task A,
produces) and the downstream GPU compaction / Newton-refine (task B / S2,
consumes). The same record layout is documented at the top of the .wgsl; this
file is the canonical short reference.

## What the kernel does

For each css (DoG) voxel of ONE octave, the `detect` entry point:

1. Computes the DoG on-the-fly, **fused**, fp32 in-register (no css buffer is
   ever materialized): `css[lvl] = gss[lvl] - gss[lvl+1]`.
   This is VLFeat's sign (`_vl_dog_response`, `covdet.c:1905`,
   `dog = level2 - level1` with `level2 = gss[s]`, `level1 = gss[s+1]`), i.e.
   smaller-sigma minus larger-sigma — the negative of the conventional DoG. The
   sign is load-bearing because the threshold gate is signed.
2. Tests the strict 26-neighbour scale-space extremum criterion
   (`vl_find_local_extrema_3`, `covdet.c:1057-1126`):
   - maxima: `v >= +detect_thr` AND `v >` all 26 neighbours
   - minima: `v <= -detect_thr` AND `v <` all 26 neighbours
   - threshold comparison is **non-strict** (`>=`/`<=`); neighbour comparison is
     **strict** (`>`/`<`) — a plateau is rejected. Matches the
     `CHECK_NEIGHBORS_3` macro exactly.
   - interior-only: `z in [1,D-2]`, `y in [1,H-2]`, `x in [1,W-2]` (the
     `covdet.c:1103-1105` triple-loop bounds; borders early-out).
3. Appends each survivor to `out` via an `atomic<u32>` count.

The kernel does **not** Newton-refine and does **not** apply the post-refine
`|peakScore| > peakThreshold` / `edgeScore < edgeThreshold` gates — those are
S2/CPU. Emitted coords are the integer DoG voxel (pre-refine).

## Bindings (`@group(0)`)

| binding | kind                      | name    | contents |
|---------|---------------------------|---------|----------|
| 0       | `storage, read`           | `gss`   | one octave's gss levels, flat, row-major, level-major: `gss[(lvl*H + y)*W + x]`, `lvl in [0..D]` — **D+1 gss levels** produce **D css levels**. fp32. |
| 1       | `storage, read_write`     | `count` | single `atomic<u32>`; caller **zero-inits** before dispatch. |
| 2       | `storage, read_write`     | `out`   | `array<CandidateExtremum>`, capacity = `P.max_count` records. |
| 3       | `uniform`                 | `P`     | `Params` (below). |

## Record layout

```wgsl
struct CandidateExtremum {
  octave    : u32,   // P.octave, echoed for the host
  level     : u32,   // css-local scale index z (0-based; == s - octaveFirstSubdivision)
  x         : u32,   // integer DoG voxel column
  y         : u32,   // integer DoG voxel row
  dog_value : f32,   // css[level] at (x,y) = gss[level]-gss[level+1], fp32 (pre-refine peak response)
};   // 20 bytes, std430 (5 x 4-byte scalars, naturally aligned)
```

## Params (uniform)

```wgsl
struct Params {
  width      : u32,  // W: css/gss octave width
  height     : u32,  // H: css/gss octave height
  num_css    : u32,  // D: number of css levels (gss levels = D+1)
  octave     : u32,  // echoed into each record
  detect_thr : f32,  // ALREADY 0.8 * peakThreshold (host applies the 0.8)
  max_count  : u32,  // over-detect cap = capacity of `out` in records
  _pad0      : u32,
  _pad1      : u32,
};
```

`detect_thr` is the **already-scaled** detection threshold `0.8 * peakThreshold`
(`covdet.c:2013`). The host applies the `0.8` so the scaling lives in one place.
COLMAP default `peakThreshold = 0.02/octave_resolution = 0.02/3 ~= 0.0066667`
(`colmap/feature/sift.h:54`); VLFeat covdet default = `0.01` (`covdet.c:1447`).

## Dispatch

One invocation per css voxel. 3D dispatch, `workgroup_size(8,8,1)`, grid =
`ceil(W/8) x ceil(H/8) x D`. The kernel early-outs on border voxels, so over-
covering z to `D` (rather than `D-2`) is harmless (those invocations return).

## Semantics / cap

- Coords are the integer **DoG voxel** (pre-refine). CPU/S2 does Newton subpixel
  refine + `|peakScore|`/`edgeScore` gates downstream.
- `level` (z) is css-local (0-based). The host maps z -> sigma via
  `octaveFirstSubdivision` (`covdet.c:2027-2029`): `s = z + octaveFirstSubdivision`.
- `count` counts **all** survivors (may exceed `max_count`). `out` is written
  only for `slot < max_count`. If `count > max_count` the buffer **saturated**:
  the host clamps reads to `min(count, max_count)` and may grow + re-dispatch.
  The PLAN's over-detect cap is ~24k; the real 8192 clamp is deferred to S5a.

## Per-octave invocation pattern (host)

The kernel processes ONE octave. The host loops octaves: for each, it makes the
octave's `D+1` gss levels resident as the flat `gss` buffer, sets `P.octave`,
zero-inits a shared `count`, and dispatches. `out` is appended across octaves
(the atomic count is shared), so the final `out[0..min(count,max_count))` is the
full multi-octave candidate set. (In S1 the gss is already resident from the
gss-build kernels; this kernel re-reads it — the PLAN's "gss resident, re-read
~4x".)

---

# S2 — Newton refine + peak/edge gate output interface

Shared contract between `shaders/wgsl/sift_refine_gate.wgsl` (S2, produces) and
downstream (task B / S3 descriptor + sort). S2 CONSUMES the S1
`CandidateExtremum` buffer above and PRODUCES a dense `Keypoint` survivor buffer.

## What the S2 kernel does

One invocation per S1 `CandidateExtremum` (1D dispatch, `workgroup_size(64)`,
`ceil(num_cands/64)` workgroups; invocations past `num_cands` early-out). Each
lane:
1. Reads its candidate's integer voxel `(octave, level=z, x, y)`.
2. Newton subpixel-refines on the DoG (recomputed fp32-in-register from the
   resident gss, `css=gss[lvl]-gss[lvl+1]`) — `vl_refine_local_extreum_3`
   (covdet.c:1206-1318): ≤5 iters, 3×3×3 gradient/Hessian, 3×3 Gauss-elim solve
   with partial pivoting (`vl_solve_linear_system_3`/`vl_gaussian_elimination`,
   mathop.c:839-1008), x/y relocation when `|offset|>0.6`, accept if `err==OK &&
   |b|<1.5 && refined in [0,dim-1]`.
3. Applies the peak gate `|peakScore| > peakThreshold` (covdet.c:2024) and the
   edge gate `edgeScore < edgeThreshold` (covdet.c:2025).
4. Survivors atomic-append to the dense `out_kp` buffer via a shared
   `atomic<u32>` (compaction = atomic, NOT scan/scatter — the S1 candidates are
   already dense; see the kernel header for the justification).

## S2 bindings (`@group(0)`)

| binding | kind | name | contents |
|---|---|---|---|
| 0 | `storage, read` | `gss` | one octave's gss levels, flat level-major (same buffer S1 consumes). fp32. |
| 1 | `storage, read` | `cands` | `array<CandidateExtremum>` — the S1 candidates for THIS octave. |
| 2 | `storage, read_write` | `out_count` | single `atomic<u32>` survivor count; caller **zero-inits ONCE** (shared across octaves for a dense multi-octave output). |
| 3 | `storage, read_write` | `out_kp` | `array<Keypoint>`, capacity = `P.max_kp` records. |
| 4 | `uniform` | `P` | `RefineParams` (below). |

## S2 output record layout

```wgsl
struct Keypoint {
  x_local    : f32,   // refined subpixel x in octave-local css coords (refined.x)
  y_local    : f32,   // refined subpixel y in octave-local css coords (refined.y)
  z_local    : f32,   // refined subpixel css-local scale (refined.z, 0-based)
  octave     : u32,   // detection octave o
  sigma      : f32,   // baseScale * 2^(o + (z_local + first_sub)/octave_res)
  step       : f32,   // per-octave step
  peak_score : f32,   // refined.peakScore (signed)
  edge_score : f32,   // refined.edgeScore
};   // 48 bytes, std430 (8 x 4-byte scalars)
```

Image-frame conversion (host / S3, COLMAP sift.cc:422-423):
`frame.x = x_local*step + 0.5`, `frame.y = y_local*step + 0.5`. The affine frame
is isotropic-`sigma` at detection (a11=a22=sigma, a12=a21=0); S4 affine-shape +
orientation replace it later. `z_local` is css-local (add `first_sub` for the
gss subdivision; `feature.s = round(z_local + first_sub)` for the COLMAP sort
key, covdet.c:2037).

## S2 Params (uniform)

```wgsl
struct RefineParams {
  width, height : u32,   // W, H octave dims
  num_css       : u32,   // D css levels (gss levels = D+1)
  num_cands     : u32,   // S1 candidate count for this octave
  peak_thr      : f32,   // FULL peakThreshold (post-refine gate; NOT the 0.8x)
  edge_thr      : f32,   // edgeThreshold (default 10.0)
  base_scale    : f32,   // cgeom.baseScale
  step          : f32,   // octave geometry .step
  first_sub     : i32,   // octaveFirstSubdivision (default -1)
  octave_res    : f32,   // octaveResolution (default 3)
  max_kp        : u32,   // out_kp capacity (records)
  _pad0         : u32,
};
```

## S2 cap / saturation / NOT-yet-applied

- `out_count` counts ALL survivors; `out_kp` is written only for
  `slot < max_kp`. Host clamps reads to `min(out_count, max_kp)`.
- **nonExtremaSuppression (covdet.c:2104, =0.5 ON by VLFeat default, NOT disabled
  by COLMAP) is NOT applied in this kernel.** It is a GLOBAL O(N²) pass over the
  final frame-space feature list (suppress a kp if a stronger one sits within
  `tol*sigma` spatially and `(1+tol)` in scale) — not expressible per-candidate.
  Deferred to a host post-pass / later GPU stage. On the 4224×2376 test image it
  removes ~1.4% of survivors (26783 → 26416 at COLMAP defaults). The S5a sort +
  8192 clamp is also deferred (PLAN).

## S2 measured parity (extract_gpuparity.cc `--refine`, M-series host Dawn)

Validated vs VLFeat's OWN `vl_refine_local_extreum_3` + gates on the byte-
identical CPU css (isolates the kernel from gss-build error). sift_test.jpg
4224×2376, COLMAP defaults (peak=0.02/3, edge=10):
- **fo0**: 26783 survivors, recall=precision=**1.000000**, median pos-err
  **0.000000px**, mean 0.000031px, p99 0.000252px, max 0.314px (1 of 26783
  >0.05px = 0.0037% — a single fp32-vs-double Newton divergence). Per-octave
  survivor counts bit-match VLFeat.
- **fo−1**: 122738 survivors, recall=precision=1.000000, median 0px, max
  **0.0026px**, **0 of 122738 >0.05px**.
- **edge_threshold=5** (stress the edge gate): precision 0.999952 — exactly 1 of
  20686 GPU survivors disagreed at the edge boundary (fp32 edgeScore vs double),
  the documented near-edge fp32-fragile decision.
- All cases PASS the S2 gate (recall/precision ≥0.97, median pos-err ≤0.05px).
