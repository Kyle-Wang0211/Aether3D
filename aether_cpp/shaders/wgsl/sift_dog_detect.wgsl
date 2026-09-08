// sift_dog_detect.wgsl — S2 DoG + S3 extrema/refine/cull + atomic collect (oct 0).
//
// GPU DSP-SIFT M1 Stage B (GPU_DSP_SIFT_PLAN_AFFINE_OFF.md §2-S2/S3, §3-①).
// One invocation per CSS pixel of octave 0. Replicates, bit-for-bit in
// structure (f32 vs VLFeat's f64 — see note), colmap/feature/sift.cc's covdet
// DOG detector via VLFeat covdet.c:1921 vl_covdet_detect:
//
//   CSS geometry (DOG): octaveLastSubdivision -= 1, so for the fo=0 pyramid
//   (gss sublevels s in [-1,4]) the DoG stack has sublevels s in [-1,3] →
//   depth = 5. clevel[s] = gss[s] - gss[s+1]   (_vl_dog_response: level2-level1
//   with level1=gss[s+1], level2=gss[s]).  DoG is NEVER materialized: every
//   sample is gss[s]-gss[s+1] in f32 registers (avoids catastrophic
//   cancellation that f16 would suffer).
//
//   Extrema (vl_find_local_extrema_3, covdet.c:1057): strict > or < over the
//   full 26-neighbourhood AND |v| >= 0.8*peakThreshold. z in [1, depth-2] i.e.
//   the DoG sublevels s in [first+1, first+depth-2] = [0, 2] here.
//
//   Refine (vl_refine_local_extreum_3, covdet.c:1206): <=5 Newton iters, 3x3x3
//   gradient+Hessian, 3x3 linear solve (Gaussian elim w/ partial pivot, singular
//   thresh 1e-10), move the integer (x,y) cell when |b|>0.6 (NOT 0.5), z fixed.
//   Accept iff solve ok && |b.{x,y,z}|<1.5 && refined in [0,W-1]x[0,H-1]x[0,D-1].
//
//   Cull: |peakScore| > peakThreshold && edgeScore < edgeThreshold, with
//   peakScore = D(0) + 0.5*(Dx*bx+Dy*by+Dz*bz),
//   alpha = (Dxx+Dyy)^2/(Dxx*Dyy - Dxy^2), edgeScore = (0.5a-1)+sqrt(max(0.25a-1,0)*a)
//   (alpha<0 → edgeScore = +inf → rejected).
//
//   Emitted frame: x = refined.x * step (step=1 at octave 0), y = refined.y*step,
//   sigma = baseScale * 2^(o + (z + octaveFirstSub)/octaveResolution), s=round(z).
//   NOTE the CPU keypoint.x = frame.x + 0.5 half-pixel shift is applied at
//   READBACK on the host (sift.cc:422), NOT here — we store the raw frame.x/y so
//   downstream affine/orient/descriptor stages see VLFeat-native coordinates.
//
// f32 vs f64: VLFeat refines in double. We refine in f32 (no f64 in WGSL). The
// DoG inputs are already f32, the solve is well-conditioned 3x3, and the gate
// tolerance (pos-err<=0.05px) absorbs the f32 round-off. This is the only
// intentional numeric divergence in Stage B.
//
// Keypoint collection (§3-①): atomicAdd into kp_counter, capacity guard CAP, no
// decoupled-lookback prefix sum (Metal forward-progress unsafe). A separate tiny
// pass turns the counter into indirect-dispatch args for S4/S5.

// ─── KpRecord layout (must match host struct + downstream stages) ───
//   f32 x, y           VLFeat frame coords (pre +0.5)
//   f32 sigma          ellipse scale (a11=a22=sigma, a12=a21=0 isotropic init)
//   f32 peakScore
//   f32 edgeScore
//   i32 o, s           octave, rounded sublevel
//   i32 _pad           → 32 bytes, 16B-aligned
const KP_STRIDE : u32 = 8u;   // u32/f32 words per KpRecord

