// sift_dog_extrema_test.wgsl — GPU DSP-SIFT Stage-1 fused DoG + strict
// 26-neighbour scale-space extremum TEST (pre-Newton-refine candidate detect).
//
// See third_party/glomap_vendor/GPU_DSP_SIFT_PLAN.md, S1 scope:
//   "gss build + fused DoG + extremum TEST (rest CPU)".
// This kernel is S1 step (a)+(b): it computes the DoG on-the-fly (FUSED, never
// materializes a css buffer) and emits the SET of voxels that pass VLFeat's
// strict 26-neighbour local-extremum test gated by the initial peak threshold.
// Newton subpixel refine + the post-refine |peakScore|/edgeScore gates are S2 /
// CPU downstream — this kernel emits INTEGER voxel coordinates only.
//
// ════════════════════════════════════════════════════════════════════════════
//  VLFeat parity — line-by-line correspondence (covdet.c in
//  third_party/glomap_vendor/colmap-src/thirdparty/VLFeat/covdet.c)
// ════════════════════════════════════════════════════════════════════════════
//
//  (1) DoG response — _vl_dog_response (covdet.c:1897-1907), call site
//      vl_covdet_detect (covdet.c:1965-1970):
//        _vl_dog_response(clevel, level1=gss[o,s+1], level2=gss[o,s])
//        body: dog[k] = level2[k] - level1[k]
//      => css[s] = gss[s] - gss[s+1]   (smaller-sigma MINUS larger-sigma; this
//      is the NEGATIVE of the conventional DoG. The sign is load-bearing: the
//      threshold gate below is signed, so we must subtract in this exact order
//      to land maxima/minima on the same voxels VLFeat does.) Computed fp32
//      in-register here from two gss levels — NEVER stored to a css buffer
//      (PLAN "DoG = adjacent gss subtract, FUSED into S3, never materialize css"
//      + "fp32 discipline: load->subtract in fp32 in-register").
//
//  (2) css scale-space geometry — vl_covdet_detect (covdet.c:1938-1940, 2002):
//        cgeom = gss geom; if (DoG) cgeom.octaveLastSubdivision -= 1
//        depth = octaveLastSubdivision - octaveFirstSubdivision + 1
//      For the default DoG geometry (vl_covdet_put_image covdet.c:1701-1703):
//        gss subdivisions  s in [octaveFirstSubdivision=-1 ..
//                                octaveLastSubdivision=octaveResolution+1=4]  (6 gss levels)
//        css subdivisions  s in [-1 .. octaveResolution=3]                    (5 css levels)
//        depth = 3 - (-1) + 1 = 5
//      The host passes the css depth `D` (number of css levels in this octave)
//      and the per-octave gss levels as a flat buffer. css level index
//      cs in [0 .. D-1] maps to gss level indices (cs, cs+1) in the SAME flat
//      buffer (because css[cs] = gss[cs] - gss[cs+1], and the gss buffer here is
//      laid out 0-based over its own [firstSub .. lastSub] range).
//
//  (3) The strict 26-neighbour extremum test — vl_find_local_extrema_3
//      (covdet.c:1057-1126), driven from vl_covdet_detect (covdet.c:2009-2013)
//      with threshold = 0.8 * peakThreshold:
//        CHECK_NEIGHBORS_3(v,>,+):  v >= +threshold  AND  v > all 26 neighbours
//        CHECK_NEIGHBORS_3(v,<,-):  v <= -threshold  AND  v < all 26 neighbours
//        keep if  ( maxima )  OR  ( minima )
//      NOTE the asymmetry exactly as in VLFeat's CHECK_NEIGHBORS_3 macro
//      (covdet.c:1071-1101): the THRESHOLD comparison is non-strict (`>=`/`<=`
//      via `CMP ## = SGN threshold`) while every NEIGHBOUR comparison is STRICT
//      (`>`/`<`). A plateau (any neighbour equal to v) is therefore rejected —
//      we replicate `>`/`<` (not `>=`/`<=`) on all 26 neighbours.
//      The triple loop bounds (covdet.c:1103-1105) are z in [1,depth-2],
//      y in [1,height-2], x in [1,width-2] — the 1-pixel/1-scale border is
//      never a candidate (its full 3x3x3 neighbourhood would read out of the
//      map). We gate identically: skip any voxel on the spatial or scale border.
//
//  (4) Emitted coordinates — vl_find_local_extrema_3 stores (x,y,z)
//      (covdet.c:1115-1117) as INTEGER voxel indices into the css map; z is the
//      css-local scale index (0-based over the css [firstSub..lastSub] range,
//      i.e. z == s - octaveFirstSubdivision). vl_covdet_detect later maps z back
//      to sigma via cgeom.octaveFirstSubdivision (covdet.c:2028). We emit the
//      same (x, y, z=css-local-level) integers; the host/CPU owns the z->sigma
//      and the Newton refine that turns these into subpixel keypoints.
//
//  Peak threshold value (host-supplied): COLMAP SiftExtractionOptions
//  (colmap/feature/sift.h:54) default peak_threshold = 0.02/octave_resolution
//  = 0.02/3 ~= 0.0066667; VLFeat covdet default (covdet.c:1447,1515) =
//  VL_COVDET_DOG_DEF_PEAK_THRESHOLD = 0.01. The detection pre-gate used here is
//  0.8 * peakThreshold (covdet.c:2013). The host passes the ALREADY-SCALED
//  detection threshold `detect_threshold = 0.8 * peakThreshold` so this kernel
//  does not re-apply the 0.8 (keeps the scaling decision in one place, host-side).
//
// ════════════════════════════════════════════════════════════════════════════
//  OUTPUT INTERFACE (shared with task B — see bench/gpu_extrema_iface.md)
// ════════════════════════════════════════════════════════════════════════════
//  Bindings (@group(0)):
//    binding(0) storage read        gss     : array<f32>   one octave's gss
//                                              levels, flat, row-major, level-major:
//                                              gss[(lvl*H + y)*W + x], lvl in [0..D]
//                                              (D+1 gss levels -> D css levels).
//    binding(1) storage read_write  count   : atomic<u32>  candidate count
//                                              (single u32; caller zero-inits).
//    binding(2) storage read_write  out     : array<CandidateExtremum>
//                                              append target, capacity = P.max_count.
//    binding(3) uniform             P       : Params
//
//  Record layout (matches the task spec exactly):
//    struct CandidateExtremum { octave:u32, level:u32, x:u32, y:u32, dog_value:f32 }
//      octave    = P.octave (this dispatch's octave, echoed for the host)
//      level     = css-local scale index z (0-based; == s - octaveFirstSubdivision)
//      x, y      = integer DoG voxel column / row (the css map coords)
//      dog_value = css[level] at (x,y) = gss[level] - gss[level+1], fp32 (the
//                  pre-refine peak response; lets the host sort / sanity-check
//                  and feed Newton refine without recomputing the subtract).
//    All coords are the DoG VOXEL (pre-refine). The CPU does Newton subpixel
//    refine + |peakScore|/edgeScore gates downstream (S2/CPU).
//
//  Capacity / over-detect cap: the host sizes `out` to P.max_count records and
//  the kernel CAPS appends at P.max_count (PLAN over-detect cap ~24k). The
//  atomic count may exceed max_count (it counts ALL survivors); the host clamps
//  reads to min(count, max_count) and, if count > max_count, knows the buffer
//  saturated (grow + re-dispatch, or accept the cap — the PLAN defers the real
//  8192 clamp to S5a). Writing the full count even when saturated lets the host
//  detect saturation without a second pass.
//
//  Dispatch: one invocation per css voxel. Grid covers (W, H, D): a 3D dispatch
//  with workgroup_size (8,8,1) over ceil(W/8) x ceil(H/8) x D. Border voxels
//  (x/y on the 1px image border, z on the first/last css level) early-out — they
//  can never be candidates (their 3x3x3 neighbourhood is out of map), matching
//  the VLFeat triple-loop interior bounds.
// ════════════════════════════════════════════════════════════════════════════

