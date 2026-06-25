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