struct Params {
  width   : u32,        // octave-0 CSS width  (== gss octave-0 width)
  height  : u32,        // octave-0 CSS height
  cap     : u32,        // keypoint capacity guard
  octave  : u32,        // o (0 for M1)
  peak_threshold : f32, // self->peakThreshold (0.02/octave_resolution default)
  edge_threshold : f32, // self->edgeThreshold (10.0 default)
  base_scale     : f32, // cgeom.baseScale
  oct_resolution : f32, // cgeom.octaveResolution (3)
  // [PACK-ZERO 2026-08-10] 本 octave 6 层在 packed 大缓冲中的 element 偏移。
  off0 : u32,
  off1 : u32,
  off2 : u32,
  off3 : u32,
  off4 : u32,
  off5 : u32,
  z0 : u32,      // [W256] 拆分 dispatch 的 z 起点(0 或 2);偏移 off* 相对绑定起点
  _pad1 : u32,
};

// gss octave-0 levels s = -1..4 → 6 buffers, index = s+1.
// [PACK-ZERO 2026-08-10] 6 层独立绑定 → 单一 packed 大缓冲 + 每层偏移
// (Params.off0..off5,由 host 按本 octave 填)。数值逐位不变,仅寻址变化。
@group(0) @binding(0) var<storage, read> packed_gss : array<f32>;
@group(0) @binding(1) var<storage, read_write> kp_counter : atomic<u32>;
@group(0) @binding(2) var<storage, read_write> kp_buffer  : array<u32>; // CAP * KP_STRIDE
@group(0) @binding(3) var<uniform>             P          : Params;
// [SPLITBUF 2026-09-08] 高三层(li 3..5)从**第二块缓冲**读。层→缓冲的映射是
// 编译期固定的(每层本来就各有自己的 case 和偏移),不引入任何数据相关分支。
// 单缓冲模式下两个绑定指向同一块同一窗口 ⇒ 行为完全等价。
@group(0) @binding(4) var<storage, read> packed_gss_hi : array<f32>;

// gss[level_idx] sampled at clamped (x,y). level_idx = s+1 in [0,5].
fn gss_at(level_idx : i32, x : i32, y : i32) -> f32 {
  let w : i32 = i32(P.width);
  let h : i32 = i32(P.height);
  let cx : i32 = max(0, min(x, w - 1));
  let cy : i32 = max(0, min(y, h - 1));
  let k : i32 = cy * w + cx;
  switch (level_idx) {
    case 0: { return packed_gss[P.off0 + u32(k)]; }
    case 1: { return packed_gss[P.off1 + u32(k)]; }
    case 2: { return packed_gss[P.off2 + u32(k)]; }
    case 3: { return packed_gss_hi[P.off3 + u32(k)]; }
    case 4: { return packed_gss_hi[P.off4 + u32(k)]; }
    default: { return packed_gss_hi[P.off5 + u32(k)]; }
  }
}

// DoG at css-sublevel-index zc (0..depth-1, i.e. gss s = zc + first = zc - 1):
//   clevel[s] = gss[s] - gss[s+1]  → here gss level_idx (s+1) = zc and zc+1.
// So dog(zc) = gss_level(zc) - gss_level(zc+1).
fn dog_at(zc : i32, x : i32, y : i32) -> f32 {
  return gss_at(zc, x, y) - gss_at(zc + 1, x, y);
}