struct CandidateExtremum {
  octave    : u32,
  level     : u32,   // css-local scale index z (0-based)
  x         : u32,
  y         : u32,
  dog_value : f32,
};

struct Params {
  width        : u32,   // css/gss octave width  (W)
  height       : u32,   // css/gss octave height (H)
  num_css      : u32,   // number of css levels D  (gss levels = D+1)
  octave       : u32,   // echoed into each emitted record
  detect_thr   : f32,   // ALREADY 0.8 * peakThreshold (host applies the 0.8)
  max_count    : u32,   // over-detect cap = capacity of `out` (records)
  _pad0        : u32,
  _pad1        : u32,
};

@group(0) @binding(0) var<storage, read>       gss   : array<f32>;
@group(0) @binding(1) var<storage, read_write> count : atomic<u32>;
@group(0) @binding(2) var<storage, read_write> out   : array<CandidateExtremum>;
@group(0) @binding(3) var<uniform>             P     : Params;

// css voxel = gss[lvl] - gss[lvl+1]   (VLFeat _vl_dog_response sign; see (1)).
// `lvl` is the css-local level index (0-based). Reads two adjacent gss levels
// from the flat per-octave buffer; fp32 in-register, no css materialization.
fn dog_at(x : i32, y : i32, lvl : i32) -> f32 {
  let W : i32 = i32(P.width);
  let H : i32 = i32(P.height);
  let plane : i32 = W * H;
  let idx : i32 = (lvl * H + y) * W + x;        // gss[lvl] at (x,y)
  let a : f32 = gss[idx];                        // gss[lvl]
  let b : f32 = gss[idx + plane];                // gss[lvl+1]
  return a - b;                                  // css[lvl] (smaller - larger sigma)
}