// Solve 3x3 A x = b in-place (Gaussian elimination, partial pivot), mirrors
// vl_gaussian_elimination(M,3,4). A is row-major Aat(i,j)=A[i + j*3] as VLFeat
// stores it. Returns false if singular (maxabsa < 1e-10).
fn solve3(Ain : array<f32, 9>, bin : array<f32, 3>, out_x : ptr<function, array<f32,3>>) -> bool {
  // Augmented matrix M[3*4], column-major same as VLFeat: Mat(i,j)=M[i+j*3].
  var M : array<f32, 12>;
  // A occupies columns 0..2, b column 3. VLFeat: M[0..8]=A[0..8], M[9..11]=b.
  M[0] = Ain[0]; M[1] = Ain[1]; M[2] = Ain[2];
  M[3] = Ain[3]; M[4] = Ain[4]; M[5] = Ain[5];
  M[6] = Ain[6]; M[7] = Ain[7]; M[8] = Ain[8];
  M[9] = bin[0]; M[10] = bin[1]; M[11] = bin[2];

  let numRows : i32 = 3;
  let numCols : i32 = 4;
  for (var j : i32 = 0; j < numRows; j = j + 1) {
    var maxa : f32 = 0.0;
    var maxabsa : f32 = 0.0;
    var maxi : i32 = -1;
    for (var i : i32 = j; i < numRows; i = i + 1) {
      let a : f32 = M[i + j * numRows];
      let absa : f32 = abs(a);
      if (absa > maxabsa) { maxa = a; maxabsa = absa; maxi = i; }
    }
    if (maxabsa < 1e-10) { return false; }
    let ip : i32 = maxi;
    // swap row ip with row j (cols j..numCols-1) + normalize row j by maxa.
    for (var jj : i32 = j; jj < numCols; jj = jj + 1) {
      let tmp : f32 = M[ip + jj * numRows];
      M[ip + jj * numRows] = M[j + jj * numRows];
      M[j + jj * numRows] = tmp;
      M[j + jj * numRows] = M[j + jj * numRows] / maxa;
    }
    // elimination of rows below.
    for (var ii : i32 = j + 1; ii < numRows; ii = ii + 1) {
      let x : f32 = M[ii + j * numRows];
      for (var jj : i32 = j; jj < numCols; jj = jj + 1) {
        M[ii + jj * numRows] = M[ii + jj * numRows] - x * M[j + jj * numRows];
      }
    }
  }
  // backward substitution (cols numRows..numCols-1, here just col 3).
  for (var i : i32 = numRows - 1; i > 0; i = i - 1) {
    for (var ii : i32 = i - 1; ii >= 0; ii = ii - 1) {
      let x : f32 = M[ii + i * numRows];
      for (var jc : i32 = numRows; jc < numCols; jc = jc + 1) {
        M[ii + jc * numRows] = M[ii + jc * numRows] - x * M[i + jc * numRows];
      }
    }
  }
  (*out_x)[0] = M[9];
  (*out_x)[1] = M[10];
  (*out_x)[2] = M[11];
  return true;
}