@compute @workgroup_size(8, 8, 1)
fn detect(@builtin(global_invocation_id) gid : vec3<u32>) {
  let W : i32 = i32(P.width);
  let H : i32 = i32(P.height);
  let D : i32 = i32(P.num_css);

  let x : i32 = i32(gid.x);
  let y : i32 = i32(gid.y);
  let z : i32 = i32(gid.z);   // css-local level index

  // Interior-only, exactly VLFeat's triple-loop bounds (covdet.c:1103-1105):
  //   z in [1, depth-2], y in [1, height-2], x in [1, width-2].
  // Border voxels can never be candidates (3x3x3 neighbourhood out of map).
  if (x < 1 || x >= W - 1) { return; }
  if (y < 1 || y >= H - 1) { return; }
  if (z < 1 || z >= D - 1) { return; }

  let v : f32 = dog_at(x, y, z);
  let thr : f32 = P.detect_thr;

  // ── Gather the 26 neighbours across (dx,dy,dz) in {-1,0,+1}^3 \ {0,0,0}. ──
  // Same-scale (dz=0) ring + the two adjacent scales (dz=±1) full 3x3 faces:
  // 8 (same scale) + 9 (z-1) + 9 (z+1) = 26 neighbours (covdet.c:1071-1101).
  // We accumulate the two strict predicates (max: v > all; min: v < all) as we
  // go; both start true, and each neighbour can only falsify one or the other.
  var is_max : bool = (v >= thr);   // threshold gate is NON-strict (>=), see (3)
  var is_min : bool = (v <= -thr);  // threshold gate is NON-strict (<=), see (3)

  // Early-out if neither sign passes the threshold pre-gate (most voxels).
  if (!is_max && !is_min) { return; }

  for (var dz : i32 = -1; dz <= 1; dz = dz + 1) {
    for (var dy : i32 = -1; dy <= 1; dy = dy + 1) {
      for (var dx : i32 = -1; dx <= 1; dx = dx + 1) {
        if (dx == 0 && dy == 0 && dz == 0) { continue; }  // skip center
        let nb : f32 = dog_at(x + dx, y + dy, z + dz);
        // STRICT neighbour comparison (covdet.c CHECK_NEIGHBORS_3 uses `>`/`<`,
        // NOT `>=`/`<=`): a plateau (nb == v) falsifies BOTH, rejecting it.
        if (!(v > nb)) { is_max = false; }
        if (!(v < nb)) { is_min = false; }
      }
    }
  }

  if (!is_max && !is_min) { return; }

  // Survivor: atomic-append. Count ALL survivors (so the host can detect
  // saturation), but only WRITE within the over-detect cap.
  let slot : u32 = atomicAdd(&count, 1u);
  if (slot < P.max_count) {
    out[slot] = CandidateExtremum(
      P.octave,
      u32(z),
      u32(x),
      u32(y),
      v,
    );
  }
}