@compute @workgroup_size(8, 8, 1)
fn main(@builtin(global_invocation_id) gid : vec3<u32>) {
  let gx : u32 = gid.x;
  let gy : u32 = gid.y;
  let zc : i32 = i32(gid.z) + i32(P.z0) + 1;  // [W256]  // css sublevel index z in [1, depth-2] = [1,3]
  let W : i32 = i32(P.width);
  let H : i32 = i32(P.height);

  // depth = 5 → z (1-based extrema range) in {1,2,3}. gid.z in {0,1,2}.
  if (i32(gid.z) + i32(P.z0) > 2) { return; }
  // extrema interior: x,y in [1, W-2] / [1, H-2].
  if (gx < 1u || gy < 1u || gx >= u32(W - 1) || gy >= u32(H - 1)) { return; }

  let x0 : i32 = i32(gx);
  let y0 : i32 = i32(gy);
  let v : f32 = dog_at(zc, x0, y0);

  // ─── extrema test: strict > all 26 neighbours AND v >= +0.8t, OR strict <
  //     all 26 AND v <= -0.8t. (vl_find_local_extrema_3 CHECK_NEIGHBORS_3) ───
  let t08 : f32 = 0.8 * P.peak_threshold;
  var is_max : bool = (v >= t08);
  var is_min : bool = (v <= -t08);
  if (is_max || is_min) {
    // [K1c 2026-09-07] 先查同层 8 邻居(缓存最热、最易否决),再查上下层;
    // 26 个比较是 AND,顺序不影响结果 ⇒ 逐位同;只是平均更早退出。
    for (var kz : i32 = 0; kz <= 2; kz = kz + 1) {
      let dz : i32 = select(select(1, -1, kz == 1), 0, kz == 0);
      for (var dy : i32 = -1; dy <= 1; dy = dy + 1) {
        for (var dx : i32 = -1; dx <= 1; dx = dx + 1) {
          if (dx == 0 && dy == 0 && dz == 0) { continue; }
          let nv : f32 = dog_at(zc + dz, x0 + dx, y0 + dy);
          if (!(v > nv)) { is_max = false; }
          if (!(v < nv)) { is_min = false; }
          // [K1a 2026-09-06] 两个判定都已失败 ⇒ 后续邻居不可能再改变结果,提前退出(纯控制流,逐位不变)
          if (!(is_max || is_min)) { break; }
        }
        if (!(is_max || is_min)) { break; }
      }
      if (!(is_max || is_min)) { break; }
    }
  }
  if (!(is_max || is_min)) { return; }

  // ─── Newton refine (vl_refine_local_extreum_3) ───
  var x : i32 = x0;
  var y : i32 = y0;
  let z : i32 = zc;  // z fixed (only x,y cells move)
  var dxc : i32 = 0;
  var dyc : i32 = 0;
  var b : array<f32, 3>;
  b[0] = 0.0; b[1] = 0.0; b[2] = 0.0;
  var Dx : f32 = 0.0; var Dy : f32 = 0.0; var Dz : f32 = 0.0;
  var ok_solve : bool = true;

  for (var iter : i32 = 0; iter < 5; iter = iter + 1) {
    x = x + dxc;
    y = y + dyc;
    // sample the 3x3x3 DoG window centred at (x,y,z).
    let c   : f32 = dog_at(z,   x,   y);
    let xp  : f32 = dog_at(z,   x+1, y);
    let xm  : f32 = dog_at(z,   x-1, y);
    let yp  : f32 = dog_at(z,   x,   y+1);
    let ym  : f32 = dog_at(z,   x,   y-1);
    let zp  : f32 = dog_at(z+1, x,   y);
    let zm  : f32 = dog_at(z-1, x,   y);
    let xyp : f32 = dog_at(z,   x+1, y+1);
    let xym : f32 = dog_at(z,   x-1, y-1);
    let xpym: f32 = dog_at(z,   x+1, y-1);
    let xmyp: f32 = dog_at(z,   x-1, y+1);
    let xzp : f32 = dog_at(z+1, x+1, y);
    let xzm : f32 = dog_at(z-1, x-1, y);
    let xpzm: f32 = dog_at(z-1, x+1, y);
    let xmzp: f32 = dog_at(z+1, x-1, y);
    let yzp : f32 = dog_at(z+1, x,   y+1);
    let yzm : f32 = dog_at(z-1, x,   y-1);
    let ypzm: f32 = dog_at(z-1, x,   y+1);
    let ymzp: f32 = dog_at(z+1, x,   y-1);

    Dx = 0.5 * (xp - xm);
    Dy = 0.5 * (yp - ym);
    Dz = 0.5 * (zp - zm);
    let Dxx : f32 = xp + xm - 2.0 * c;
    let Dyy : f32 = yp + ym - 2.0 * c;
    let Dzz : f32 = zp + zm - 2.0 * c;
    let Dxy : f32 = 0.25 * (xyp + xym - xmyp - xpym);
    let Dxz : f32 = 0.25 * (xzp + xzm - xmzp - xpzm);
    let Dyz : f32 = 0.25 * (yzp + yzm - ypzm - ymzp);

    // A (VLFeat Aat(i,j)=A[i+j*3]):
    var A : array<f32, 9>;
    A[0] = Dxx; A[4] = Dyy; A[8] = Dzz;
    A[1] = Dxy; A[3] = Dxy;   // Aat(1,0)=Aat(0,1)=Dxy
    A[2] = Dxz; A[6] = Dxz;   // Aat(2,0)=Aat(0,2)=Dxz
    A[5] = Dyz; A[7] = Dyz;   // Aat(2,1)=Aat(1,2)=Dyz
    var rhs : array<f32, 3>;
    rhs[0] = -Dx; rhs[1] = -Dy; rhs[2] = -Dz;

    var sol : array<f32, 3>;
    ok_solve = solve3(A, rhs, &sol);
    if (!ok_solve) {
      b[0] = 0.0; b[1] = 0.0; b[2] = 0.0;
      break;
    }
    b[0] = sol[0]; b[1] = sol[1]; b[2] = sol[2];

    // move integer cell when |b| > 0.6 (VLFeat uses 0.6, not 0.5).
    dxc = 0; dyc = 0;
    if (b[0] > 0.6 && x < W - 2) { dxc = 1; }
    if (b[0] < -0.6 && x > 1) { dxc = -1; }
    if (b[1] > 0.6 && y < H - 2) { dyc = dyc + 1; }
    if (b[1] < -0.6 && y > 1) { dyc = dyc - 1; }
    if (dxc == 0 && dyc == 0) { break; }
  }

  // ─── accept / score (mirrors covdet.c:1284-1314) ───
  // Recompute Dxx/Dyy/Dxy at the FINAL (x,y,z) for alpha (they're needed for the
  // edge score; the loop's last values already correspond to final x,y since the
  // last iteration that changed the cell re-sampled before solving — but to be
  // exact we recompute here, matching VLFeat which uses the post-loop pt window).
  let c2   : f32 = dog_at(z,   x,   y);
  let xp2  : f32 = dog_at(z,   x+1, y);
  let xm2  : f32 = dog_at(z,   x-1, y);
  let yp2  : f32 = dog_at(z,   x,   y+1);
  let ym2  : f32 = dog_at(z,   x,   y-1);
  let xyp2 : f32 = dog_at(z,   x+1, y+1);
  let xym2 : f32 = dog_at(z,   x-1, y-1);
  let xpym2: f32 = dog_at(z,   x+1, y-1);
  let xmyp2: f32 = dog_at(z,   x-1, y+1);
  let Dxx2 : f32 = xp2 + xm2 - 2.0 * c2;
  let Dyy2 : f32 = yp2 + ym2 - 2.0 * c2;
  let Dxy2 : f32 = 0.25 * (xyp2 + xym2 - xmyp2 - xpym2);

  let peakScore : f32 = c2 + 0.5 * (Dx * b[0] + Dy * b[1] + Dz * b[2]);
  let denom : f32 = Dxx2 * Dyy2 - Dxy2 * Dxy2;
  let alpha : f32 = (Dxx2 + Dyy2) * (Dxx2 + Dyy2) / denom;
  var edgeScore : f32;
  if (alpha < 0.0) {
    edgeScore = 3.4e38;  // +inf-ish → always fails edge_threshold (10)
  } else {
    edgeScore = (0.5 * alpha - 1.0) + sqrt(max(0.25 * alpha - 1.0, 0.0) * alpha);
  }

  let rx : f32 = f32(x) + b[0];
  let ry : f32 = f32(y) + b[1];
  let rz : f32 = f32(z) + b[2];
  let depth : i32 = 5;

  // refine stability (covdet.c:1307): solve ok && |b|<1.5 all && in bounds.
  let stable : bool =
      ok_solve &&
      abs(b[0]) < 1.5 && abs(b[1]) < 1.5 && abs(b[2]) < 1.5 &&
      rx >= 0.0 && rx <= f32(W - 1) &&
      ry >= 0.0 && ry <= f32(H - 1) &&
      rz >= 0.0 && rz <= f32(depth - 1);

  // cull (covdet.c:2024): |peakScore| > peakThreshold && edgeScore < edgeThreshold.
  let keep : bool = stable &&
      abs(peakScore) > P.peak_threshold &&
      edgeScore < P.edge_threshold;
  if (!keep) { return; }

  // ─── emit ───
  // step = 2^octave; octave 0 → step = 1. frame.x = refined.x * step.
  let step : f32 = exp2(f32(P.octave));
  let fx : f32 = rx * step;
  let fy : f32 = ry * step;
  // sigma = baseScale * 2^(o + (z_round + octaveFirstSub)/octaveResolution),
  // octaveFirstSub = -1. round(refined.z) per covdet.c:2037.
  let s_round : i32 = i32(round(rz));
  let sigma : f32 = P.base_scale *
      exp2(f32(P.octave) + (f32(s_round) + (-1.0)) / P.oct_resolution);

  let slot : u32 = atomicAdd(&kp_counter, 1u);
  if (slot < P.cap) {
    let base : u32 = slot * KP_STRIDE;
    kp_buffer[base + 0u] = bitcast<u32>(fx);
    kp_buffer[base + 1u] = bitcast<u32>(fy);
    kp_buffer[base + 2u] = bitcast<u32>(sigma);
    kp_buffer[base + 3u] = bitcast<u32>(peakScore);
    kp_buffer[base + 4u] = bitcast<u32>(edgeScore);
    kp_buffer[base + 5u] = bitcast<u32>(i32(P.octave));
    kp_buffer[base + 6u] = bitcast<u32>(s_round);
    kp_buffer[base + 7u] = 0u;
  }
}
