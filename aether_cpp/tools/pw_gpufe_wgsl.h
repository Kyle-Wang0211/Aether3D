// GENERATED from xrslam-gpu-detect/wgsl/*.wgsl — do not edit; regenerate (tools/gen_wgsl_header.py).
#pragma once
namespace pw::gpufe::wgsl {
static const char* const k_gftt_common = R"WGSL(
// M1 — port of OpenCV 4.0.1 (c9ad5779, Apache-2.0) cornerHarris + goodFeaturesToTrack pieces.
// One thread per output pixel; arithmetic mirrors OpenCV's SymmRowSmallFilter / SymmColumnSmallFilter
// expression order (k0*x0 + k1*(x[-1]+x[1]) for symmetric, k1*(x[1]-x[-1]) for anti-symmetric),
// BORDER_REFLECT_101, float32.
struct Params { width: u32, height: u32, scale: f32, k: f32, quality: f32, max_corners: u32, pwq: u32, base: u32 };
fn reflect101(i: i32, n: i32) -> i32 { var j = i; if (j < 0) { j = -j; } if (j >= n) { j = 2 * n - 2 - j; } return j; }

)WGSL";
static const char* const k_sobel_dxdy = R"WGSL(
// cv::Sobel(8U→32F, ksize 3, scale, BORDER_REFLECT_101) exactly as OpenCV 4.0.1 filter.cpp small filters evaluate it:
//  Dx: row anti-symmetric [-1,0,1] (kx[0]==0&&kx[1]==1 branch): S[+1]-S[-1]; column symmetric [1,2,1]*scale (generic): (S0+S2)*f1 + S1*f0, f0=2s f1=s
//  Dy: row symmetric [1,2,1]*scale (generic): S[0]*k0 + (S[-1]+S[+1])*k1, k0=2s k1=s; column anti-symmetric [-1,0,1] (is_m1_0_1): S2-S0
@group(0) @binding(0) var<storage, read> img: array<u32>;
@group(0) @binding(1) var<storage, read_write> dx: array<f32>;
@group(0) @binding(2) var<storage, read_write> dy: array<f32>;
@group(0) @binding(3) var<uniform> p: Params;
fn px(x: i32, y: i32) -> f32 { let xx = reflect101(x, i32(p.width)); let yy = reflect101(y, i32(p.height)); let c = u32(xx + 21); return f32((img[p.base + u32(yy + 21) * p.pwq + (c >> 2u)] >> ((c & 3u) * 8u)) & 255u); }   // packed padded layout (same buffer as the LK pyramid)
fn row_dx(x: i32, y: i32) -> f32 { return px(x + 1, y) - px(x - 1, y); }
fn row_dy(x: i32, y: i32, s: f32) -> f32 { return (fma(px(x - 1, y), s, 0.0) + fma(px(x, y), 2.0 * s, 0.0)) + fma(px(x + 1, y), s, 0.0); }   // generic RowFilter<uchar,float>: ((k0*S0 + k1*S1) + k2*S2), verified 0 mismatches vs 4.0.1
@compute @workgroup_size(16, 16)
fn main(@builtin(global_invocation_id) gid: vec3<u32>) {
  if (gid.x >= p.width || gid.y >= p.height) { return; }
  let x = i32(gid.x); let y = i32(gid.y); let s = p.scale; let h = i32(p.height);
  let ym = reflect101(y - 1, h); let yp = reflect101(y + 1, h);
  dx[gid.y * p.width + gid.x] = fma(row_dx(x, ym) + row_dx(x, yp), s, fma(row_dx(x, y), 2.0 * s, 0.0));   // SymmColumnSmallVec_32f: v_muladd(S0+S2, k1, S1*k0) is vfmaq_f32 on arm64 (FUSED) — verified 0 mismatches vs 4.0.1
  dy[gid.y * p.width + gid.x] = row_dy(x, yp, s) - row_dy(x, ym, s);
}

)WGSL";
static const char* const k_harris_box = R"WGSL(
// cov=(dx²,dx·dy,dy²) → 3×3 unnormalised box (RowSum then ColumnSum, BORDER_DEFAULT) → Harris: a*c - b*b - k*(a+c)*(a+c)  (calcHarris, corner.cpp)
@group(0) @binding(0) var<storage, read> dx: array<f32>;
@group(0) @binding(1) var<storage, read> dy: array<f32>;
@group(0) @binding(2) var<storage, read_write> eig: array<f32>;
@group(0) @binding(3) var<uniform> p: Params;
fn at(x: i32, y: i32) -> u32 { return u32(reflect101(y, i32(p.height))) * p.width + u32(reflect101(x, i32(p.width))); }
// boxFilter(cov, 3x3, normalize=false) on CV_32F sums in DOUBLE (RowSum<float,double>/ColumnSum<double,float>) and casts
// once: = the correctly rounded f32 of the exact 9-term sum. Emulated with a signed 96-bit fixed-point accumulator.
struct Acc { w0: u32, w1: u32, w2: u32 };
fn acc_add(a: ptr<function, Acc>, m: u32, sh: u32) {   // a += m << sh  (m < 2^24, sh < 96)
  let k = sh >> 5u; let b = sh & 31u;
  let lo = m << b; let hi = select(0u, m >> (32u - b), b != 0u);
  if (k == 0u) {
    let s0 = (*a).w0 + lo; let c0 = select(0u, 1u, s0 < lo); (*a).w0 = s0;
    let t1 = (*a).w1 + hi; let c1a = select(0u, 1u, t1 < hi); let s1 = t1 + c0; let c1b = select(0u, 1u, s1 < t1); (*a).w1 = s1;
    (*a).w2 = (*a).w2 + c1a + c1b;
  } else if (k == 1u) {
    let s1 = (*a).w1 + lo; let c1 = select(0u, 1u, s1 < lo); (*a).w1 = s1; (*a).w2 = (*a).w2 + hi + c1;
  } else { (*a).w2 = (*a).w2 + lo; }
}
fn acc_neg(a: ptr<function, Acc>) {   // two's complement negate
  let n0 = ~(*a).w0; let n1 = ~(*a).w1; let n2 = ~(*a).w2;
  let s0 = n0 + 1u; let c0 = select(0u, 1u, s0 == 0u); let s1 = n1 + c0; let c1 = select(0u, 1u, c0 == 1u && s1 == 0u);
  (*a).w0 = s0; (*a).w1 = s1; (*a).w2 = n2 + c1;
}
fn bit96(S: Acc, bit: i32) -> u32 { let w = select(select(S.w0, S.w1, bit >= 32), S.w2, bit >= 64); return (w >> u32(bit & 31)) & 1u; }
fn finish_sum(pos: Acc, neg0: Acc, base: i32) -> f32 {
  var neg = neg0; acc_neg(&neg);
  var S = pos;
  { let s0 = S.w0 + neg.w0; let c0 = select(0u, 1u, s0 < neg.w0); let t1 = S.w1 + neg.w1; let c1a = select(0u, 1u, t1 < neg.w1); let s1 = t1 + c0; let c1b = select(0u, 1u, s1 < t1); S.w0 = s0; S.w1 = s1; S.w2 = S.w2 + neg.w2 + c1a + c1b; }
  var negative = false;
  if ((S.w2 & 0x80000000u) != 0u) { negative = true; acc_neg(&S); }
  if (S.w0 == 0u && S.w1 == 0u && S.w2 == 0u) { return 0.0; }
  var hbit: i32;
  if (S.w2 != 0u) { hbit = 64 + 31 - i32(countLeadingZeros(S.w2)); } else if (S.w1 != 0u) { hbit = 32 + 31 - i32(countLeadingZeros(S.w1)); } else { hbit = 31 - i32(countLeadingZeros(S.w0)); }
  let lowbit = hbit - 23;
  var mant: u32; var guard: u32 = 0u; var sticky: u32 = 0u;
  if (lowbit <= 0) { mant = S.w0 << u32(-lowbit); }
  else {
    let lb = u32(lowbit); let k = lb >> 5u; let b = lb & 31u;
    let wk = select(select(S.w0, S.w1, k == 1u), S.w2, k == 2u); let wk1 = select(select(S.w1, S.w2, k == 1u), 0u, k == 2u);
    mant = select((wk >> b) | (wk1 << (32u - b)), wk, b == 0u) & 0xffffffu;
    let gb = lb - 1u; let gk = gb >> 5u; let gbit = gb & 31u; let wg = select(select(S.w0, S.w1, gk == 1u), S.w2, gk == 2u);
    guard = (wg >> gbit) & 1u;
    let below = wg & ((1u << gbit) - 1u);
    var st = below != 0u;
    if (gk >= 1u && S.w0 != 0u) { st = true; }
    if (gk >= 2u && S.w1 != 0u) { st = true; }
    sticky = select(0u, 1u, st);
  }
  if (guard == 1u && (sticky == 1u || (mant & 1u) == 1u)) { mant += 1u; }
  let e2 = (base - 127 - 23) + lowbit;
  let r = ldexp(f32(mant), e2);
  return select(r, -r, negative);
}
// Fast path: all 9 terms within 36 exponent steps -> the exact sum fits in 64 bits (24 + 36 + 4 carry) -> two-word accumulator.
fn sum9_fast(t0: f32, t1: f32, t2: f32, t3: f32, t4: f32, t5: f32, t6: f32, t7: f32, t8: f32, base: i32) -> f32 {
  var plo: u32 = 0u; var phi: u32 = 0u; var nlo: u32 = 0u; var nhi: u32 = 0u;
  { let b = bitcast<u32>(t0); if ((b & 0x7fffffffu) != 0u) { let e = i32((b >> 23u) & 255u); var m = b & 0x7fffffu; var ee = e; if (e == 0) { ee = 1; } else { m |= 0x800000u; } let sh = u32(ee - base);
      let lo = select(m << sh, 0u, sh >= 32u); let hi = select(select(m >> (32u - sh), 0u, sh == 0u), m << (sh - 32u), sh >= 32u);
      if ((b & 0x80000000u) != 0u) { let s = nlo + lo; nhi = nhi + hi + select(0u, 1u, s < lo); nlo = s; } else { let s = plo + lo; phi = phi + hi + select(0u, 1u, s < lo); plo = s; } } }
  { let b = bitcast<u32>(t1); if ((b & 0x7fffffffu) != 0u) { let e = i32((b >> 23u) & 255u); var m = b & 0x7fffffu; var ee = e; if (e == 0) { ee = 1; } else { m |= 0x800000u; } let sh = u32(ee - base);
      let lo = select(m << sh, 0u, sh >= 32u); let hi = select(select(m >> (32u - sh), 0u, sh == 0u), m << (sh - 32u), sh >= 32u);
      if ((b & 0x80000000u) != 0u) { let s = nlo + lo; nhi = nhi + hi + select(0u, 1u, s < lo); nlo = s; } else { let s = plo + lo; phi = phi + hi + select(0u, 1u, s < lo); plo = s; } } }
  { let b = bitcast<u32>(t2); if ((b & 0x7fffffffu) != 0u) { let e = i32((b >> 23u) & 255u); var m = b & 0x7fffffu; var ee = e; if (e == 0) { ee = 1; } else { m |= 0x800000u; } let sh = u32(ee - base);
      let lo = select(m << sh, 0u, sh >= 32u); let hi = select(select(m >> (32u - sh), 0u, sh == 0u), m << (sh - 32u), sh >= 32u);
      if ((b & 0x80000000u) != 0u) { let s = nlo + lo; nhi = nhi + hi + select(0u, 1u, s < lo); nlo = s; } else { let s = plo + lo; phi = phi + hi + select(0u, 1u, s < lo); plo = s; } } }
  { let b = bitcast<u32>(t3); if ((b & 0x7fffffffu) != 0u) { let e = i32((b >> 23u) & 255u); var m = b & 0x7fffffu; var ee = e; if (e == 0) { ee = 1; } else { m |= 0x800000u; } let sh = u32(ee - base);
      let lo = select(m << sh, 0u, sh >= 32u); let hi = select(select(m >> (32u - sh), 0u, sh == 0u), m << (sh - 32u), sh >= 32u);
      if ((b & 0x80000000u) != 0u) { let s = nlo + lo; nhi = nhi + hi + select(0u, 1u, s < lo); nlo = s; } else { let s = plo + lo; phi = phi + hi + select(0u, 1u, s < lo); plo = s; } } }
  { let b = bitcast<u32>(t4); if ((b & 0x7fffffffu) != 0u) { let e = i32((b >> 23u) & 255u); var m = b & 0x7fffffu; var ee = e; if (e == 0) { ee = 1; } else { m |= 0x800000u; } let sh = u32(ee - base);
      let lo = select(m << sh, 0u, sh >= 32u); let hi = select(select(m >> (32u - sh), 0u, sh == 0u), m << (sh - 32u), sh >= 32u);
      if ((b & 0x80000000u) != 0u) { let s = nlo + lo; nhi = nhi + hi + select(0u, 1u, s < lo); nlo = s; } else { let s = plo + lo; phi = phi + hi + select(0u, 1u, s < lo); plo = s; } } }
  { let b = bitcast<u32>(t5); if ((b & 0x7fffffffu) != 0u) { let e = i32((b >> 23u) & 255u); var m = b & 0x7fffffu; var ee = e; if (e == 0) { ee = 1; } else { m |= 0x800000u; } let sh = u32(ee - base);
      let lo = select(m << sh, 0u, sh >= 32u); let hi = select(select(m >> (32u - sh), 0u, sh == 0u), m << (sh - 32u), sh >= 32u);
      if ((b & 0x80000000u) != 0u) { let s = nlo + lo; nhi = nhi + hi + select(0u, 1u, s < lo); nlo = s; } else { let s = plo + lo; phi = phi + hi + select(0u, 1u, s < lo); plo = s; } } }
  { let b = bitcast<u32>(t6); if ((b & 0x7fffffffu) != 0u) { let e = i32((b >> 23u) & 255u); var m = b & 0x7fffffu; var ee = e; if (e == 0) { ee = 1; } else { m |= 0x800000u; } let sh = u32(ee - base);
      let lo = select(m << sh, 0u, sh >= 32u); let hi = select(select(m >> (32u - sh), 0u, sh == 0u), m << (sh - 32u), sh >= 32u);
      if ((b & 0x80000000u) != 0u) { let s = nlo + lo; nhi = nhi + hi + select(0u, 1u, s < lo); nlo = s; } else { let s = plo + lo; phi = phi + hi + select(0u, 1u, s < lo); plo = s; } } }
  { let b = bitcast<u32>(t7); if ((b & 0x7fffffffu) != 0u) { let e = i32((b >> 23u) & 255u); var m = b & 0x7fffffu; var ee = e; if (e == 0) { ee = 1; } else { m |= 0x800000u; } let sh = u32(ee - base);
      let lo = select(m << sh, 0u, sh >= 32u); let hi = select(select(m >> (32u - sh), 0u, sh == 0u), m << (sh - 32u), sh >= 32u);
      if ((b & 0x80000000u) != 0u) { let s = nlo + lo; nhi = nhi + hi + select(0u, 1u, s < lo); nlo = s; } else { let s = plo + lo; phi = phi + hi + select(0u, 1u, s < lo); plo = s; } } }
  { let b = bitcast<u32>(t8); if ((b & 0x7fffffffu) != 0u) { let e = i32((b >> 23u) & 255u); var m = b & 0x7fffffu; var ee = e; if (e == 0) { ee = 1; } else { m |= 0x800000u; } let sh = u32(ee - base);
      let lo = select(m << sh, 0u, sh >= 32u); let hi = select(select(m >> (32u - sh), 0u, sh == 0u), m << (sh - 32u), sh >= 32u);
      if ((b & 0x80000000u) != 0u) { let s = nlo + lo; nhi = nhi + hi + select(0u, 1u, s < lo); nlo = s; } else { let s = plo + lo; phi = phi + hi + select(0u, 1u, s < lo); plo = s; } } }
  // S = P - N (signed 64)
  var negative = false; var lo: u32; var hi: u32;
  if (phi > nhi || (phi == nhi && plo >= nlo)) { lo = plo - nlo; hi = phi - nhi - select(0u, 1u, plo < nlo); }
  else { negative = true; lo = nlo - plo; hi = nhi - phi - select(0u, 1u, nlo < plo); }
  if (lo == 0u && hi == 0u) { return 0.0; }
  var hbit: i32; if (hi != 0u) { hbit = 32 + 31 - i32(countLeadingZeros(hi)); } else { hbit = 31 - i32(countLeadingZeros(lo)); }
  let lowbit = hbit - 23;
  var mant: u32; var guard: u32 = 0u; var sticky: u32 = 0u;
  if (lowbit <= 0) { mant = lo << u32(-lowbit); }
  else {
    let lb = u32(lowbit);
    mant = select(select((lo >> lb) | (hi << (32u - lb)), lo, lb == 0u), hi >> (lb - 32u), lb >= 32u) & 0xffffffu;
    let gb = lb - 1u;
    guard = select((lo >> gb) & 1u, (hi >> (gb - 32u)) & 1u, gb >= 32u);
    let below_lo = select(lo & ((1u << gb) - 1u), lo, gb >= 32u);
    let below_hi = select(0u, hi & ((1u << (gb - 32u)) - 1u), gb >= 32u);
    sticky = select(0u, 1u, (below_lo | below_hi) != 0u);
  }
  if (guard == 1u && (sticky == 1u || (mant & 1u) == 1u)) { mant += 1u; }
  let r = ldexp(f32(mant), (base - 127 - 23) + lowbit);
  return select(r, -r, negative);
}
// Error-free fast path (Knuth TwoSum cascade, strict math: adds/subs only, no contraction possible). Accumulate s with
// TwoSum, feed every error into a second TwoSum accumulator e; if no error ever escapes the second level (all err2 == 0) then
// s + e is EXACTLY the real sum, and fl(s + e) is its correctly rounded float. Otherwise fall back to the integer path.
fn two_sum(a: f32, b: f32) -> vec2<f32> { let s = a + b; let bb = s - a; return vec2<f32>(s, (a - (s - bb)) + (b - bb)); }
fn sum9_ef(t0: f32, t1: f32, t2: f32, t3: f32, t4: f32, t5: f32, t6: f32, t7: f32, t8: f32) -> vec2<f32> {   // (result, ok)
  var s = t0; var e: f32 = 0.0; var lost: f32 = 0.0;
  { let r = two_sum(s, t1); s = r.x; let q = two_sum(e, r.y); e = q.x; lost += abs(q.y); }
  { let r = two_sum(s, t2); s = r.x; let q = two_sum(e, r.y); e = q.x; lost += abs(q.y); }
  { let r = two_sum(s, t3); s = r.x; let q = two_sum(e, r.y); e = q.x; lost += abs(q.y); }
  { let r = two_sum(s, t4); s = r.x; let q = two_sum(e, r.y); e = q.x; lost += abs(q.y); }
  { let r = two_sum(s, t5); s = r.x; let q = two_sum(e, r.y); e = q.x; lost += abs(q.y); }
  { let r = two_sum(s, t6); s = r.x; let q = two_sum(e, r.y); e = q.x; lost += abs(q.y); }
  { let r = two_sum(s, t7); s = r.x; let q = two_sum(e, r.y); e = q.x; lost += abs(q.y); }
  { let r = two_sum(s, t8); s = r.x; let q = two_sum(e, r.y); e = q.x; lost += abs(q.y); }
  return vec2<f32>(s + e, select(0.0, 1.0, lost == 0.0));
}
fn exact_sum9(t0: f32, t1: f32, t2: f32, t3: f32, t4: f32, t5: f32, t6: f32, t7: f32, t8: f32) -> f32 {
  var maxe: i32 = -1; var mine: i32 = 999;
  { let b = bitcast<u32>(t0); if ((b & 0x7fffffffu) != 0u) { let e = max(i32((b >> 23u) & 255u), 1); maxe = max(maxe, e); mine = min(mine, e); } }
  { let b = bitcast<u32>(t1); if ((b & 0x7fffffffu) != 0u) { let e = max(i32((b >> 23u) & 255u), 1); maxe = max(maxe, e); mine = min(mine, e); } }
  { let b = bitcast<u32>(t2); if ((b & 0x7fffffffu) != 0u) { let e = max(i32((b >> 23u) & 255u), 1); maxe = max(maxe, e); mine = min(mine, e); } }
  { let b = bitcast<u32>(t3); if ((b & 0x7fffffffu) != 0u) { let e = max(i32((b >> 23u) & 255u), 1); maxe = max(maxe, e); mine = min(mine, e); } }
  { let b = bitcast<u32>(t4); if ((b & 0x7fffffffu) != 0u) { let e = max(i32((b >> 23u) & 255u), 1); maxe = max(maxe, e); mine = min(mine, e); } }
  { let b = bitcast<u32>(t5); if ((b & 0x7fffffffu) != 0u) { let e = max(i32((b >> 23u) & 255u), 1); maxe = max(maxe, e); mine = min(mine, e); } }
  { let b = bitcast<u32>(t6); if ((b & 0x7fffffffu) != 0u) { let e = max(i32((b >> 23u) & 255u), 1); maxe = max(maxe, e); mine = min(mine, e); } }
  { let b = bitcast<u32>(t7); if ((b & 0x7fffffffu) != 0u) { let e = max(i32((b >> 23u) & 255u), 1); maxe = max(maxe, e); mine = min(mine, e); } }
  { let b = bitcast<u32>(t8); if ((b & 0x7fffffffu) != 0u) { let e = max(i32((b >> 23u) & 255u), 1); maxe = max(maxe, e); mine = min(mine, e); } }
  if (maxe < 0) { return 0.0; }
  { let r = sum9_ef(t0, t1, t2, t3, t4, t5, t6, t7, t8); if (r.y != 0.0) { return r.x; } }
  if (maxe - mine <= 36) { return sum9_fast(t0, t1, t2, t3, t4, t5, t6, t7, t8, mine); }
  var base = mine; if (maxe - mine > 71) { base = maxe - 64; }
  var pos = Acc(0u, 0u, 0u); var neg = Acc(0u, 0u, 0u);
  { let b = bitcast<u32>(t0); if ((b & 0x7fffffffu) != 0u) { let e = i32((b >> 23u) & 255u); var m = b & 0x7fffffu; var ee = e; if (e == 0) { ee = 1; } else { m |= 0x800000u; } let d = ee - base; if (d >= 0) { if ((b & 0x80000000u) != 0u) { acc_add(&neg, m, u32(d)); } else { acc_add(&pos, m, u32(d)); } } } }
  { let b = bitcast<u32>(t1); if ((b & 0x7fffffffu) != 0u) { let e = i32((b >> 23u) & 255u); var m = b & 0x7fffffu; var ee = e; if (e == 0) { ee = 1; } else { m |= 0x800000u; } let d = ee - base; if (d >= 0) { if ((b & 0x80000000u) != 0u) { acc_add(&neg, m, u32(d)); } else { acc_add(&pos, m, u32(d)); } } } }
  { let b = bitcast<u32>(t2); if ((b & 0x7fffffffu) != 0u) { let e = i32((b >> 23u) & 255u); var m = b & 0x7fffffu; var ee = e; if (e == 0) { ee = 1; } else { m |= 0x800000u; } let d = ee - base; if (d >= 0) { if ((b & 0x80000000u) != 0u) { acc_add(&neg, m, u32(d)); } else { acc_add(&pos, m, u32(d)); } } } }
  { let b = bitcast<u32>(t3); if ((b & 0x7fffffffu) != 0u) { let e = i32((b >> 23u) & 255u); var m = b & 0x7fffffu; var ee = e; if (e == 0) { ee = 1; } else { m |= 0x800000u; } let d = ee - base; if (d >= 0) { if ((b & 0x80000000u) != 0u) { acc_add(&neg, m, u32(d)); } else { acc_add(&pos, m, u32(d)); } } } }
  { let b = bitcast<u32>(t4); if ((b & 0x7fffffffu) != 0u) { let e = i32((b >> 23u) & 255u); var m = b & 0x7fffffu; var ee = e; if (e == 0) { ee = 1; } else { m |= 0x800000u; } let d = ee - base; if (d >= 0) { if ((b & 0x80000000u) != 0u) { acc_add(&neg, m, u32(d)); } else { acc_add(&pos, m, u32(d)); } } } }
  { let b = bitcast<u32>(t5); if ((b & 0x7fffffffu) != 0u) { let e = i32((b >> 23u) & 255u); var m = b & 0x7fffffu; var ee = e; if (e == 0) { ee = 1; } else { m |= 0x800000u; } let d = ee - base; if (d >= 0) { if ((b & 0x80000000u) != 0u) { acc_add(&neg, m, u32(d)); } else { acc_add(&pos, m, u32(d)); } } } }
  { let b = bitcast<u32>(t6); if ((b & 0x7fffffffu) != 0u) { let e = i32((b >> 23u) & 255u); var m = b & 0x7fffffu; var ee = e; if (e == 0) { ee = 1; } else { m |= 0x800000u; } let d = ee - base; if (d >= 0) { if ((b & 0x80000000u) != 0u) { acc_add(&neg, m, u32(d)); } else { acc_add(&pos, m, u32(d)); } } } }
  { let b = bitcast<u32>(t7); if ((b & 0x7fffffffu) != 0u) { let e = i32((b >> 23u) & 255u); var m = b & 0x7fffffu; var ee = e; if (e == 0) { ee = 1; } else { m |= 0x800000u; } let d = ee - base; if (d >= 0) { if ((b & 0x80000000u) != 0u) { acc_add(&neg, m, u32(d)); } else { acc_add(&pos, m, u32(d)); } } } }
  { let b = bitcast<u32>(t8); if ((b & 0x7fffffffu) != 0u) { let e = i32((b >> 23u) & 255u); var m = b & 0x7fffffu; var ee = e; if (e == 0) { ee = 1; } else { m |= 0x800000u; } let d = ee - base; if (d >= 0) { if ((b & 0x80000000u) != 0u) { acc_add(&neg, m, u32(d)); } else { acc_add(&pos, m, u32(d)); } } } }
  return finish_sum(pos, neg, base);
}
fn box3(x: i32, y: i32) -> vec3<f32> {
  let k0 = at(x - 1, y - 1); let k1 = at(x, y - 1); let k2 = at(x + 1, y - 1); let k3 = at(x - 1, y); let k4 = at(x, y); let k5 = at(x + 1, y); let k6 = at(x - 1, y + 1); let k7 = at(x, y + 1); let k8 = at(x + 1, y + 1);
  let a0 = dx[k0]; let a1 = dx[k1]; let a2 = dx[k2]; let a3 = dx[k3]; let a4 = dx[k4]; let a5 = dx[k5]; let a6 = dx[k6]; let a7 = dx[k7]; let a8 = dx[k8];
  let b0 = dy[k0]; let b1 = dy[k1]; let b2 = dy[k2]; let b3 = dy[k3]; let b4 = dy[k4]; let b5 = dy[k5]; let b6 = dy[k6]; let b7 = dy[k7]; let b8 = dy[k8];
  let sa = exact_sum9(fma(a0, a0, 0.0), fma(a1, a1, 0.0), fma(a2, a2, 0.0), fma(a3, a3, 0.0), fma(a4, a4, 0.0), fma(a5, a5, 0.0), fma(a6, a6, 0.0), fma(a7, a7, 0.0), fma(a8, a8, 0.0));
  let sb = exact_sum9(fma(a0, b0, 0.0), fma(a1, b1, 0.0), fma(a2, b2, 0.0), fma(a3, b3, 0.0), fma(a4, b4, 0.0), fma(a5, b5, 0.0), fma(a6, b6, 0.0), fma(a7, b7, 0.0), fma(a8, b8, 0.0));
  let sc = exact_sum9(fma(b0, b0, 0.0), fma(b1, b1, 0.0), fma(b2, b2, 0.0), fma(b3, b3, 0.0), fma(b4, b4, 0.0), fma(b5, b5, 0.0), fma(b6, b6, 0.0), fma(b7, b7, 0.0), fma(b8, b8, 0.0));
  return vec3<f32>(sa, sb, sc);
}
@compute @workgroup_size(16, 16)
fn main(@builtin(global_invocation_id) gid: vec3<u32>) {
  if (gid.x >= p.width || gid.y >= p.height) { return; }
  let x = i32(gid.x); let y = i32(gid.y);
  let c = box3(x, y);
  let a = c.x; let b = c.y; let cc = c.z;
  eig[gid.y * p.width + gid.x] = fma(a, cc, 0.0) - fma(b, b, 0.0) - fma(p.k * (a + cc), a + cc, 0.0);   // 4.0.1 calcHarris: a*c - b*b - k*(a+c)*(a+c), products guarded against FMA contraction
}

)WGSL";
static const char* const k_harris_fused = R"WGSL(
// cov=(dx²,dx·dy,dy²) → 3×3 unnormalised box (RowSum then ColumnSum, BORDER_DEFAULT) → Harris: a*c - b*b - k*(a+c)*(a+c)  (calcHarris, corner.cpp)
// FUSED variant: Sobel dx/dy are recomputed in-kernel from the packed image (same expressions as sobel_dxdy.wgsl) instead of
// being written/read through two W*H f32 buffers (44 MB/frame at 1920x1440): bandwidth is the cost at throttled GPU clocks.
@group(0) @binding(0) var<storage, read> img: array<u32>;
@group(0) @binding(1) var<storage, read_write> eig: array<f32>;
@group(0) @binding(2) var<uniform> p: Params;
fn px(x: i32, y: i32) -> f32 { let xx = reflect101(x, i32(p.width)); let yy = reflect101(y, i32(p.height)); let c = u32(xx + 21); return f32((img[p.base + u32(yy + 21) * p.pwq + (c >> 2u)] >> ((c & 3u) * 8u)) & 255u); }
fn row_dx(x: i32, y: i32) -> f32 { return px(x + 1, y) - px(x - 1, y); }
fn row_dy(x: i32, y: i32, s: f32) -> f32 { return (fma(px(x - 1, y), s, 0.0) + fma(px(x, y), 2.0 * s, 0.0)) + fma(px(x + 1, y), s, 0.0); }
fn sdx(x0: i32, y0: i32) -> f32 { let x = reflect101(x0, i32(p.width)); let y = reflect101(y0, i32(p.height)); let h = i32(p.height); let s = p.scale;
  let ym = reflect101(y - 1, h); let yp = reflect101(y + 1, h); return fma(row_dx(x, ym) + row_dx(x, yp), s, fma(row_dx(x, y), 2.0 * s, 0.0)); }
fn sdy(x0: i32, y0: i32) -> f32 { let x = reflect101(x0, i32(p.width)); let y = reflect101(y0, i32(p.height)); let h = i32(p.height); let s = p.scale;
  let ym = reflect101(y - 1, h); let yp = reflect101(y + 1, h); return row_dy(x, yp, s) - row_dy(x, ym, s); }
// boxFilter(cov, 3x3, normalize=false) on CV_32F sums in DOUBLE (RowSum<float,double>/ColumnSum<double,float>) and casts
// once: = the correctly rounded f32 of the exact 9-term sum. Emulated with a signed 96-bit fixed-point accumulator.
struct Acc { w0: u32, w1: u32, w2: u32 };
fn acc_add(a: ptr<function, Acc>, m: u32, sh: u32) {   // a += m << sh  (m < 2^24, sh < 96)
  let k = sh >> 5u; let b = sh & 31u;
  let lo = m << b; let hi = select(0u, m >> (32u - b), b != 0u);
  if (k == 0u) {
    let s0 = (*a).w0 + lo; let c0 = select(0u, 1u, s0 < lo); (*a).w0 = s0;
    let t1 = (*a).w1 + hi; let c1a = select(0u, 1u, t1 < hi); let s1 = t1 + c0; let c1b = select(0u, 1u, s1 < t1); (*a).w1 = s1;
    (*a).w2 = (*a).w2 + c1a + c1b;
  } else if (k == 1u) {
    let s1 = (*a).w1 + lo; let c1 = select(0u, 1u, s1 < lo); (*a).w1 = s1; (*a).w2 = (*a).w2 + hi + c1;
  } else { (*a).w2 = (*a).w2 + lo; }
}
fn acc_neg(a: ptr<function, Acc>) {   // two's complement negate
  let n0 = ~(*a).w0; let n1 = ~(*a).w1; let n2 = ~(*a).w2;
  let s0 = n0 + 1u; let c0 = select(0u, 1u, s0 == 0u); let s1 = n1 + c0; let c1 = select(0u, 1u, c0 == 1u && s1 == 0u);
  (*a).w0 = s0; (*a).w1 = s1; (*a).w2 = n2 + c1;
}
fn bit96(S: Acc, bit: i32) -> u32 { let w = select(select(S.w0, S.w1, bit >= 32), S.w2, bit >= 64); return (w >> u32(bit & 31)) & 1u; }
fn finish_sum(pos: Acc, neg0: Acc, base: i32) -> f32 {
  var neg = neg0; acc_neg(&neg);
  var S = pos;
  { let s0 = S.w0 + neg.w0; let c0 = select(0u, 1u, s0 < neg.w0); let t1 = S.w1 + neg.w1; let c1a = select(0u, 1u, t1 < neg.w1); let s1 = t1 + c0; let c1b = select(0u, 1u, s1 < t1); S.w0 = s0; S.w1 = s1; S.w2 = S.w2 + neg.w2 + c1a + c1b; }
  var negative = false;
  if ((S.w2 & 0x80000000u) != 0u) { negative = true; acc_neg(&S); }
  if (S.w0 == 0u && S.w1 == 0u && S.w2 == 0u) { return 0.0; }
  var hbit: i32;
  if (S.w2 != 0u) { hbit = 64 + 31 - i32(countLeadingZeros(S.w2)); } else if (S.w1 != 0u) { hbit = 32 + 31 - i32(countLeadingZeros(S.w1)); } else { hbit = 31 - i32(countLeadingZeros(S.w0)); }
  let lowbit = hbit - 23;
  var mant: u32; var guard: u32 = 0u; var sticky: u32 = 0u;
  if (lowbit <= 0) { mant = S.w0 << u32(-lowbit); }
  else {
    let lb = u32(lowbit); let k = lb >> 5u; let b = lb & 31u;
    let wk = select(select(S.w0, S.w1, k == 1u), S.w2, k == 2u); let wk1 = select(select(S.w1, S.w2, k == 1u), 0u, k == 2u);
    mant = select((wk >> b) | (wk1 << (32u - b)), wk, b == 0u) & 0xffffffu;
    let gb = lb - 1u; let gk = gb >> 5u; let gbit = gb & 31u; let wg = select(select(S.w0, S.w1, gk == 1u), S.w2, gk == 2u);
    guard = (wg >> gbit) & 1u;
    let below = wg & ((1u << gbit) - 1u);
    var st = below != 0u;
    if (gk >= 1u && S.w0 != 0u) { st = true; }
    if (gk >= 2u && S.w1 != 0u) { st = true; }
    sticky = select(0u, 1u, st);
  }
  if (guard == 1u && (sticky == 1u || (mant & 1u) == 1u)) { mant += 1u; }
  let e2 = (base - 127 - 23) + lowbit;
  let r = ldexp(f32(mant), e2);
  return select(r, -r, negative);
}
// Fast path: all 9 terms within 36 exponent steps -> the exact sum fits in 64 bits (24 + 36 + 4 carry) -> two-word accumulator.
fn sum9_fast(t0: f32, t1: f32, t2: f32, t3: f32, t4: f32, t5: f32, t6: f32, t7: f32, t8: f32, base: i32) -> f32 {
  var plo: u32 = 0u; var phi: u32 = 0u; var nlo: u32 = 0u; var nhi: u32 = 0u;
  { let b = bitcast<u32>(t0); if ((b & 0x7fffffffu) != 0u) { let e = i32((b >> 23u) & 255u); var m = b & 0x7fffffu; var ee = e; if (e == 0) { ee = 1; } else { m |= 0x800000u; } let sh = u32(ee - base);
      let lo = select(m << sh, 0u, sh >= 32u); let hi = select(select(m >> (32u - sh), 0u, sh == 0u), m << (sh - 32u), sh >= 32u);
      if ((b & 0x80000000u) != 0u) { let s = nlo + lo; nhi = nhi + hi + select(0u, 1u, s < lo); nlo = s; } else { let s = plo + lo; phi = phi + hi + select(0u, 1u, s < lo); plo = s; } } }
  { let b = bitcast<u32>(t1); if ((b & 0x7fffffffu) != 0u) { let e = i32((b >> 23u) & 255u); var m = b & 0x7fffffu; var ee = e; if (e == 0) { ee = 1; } else { m |= 0x800000u; } let sh = u32(ee - base);
      let lo = select(m << sh, 0u, sh >= 32u); let hi = select(select(m >> (32u - sh), 0u, sh == 0u), m << (sh - 32u), sh >= 32u);
      if ((b & 0x80000000u) != 0u) { let s = nlo + lo; nhi = nhi + hi + select(0u, 1u, s < lo); nlo = s; } else { let s = plo + lo; phi = phi + hi + select(0u, 1u, s < lo); plo = s; } } }
  { let b = bitcast<u32>(t2); if ((b & 0x7fffffffu) != 0u) { let e = i32((b >> 23u) & 255u); var m = b & 0x7fffffu; var ee = e; if (e == 0) { ee = 1; } else { m |= 0x800000u; } let sh = u32(ee - base);
      let lo = select(m << sh, 0u, sh >= 32u); let hi = select(select(m >> (32u - sh), 0u, sh == 0u), m << (sh - 32u), sh >= 32u);
      if ((b & 0x80000000u) != 0u) { let s = nlo + lo; nhi = nhi + hi + select(0u, 1u, s < lo); nlo = s; } else { let s = plo + lo; phi = phi + hi + select(0u, 1u, s < lo); plo = s; } } }
  { let b = bitcast<u32>(t3); if ((b & 0x7fffffffu) != 0u) { let e = i32((b >> 23u) & 255u); var m = b & 0x7fffffu; var ee = e; if (e == 0) { ee = 1; } else { m |= 0x800000u; } let sh = u32(ee - base);
      let lo = select(m << sh, 0u, sh >= 32u); let hi = select(select(m >> (32u - sh), 0u, sh == 0u), m << (sh - 32u), sh >= 32u);
      if ((b & 0x80000000u) != 0u) { let s = nlo + lo; nhi = nhi + hi + select(0u, 1u, s < lo); nlo = s; } else { let s = plo + lo; phi = phi + hi + select(0u, 1u, s < lo); plo = s; } } }
  { let b = bitcast<u32>(t4); if ((b & 0x7fffffffu) != 0u) { let e = i32((b >> 23u) & 255u); var m = b & 0x7fffffu; var ee = e; if (e == 0) { ee = 1; } else { m |= 0x800000u; } let sh = u32(ee - base);
      let lo = select(m << sh, 0u, sh >= 32u); let hi = select(select(m >> (32u - sh), 0u, sh == 0u), m << (sh - 32u), sh >= 32u);
      if ((b & 0x80000000u) != 0u) { let s = nlo + lo; nhi = nhi + hi + select(0u, 1u, s < lo); nlo = s; } else { let s = plo + lo; phi = phi + hi + select(0u, 1u, s < lo); plo = s; } } }
  { let b = bitcast<u32>(t5); if ((b & 0x7fffffffu) != 0u) { let e = i32((b >> 23u) & 255u); var m = b & 0x7fffffu; var ee = e; if (e == 0) { ee = 1; } else { m |= 0x800000u; } let sh = u32(ee - base);
      let lo = select(m << sh, 0u, sh >= 32u); let hi = select(select(m >> (32u - sh), 0u, sh == 0u), m << (sh - 32u), sh >= 32u);
      if ((b & 0x80000000u) != 0u) { let s = nlo + lo; nhi = nhi + hi + select(0u, 1u, s < lo); nlo = s; } else { let s = plo + lo; phi = phi + hi + select(0u, 1u, s < lo); plo = s; } } }
  { let b = bitcast<u32>(t6); if ((b & 0x7fffffffu) != 0u) { let e = i32((b >> 23u) & 255u); var m = b & 0x7fffffu; var ee = e; if (e == 0) { ee = 1; } else { m |= 0x800000u; } let sh = u32(ee - base);
      let lo = select(m << sh, 0u, sh >= 32u); let hi = select(select(m >> (32u - sh), 0u, sh == 0u), m << (sh - 32u), sh >= 32u);
      if ((b & 0x80000000u) != 0u) { let s = nlo + lo; nhi = nhi + hi + select(0u, 1u, s < lo); nlo = s; } else { let s = plo + lo; phi = phi + hi + select(0u, 1u, s < lo); plo = s; } } }
  { let b = bitcast<u32>(t7); if ((b & 0x7fffffffu) != 0u) { let e = i32((b >> 23u) & 255u); var m = b & 0x7fffffu; var ee = e; if (e == 0) { ee = 1; } else { m |= 0x800000u; } let sh = u32(ee - base);
      let lo = select(m << sh, 0u, sh >= 32u); let hi = select(select(m >> (32u - sh), 0u, sh == 0u), m << (sh - 32u), sh >= 32u);
      if ((b & 0x80000000u) != 0u) { let s = nlo + lo; nhi = nhi + hi + select(0u, 1u, s < lo); nlo = s; } else { let s = plo + lo; phi = phi + hi + select(0u, 1u, s < lo); plo = s; } } }
  { let b = bitcast<u32>(t8); if ((b & 0x7fffffffu) != 0u) { let e = i32((b >> 23u) & 255u); var m = b & 0x7fffffu; var ee = e; if (e == 0) { ee = 1; } else { m |= 0x800000u; } let sh = u32(ee - base);
      let lo = select(m << sh, 0u, sh >= 32u); let hi = select(select(m >> (32u - sh), 0u, sh == 0u), m << (sh - 32u), sh >= 32u);
      if ((b & 0x80000000u) != 0u) { let s = nlo + lo; nhi = nhi + hi + select(0u, 1u, s < lo); nlo = s; } else { let s = plo + lo; phi = phi + hi + select(0u, 1u, s < lo); plo = s; } } }
  // S = P - N (signed 64)
  var negative = false; var lo: u32; var hi: u32;
  if (phi > nhi || (phi == nhi && plo >= nlo)) { lo = plo - nlo; hi = phi - nhi - select(0u, 1u, plo < nlo); }
  else { negative = true; lo = nlo - plo; hi = nhi - phi - select(0u, 1u, nlo < plo); }
  if (lo == 0u && hi == 0u) { return 0.0; }
  var hbit: i32; if (hi != 0u) { hbit = 32 + 31 - i32(countLeadingZeros(hi)); } else { hbit = 31 - i32(countLeadingZeros(lo)); }
  let lowbit = hbit - 23;
  var mant: u32; var guard: u32 = 0u; var sticky: u32 = 0u;
  if (lowbit <= 0) { mant = lo << u32(-lowbit); }
  else {
    let lb = u32(lowbit);
    mant = select(select((lo >> lb) | (hi << (32u - lb)), lo, lb == 0u), hi >> (lb - 32u), lb >= 32u) & 0xffffffu;
    let gb = lb - 1u;
    guard = select((lo >> gb) & 1u, (hi >> (gb - 32u)) & 1u, gb >= 32u);
    let below_lo = select(lo & ((1u << gb) - 1u), lo, gb >= 32u);
    let below_hi = select(0u, hi & ((1u << (gb - 32u)) - 1u), gb >= 32u);
    sticky = select(0u, 1u, (below_lo | below_hi) != 0u);
  }
  if (guard == 1u && (sticky == 1u || (mant & 1u) == 1u)) { mant += 1u; }
  let r = ldexp(f32(mant), (base - 127 - 23) + lowbit);
  return select(r, -r, negative);
}
// Error-free fast path (Knuth TwoSum cascade, strict math: adds/subs only, no contraction possible). Accumulate s with
// TwoSum, feed every error into a second TwoSum accumulator e; if no error ever escapes the second level (all err2 == 0) then
// s + e is EXACTLY the real sum, and fl(s + e) is its correctly rounded float. Otherwise fall back to the integer path.
fn two_sum(a: f32, b: f32) -> vec2<f32> { let s = a + b; let bb = s - a; return vec2<f32>(s, (a - (s - bb)) + (b - bb)); }
fn sum9_ef(t0: f32, t1: f32, t2: f32, t3: f32, t4: f32, t5: f32, t6: f32, t7: f32, t8: f32) -> vec2<f32> {   // (result, ok)
  var s = t0; var e: f32 = 0.0; var lost: f32 = 0.0;
  { let r = two_sum(s, t1); s = r.x; let q = two_sum(e, r.y); e = q.x; lost += abs(q.y); }
  { let r = two_sum(s, t2); s = r.x; let q = two_sum(e, r.y); e = q.x; lost += abs(q.y); }
  { let r = two_sum(s, t3); s = r.x; let q = two_sum(e, r.y); e = q.x; lost += abs(q.y); }
  { let r = two_sum(s, t4); s = r.x; let q = two_sum(e, r.y); e = q.x; lost += abs(q.y); }
  { let r = two_sum(s, t5); s = r.x; let q = two_sum(e, r.y); e = q.x; lost += abs(q.y); }
  { let r = two_sum(s, t6); s = r.x; let q = two_sum(e, r.y); e = q.x; lost += abs(q.y); }
  { let r = two_sum(s, t7); s = r.x; let q = two_sum(e, r.y); e = q.x; lost += abs(q.y); }
  { let r = two_sum(s, t8); s = r.x; let q = two_sum(e, r.y); e = q.x; lost += abs(q.y); }
  return vec2<f32>(s + e, select(0.0, 1.0, lost == 0.0));
}
fn exact_sum9(t0: f32, t1: f32, t2: f32, t3: f32, t4: f32, t5: f32, t6: f32, t7: f32, t8: f32) -> f32 {
  var maxe: i32 = -1; var mine: i32 = 999;
  { let b = bitcast<u32>(t0); if ((b & 0x7fffffffu) != 0u) { let e = max(i32((b >> 23u) & 255u), 1); maxe = max(maxe, e); mine = min(mine, e); } }
  { let b = bitcast<u32>(t1); if ((b & 0x7fffffffu) != 0u) { let e = max(i32((b >> 23u) & 255u), 1); maxe = max(maxe, e); mine = min(mine, e); } }
  { let b = bitcast<u32>(t2); if ((b & 0x7fffffffu) != 0u) { let e = max(i32((b >> 23u) & 255u), 1); maxe = max(maxe, e); mine = min(mine, e); } }
  { let b = bitcast<u32>(t3); if ((b & 0x7fffffffu) != 0u) { let e = max(i32((b >> 23u) & 255u), 1); maxe = max(maxe, e); mine = min(mine, e); } }
  { let b = bitcast<u32>(t4); if ((b & 0x7fffffffu) != 0u) { let e = max(i32((b >> 23u) & 255u), 1); maxe = max(maxe, e); mine = min(mine, e); } }
  { let b = bitcast<u32>(t5); if ((b & 0x7fffffffu) != 0u) { let e = max(i32((b >> 23u) & 255u), 1); maxe = max(maxe, e); mine = min(mine, e); } }
  { let b = bitcast<u32>(t6); if ((b & 0x7fffffffu) != 0u) { let e = max(i32((b >> 23u) & 255u), 1); maxe = max(maxe, e); mine = min(mine, e); } }
  { let b = bitcast<u32>(t7); if ((b & 0x7fffffffu) != 0u) { let e = max(i32((b >> 23u) & 255u), 1); maxe = max(maxe, e); mine = min(mine, e); } }
  { let b = bitcast<u32>(t8); if ((b & 0x7fffffffu) != 0u) { let e = max(i32((b >> 23u) & 255u), 1); maxe = max(maxe, e); mine = min(mine, e); } }
  if (maxe < 0) { return 0.0; }
  { let r = sum9_ef(t0, t1, t2, t3, t4, t5, t6, t7, t8); if (r.y != 0.0) { return r.x; } }
  if (maxe - mine <= 36) { return sum9_fast(t0, t1, t2, t3, t4, t5, t6, t7, t8, mine); }
  var base = mine; if (maxe - mine > 71) { base = maxe - 64; }
  var pos = Acc(0u, 0u, 0u); var neg = Acc(0u, 0u, 0u);
  { let b = bitcast<u32>(t0); if ((b & 0x7fffffffu) != 0u) { let e = i32((b >> 23u) & 255u); var m = b & 0x7fffffu; var ee = e; if (e == 0) { ee = 1; } else { m |= 0x800000u; } let d = ee - base; if (d >= 0) { if ((b & 0x80000000u) != 0u) { acc_add(&neg, m, u32(d)); } else { acc_add(&pos, m, u32(d)); } } } }
  { let b = bitcast<u32>(t1); if ((b & 0x7fffffffu) != 0u) { let e = i32((b >> 23u) & 255u); var m = b & 0x7fffffu; var ee = e; if (e == 0) { ee = 1; } else { m |= 0x800000u; } let d = ee - base; if (d >= 0) { if ((b & 0x80000000u) != 0u) { acc_add(&neg, m, u32(d)); } else { acc_add(&pos, m, u32(d)); } } } }
  { let b = bitcast<u32>(t2); if ((b & 0x7fffffffu) != 0u) { let e = i32((b >> 23u) & 255u); var m = b & 0x7fffffu; var ee = e; if (e == 0) { ee = 1; } else { m |= 0x800000u; } let d = ee - base; if (d >= 0) { if ((b & 0x80000000u) != 0u) { acc_add(&neg, m, u32(d)); } else { acc_add(&pos, m, u32(d)); } } } }
  { let b = bitcast<u32>(t3); if ((b & 0x7fffffffu) != 0u) { let e = i32((b >> 23u) & 255u); var m = b & 0x7fffffu; var ee = e; if (e == 0) { ee = 1; } else { m |= 0x800000u; } let d = ee - base; if (d >= 0) { if ((b & 0x80000000u) != 0u) { acc_add(&neg, m, u32(d)); } else { acc_add(&pos, m, u32(d)); } } } }
  { let b = bitcast<u32>(t4); if ((b & 0x7fffffffu) != 0u) { let e = i32((b >> 23u) & 255u); var m = b & 0x7fffffu; var ee = e; if (e == 0) { ee = 1; } else { m |= 0x800000u; } let d = ee - base; if (d >= 0) { if ((b & 0x80000000u) != 0u) { acc_add(&neg, m, u32(d)); } else { acc_add(&pos, m, u32(d)); } } } }
  { let b = bitcast<u32>(t5); if ((b & 0x7fffffffu) != 0u) { let e = i32((b >> 23u) & 255u); var m = b & 0x7fffffu; var ee = e; if (e == 0) { ee = 1; } else { m |= 0x800000u; } let d = ee - base; if (d >= 0) { if ((b & 0x80000000u) != 0u) { acc_add(&neg, m, u32(d)); } else { acc_add(&pos, m, u32(d)); } } } }
  { let b = bitcast<u32>(t6); if ((b & 0x7fffffffu) != 0u) { let e = i32((b >> 23u) & 255u); var m = b & 0x7fffffu; var ee = e; if (e == 0) { ee = 1; } else { m |= 0x800000u; } let d = ee - base; if (d >= 0) { if ((b & 0x80000000u) != 0u) { acc_add(&neg, m, u32(d)); } else { acc_add(&pos, m, u32(d)); } } } }
  { let b = bitcast<u32>(t7); if ((b & 0x7fffffffu) != 0u) { let e = i32((b >> 23u) & 255u); var m = b & 0x7fffffu; var ee = e; if (e == 0) { ee = 1; } else { m |= 0x800000u; } let d = ee - base; if (d >= 0) { if ((b & 0x80000000u) != 0u) { acc_add(&neg, m, u32(d)); } else { acc_add(&pos, m, u32(d)); } } } }
  { let b = bitcast<u32>(t8); if ((b & 0x7fffffffu) != 0u) { let e = i32((b >> 23u) & 255u); var m = b & 0x7fffffu; var ee = e; if (e == 0) { ee = 1; } else { m |= 0x800000u; } let d = ee - base; if (d >= 0) { if ((b & 0x80000000u) != 0u) { acc_add(&neg, m, u32(d)); } else { acc_add(&pos, m, u32(d)); } } } }
  return finish_sum(pos, neg, base);
}
fn box3(x: i32, y: i32) -> vec3<f32> {
  let a0 = sdx(x - 1, y - 1); let a1 = sdx(x, y - 1); let a2 = sdx(x + 1, y - 1); let a3 = sdx(x - 1, y); let a4 = sdx(x, y); let a5 = sdx(x + 1, y); let a6 = sdx(x - 1, y + 1); let a7 = sdx(x, y + 1); let a8 = sdx(x + 1, y + 1);
  let b0 = sdy(x - 1, y - 1); let b1 = sdy(x, y - 1); let b2 = sdy(x + 1, y - 1); let b3 = sdy(x - 1, y); let b4 = sdy(x, y); let b5 = sdy(x + 1, y); let b6 = sdy(x - 1, y + 1); let b7 = sdy(x, y + 1); let b8 = sdy(x + 1, y + 1);
  let sa = exact_sum9(fma(a0, a0, 0.0), fma(a1, a1, 0.0), fma(a2, a2, 0.0), fma(a3, a3, 0.0), fma(a4, a4, 0.0), fma(a5, a5, 0.0), fma(a6, a6, 0.0), fma(a7, a7, 0.0), fma(a8, a8, 0.0));
  let sb = exact_sum9(fma(a0, b0, 0.0), fma(a1, b1, 0.0), fma(a2, b2, 0.0), fma(a3, b3, 0.0), fma(a4, b4, 0.0), fma(a5, b5, 0.0), fma(a6, b6, 0.0), fma(a7, b7, 0.0), fma(a8, b8, 0.0));
  let sc = exact_sum9(fma(b0, b0, 0.0), fma(b1, b1, 0.0), fma(b2, b2, 0.0), fma(b3, b3, 0.0), fma(b4, b4, 0.0), fma(b5, b5, 0.0), fma(b6, b6, 0.0), fma(b7, b7, 0.0), fma(b8, b8, 0.0));
  return vec3<f32>(sa, sb, sc);
}
@compute @workgroup_size(16, 16)
fn main(@builtin(global_invocation_id) gid: vec3<u32>) {
  if (gid.x >= p.width || gid.y >= p.height) { return; }
  let x = i32(gid.x); let y = i32(gid.y);
  let c = box3(x, y);
  let a = c.x; let b = c.y; let cc = c.z;
  eig[gid.y * p.width + gid.x] = fma(a, cc, 0.0) - fma(b, b, 0.0) - fma(p.k * (a + cc), a + cc, 0.0);   // 4.0.1 calcHarris: a*c - b*b - k*(a+c)*(a+c), products guarded against FMA contraction
}

)WGSL";
static const char* const k_gftt_max = R"WGSL(
@group(0) @binding(0) var<storage, read> eig: array<f32>;
@group(0) @binding(1) var<storage, read_write> partial: array<f32>;
@group(0) @binding(2) var<uniform> p: Params;
var<workgroup> sh: array<f32, 256>;
@compute @workgroup_size(256)
fn main(@builtin(global_invocation_id) gid: vec3<u32>, @builtin(local_invocation_id) lid: vec3<u32>, @builtin(workgroup_id) wg: vec3<u32>, @builtin(num_workgroups) nw: vec3<u32>) {
  let n = p.width * p.height; let stride = 256u * nw.x; var m = -3.4e38; var i = gid.x;
  loop { if (i >= n) { break; } m = max(m, eig[i]); i = i + stride; }
  sh[lid.x] = m; workgroupBarrier();
  for (var s = 128u; s > 0u; s = s >> 1u) { if (lid.x < s) { sh[lid.x] = max(sh[lid.x], sh[lid.x + s]); } workgroupBarrier(); }
  if (lid.x == 0u) { partial[wg.x] = sh[0]; }
}

)WGSL";
static const char* const k_gftt_thr = R"WGSL(
// threshold = (float)(maxVal * qualityLevel): maxVal is the double from minMaxLoc (== the float max here), qualityLevel a double.
// One workgroup reduces the per-group partial maxima and forms the product with the double quality split as (q_hi + q_lo):
// p = mx*q_hi (rounded), e = exact error of that product, thr = p + (e + mx*q_lo) — the correctly rounded float of the
// double product except when the product lies within ~2^-53 of a float rounding boundary.
@group(0) @binding(0) var<storage, read> partial: array<f32>;
@group(0) @binding(1) var<storage, read_write> thr: array<f32>;
@group(0) @binding(2) var<uniform> qsplit: vec4<f32>;   // (q_hi, q_lo, 0, 0)
var<workgroup> sh: array<f32, 256>;
@compute @workgroup_size(256)
fn main(@builtin(local_invocation_index) lid: u32) {
  var m: f32 = -3.4e38;
  let n = arrayLength(&partial);
  for (var i: u32 = lid; i < n; i += 256u) { m = max(m, partial[i]); }
  sh[lid] = m;
  workgroupBarrier();
  for (var s: u32 = 128u; s > 0u; s >>= 1u) { if (lid < s) { sh[lid] = max(sh[lid], sh[lid + s]); } workgroupBarrier(); }
  if (lid == 0u) {
    let mx = sh[0];
    let pr = fma(mx, qsplit.x, 0.0); let e = fma(mx, qsplit.x, -pr);
    thr[0] = pr + (e + fma(mx, qsplit.y, 0.0));
  }
}

)WGSL";
static const char* const k_gftt_find = R"WGSL(
// findCorners (gftt.cl, 4.0.1): interior pixels (1..rows-2, 1..cols-2), val > threshold, strict 3×3 NMS (val == max of 9),
// atomic append of (val, packed y | x<<16). Threshold = maxEig * qualityLevel (host writes it into thr[0]).
@group(0) @binding(0) var<storage, read> eig: array<f32>;
@group(0) @binding(1) var<storage, read> thr: array<f32>;
@group(0) @binding(2) var<storage, read_write> count: atomic<u32>;
@group(0) @binding(3) var<storage, read_write> corners: array<vec2<u32>>;   // (bitcast<u32>(val), y | x<<16)
@group(0) @binding(4) var<uniform> p: Params;
fn e(x: u32, y: u32) -> f32 { return eig[y * p.width + x]; }
@compute @workgroup_size(16, 16)
fn main(@builtin(global_invocation_id) gid: vec3<u32>) {
  let x = gid.x + 1u; let y = gid.y + 1u;
  if (x >= p.width - 1u || y >= p.height - 1u) { return; }
  let v = e(x, y);
  if (v > thr[0]) {
    var m = v;
    m = max(e(x-1u,y-1u), m); m = max(e(x,y-1u), m); m = max(e(x+1u,y-1u), m);
    m = max(e(x-1u,y), m);                          m = max(e(x+1u,y), m);
    m = max(e(x-1u,y+1u), m); m = max(e(x,y+1u), m); m = max(e(x+1u,y+1u), m);
    if (v == m) { let ind = atomicAdd(&count, 1u); if (ind < p.max_corners) { corners[ind] = vec2<u32>(bitcast<u32>(v), y | (x << 16u)); } }
  }
}

)WGSL";
static const char* const k_lk_common = R"WGSL(
// Shared by the M2/M3 kernels. Images are PACKED u8 (4 px per u32), stored PADDED:
// (pw = w + 2*pad) x (ph = h + 2*pad) with the level image at offset (pad, pad) — the exact layout
// OpenCV 4.0.1 buildOpticalFlowPyramid produces (winSize border 21, REFLECT_101|ISOLATED for the
// image, CONSTANT 0 for the Scharr derivative).
struct P {
  w: u32, h: u32, pw: u32, ph: u32,          // this level (interior / padded)
  w2: u32, h2: u32, pw2: u32, ph2: u32,      // next level (pyrdown target)
  tiles_x: u32, tiles_y: u32, tw: u32, th: u32,   // CLAHE
  inv_tw: f32, inv_th: f32, lut_scale: f32, clip: u32,
  base: u32, base2: u32, dbase: u32, pwq: u32,   // base: word offset of this level in the packed-u8 pyramid; dbase: u32 offset in the deriv buffer; pwq: words per padded row
  pwq2: u32, r0: u32, r1: u32, r2: u32,          // pwq2: words per padded row of the next level
};
// Packed image layout: one u32 holds 4 horizontally adjacent padded pixels (byte k = column 4*word+k). Derivatives: one u32 per
// pixel = (dx & 0xffff) | (dy << 16), i16 each. Writers own whole words (one thread per word) — no read-modify-write races.
fn ld8(buf_word: u32, x: u32) -> u32 { return (buf_word >> ((x & 3u) * 8u)) & 255u; }
const PAD: i32 = 21;
// cv::borderInterpolate(p, len, BORDER_REFLECT_101)
fn reflect101(p0: i32, len: i32) -> i32 {
  var p = p0;
  if (len == 1) { return 0; }
  loop {
    if (p < 0) { p = -p; }
    else if (p >= len) { p = len - 1 - (p - len) - 1; }
    else { break; }
  }
  return p;
}

)WGSL";
static const char* const k_clahe_hist = R"WGSL(
// CLAHE_CalcLut_Body part 1: per-tile 256-bin histogram (one workgroup per tile).
@group(0) @binding(0) var<storage, read> src: array<u32>;               // w*h interior, PACKED u8 (4 px per u32)
@group(0) @binding(1) var<storage, read_write> hist: array<atomic<u32>>; // tiles*256
@group(0) @binding(2) var<uniform> p: P;
var<workgroup> lh: array<atomic<u32>, 256>;
@compute @workgroup_size(256)
fn main(@builtin(local_invocation_index) lid: u32, @builtin(workgroup_id) wg: vec3<u32>) {
  atomicStore(&lh[lid], 0u);
  workgroupBarrier();
  let tx = wg.x; let ty = wg.y;
  let n = p.tw * p.th;
  for (var i: u32 = lid; i < n; i += 256u) {
    let x = tx * p.tw + (i % p.tw);
    let y = ty * p.th + (i / p.tw);
    let i = y * p.w + x;
    atomicAdd(&lh[(src[i >> 2u] >> ((i & 3u) * 8u)) & 255u], 1u);
  }
  workgroupBarrier();
  let tile = ty * p.tiles_x + tx;
  atomicStore(&hist[tile * 256u + lid], atomicLoad(&lh[lid]));
}

)WGSL";
static const char* const k_clahe_lut = R"WGSL(
// CLAHE_CalcLut_Body part 2: clip, redistribute, cumulative LUT (one thread per tile; 4.0.1 clahe.cpp).
@group(0) @binding(0) var<storage, read> hist: array<u32>;
@group(0) @binding(1) var<storage, read_write> lut: array<u32>;
@group(0) @binding(2) var<uniform> p: P;
@compute @workgroup_size(64)
fn main(@builtin(global_invocation_id) gid: vec3<u32>) {
  let tile = gid.x;
  if (tile >= p.tiles_x * p.tiles_y) { return; }
  var th: array<i32, 256>;
  for (var i: u32 = 0u; i < 256u; i++) { th[i] = i32(hist[tile * 256u + i]); }
  if (p.clip > 0u) {
    let clip = i32(p.clip);
    var clipped: i32 = 0;
    for (var i: u32 = 0u; i < 256u; i++) {
      if (th[i] > clip) { clipped += th[i] - clip; th[i] = clip; }
    }
    let redistBatch = clipped / 256;
    var residual = clipped - redistBatch * 256;
    for (var i: u32 = 0u; i < 256u; i++) { th[i] += redistBatch; }
    if (residual != 0) {
      let residualStep = max(256 / residual, 1);
      var i: i32 = 0;
      loop {
        if (!(i < 256 && residual > 0)) { break; }
        th[i] += 1;
        i += residualStep; residual -= 1;
      }
    }
  }
  var sum: i32 = 0;
  for (var i: u32 = 0u; i < 256u; i++) {
    sum += th[i];
    let v = round(f32(sum) * p.lut_scale);          // saturate_cast<uchar>(float): cvRound = lrint (half-even)
    lut[tile * 256u + i] = u32(clamp(v, 0.0, 255.0));
  }
}

)WGSL";
static const char* const k_clahe_interp = R"WGSL(
// CLAHE_Interpolation_Body. Host-computed weight tables (colt per column, rowt per row), products guarded with fma(x,y,0.0).
// One thread per PADDED WORD of level 0: writes the 4 bytes of that word; border bytes are the interpolated value at the
// REFLECT_101 coordinate (== copyMakeBorder after the fact), so no pad pass is needed.
@group(0) @binding(0) var<storage, read> src: array<u32>;         // packed u8, w*h interior (unpadded)
@group(0) @binding(1) var<storage, read> lut: array<u32>;
@group(0) @binding(2) var<storage, read_write> dst: array<u32>;   // packed padded level 0 at base
@group(0) @binding(3) var<uniform> p: P;
@group(0) @binding(4) var<storage, read> colt: array<vec4<f32>>;  // per column: (ind1, ind2, xa, xa1)
@group(0) @binding(5) var<storage, read> rowt: array<vec4<f32>>;  // per row: (ty1*tilesX*256, ty2*tilesX*256, ya, ya1)
fn clahe_px(x: u32, y: u32) -> u32 {
  let ct = colt[x]; let rt = rowt[y];
  let i = y * p.w + x;
  let v = i32((src[i >> 2u] >> ((i & 3u) * 8u)) & 255u);
  let ind1 = i32(ct.x) + v; let ind2 = i32(ct.y) + v; let xa = ct.z; let xa1 = ct.w;
  let l1 = i32(rt.x); let l2 = i32(rt.y); let ya = rt.z; let ya1 = rt.w;
  let t1 = fma(f32(lut[l1 + ind1]), xa1, 0.0) + fma(f32(lut[l1 + ind2]), xa, 0.0);
  let t2 = fma(f32(lut[l2 + ind1]), xa1, 0.0) + fma(f32(lut[l2 + ind2]), xa, 0.0);
  let res = fma(t1, ya1, 0.0) + fma(t2, ya, 0.0);
  return u32(clamp(round(res), 0.0, 255.0));
}
@compute @workgroup_size(16, 16)
fn main(@builtin(global_invocation_id) gid: vec3<u32>) {
  let wq = gid.x; let py = gid.y;                  // padded word column, padded row
  if (wq >= p.pwq || py >= p.ph) { return; }
  let yi = reflect101(i32(py) - PAD, i32(p.h));   // border bytes = REFLECT_101 of the interior (the pad pass, fused)
  var word: u32 = 0u;
  for (var k: u32 = 0u; k < 4u; k++) {
    let xi = reflect101(i32(wq * 4u + k) - PAD, i32(p.w));
    word |= clahe_px(u32(xi), u32(yi)) << (k * 8u);
  }
  dst[p.base + py * p.pwq + wq] = word;
}

)WGSL";
static const char* const k_pad_reflect101 = R"WGSL(
// copyMakeBorder(level, 21, BORDER_REFLECT_101 | BORDER_ISOLATED) on the packed layout. One thread per padded word; words that
// are fully interior are left untouched; mixed/border words are rebuilt byte by byte (interior bytes kept, border bytes reflected).
@group(0) @binding(0) var<storage, read_write> img: array<u32>;
@group(0) @binding(1) var<uniform> p: P;
fn px(x: i32, y: i32) -> u32 { let c = u32(x + PAD); return ld8(img[p.base + u32(y + PAD) * p.pwq + (c >> 2u)], c); }   // interior coords
@compute @workgroup_size(16, 16)
fn main(@builtin(global_invocation_id) gid: vec3<u32>) {
  let wq = gid.x; let py = gid.y;
  if (wq >= p.pwq || py >= p.ph) { return; }
  let yi = i32(py) - PAD;
  let x0 = i32(wq * 4u) - PAD;
  let row_interior = yi >= 0 && yi < i32(p.h);
  if (row_interior && x0 >= 0 && x0 + 3 < i32(p.w)) { return; }   // fully interior word
  let idx = p.base + py * p.pwq + wq;
  let old = img[idx];
  var word: u32 = 0u;
  for (var k: u32 = 0u; k < 4u; k++) {
    let xi = x0 + i32(k);
    var v: u32;
    if (row_interior && xi >= 0 && xi < i32(p.w)) { v = (old >> (k * 8u)) & 255u; }
    else { v = px(reflect101(xi, i32(p.w)), reflect101(yi, i32(p.h))); }
    word |= v << (k * 8u);
  }
  img[idx] = word;
}

)WGSL";
static const char* const k_pyrdown = R"WGSL(
// pyrDown_<FixPtCast<uchar,8>, PyrDownNoVec<int,uchar>> cn=1, BORDER_REFLECT_101 (4.0.1 pyramids.cpp), packed layout.
// One thread per padded word of level l+1; border bytes reflected (no pad pass).
@group(0) @binding(0) var<storage, read_write> img: array<u32>;   // reads level l (base, pwq), writes level l+1 (base2, pwq2)
@group(0) @binding(1) var<uniform> p: P;
fn s(x: i32, y: i32) -> i32 {
  let c = u32(reflect101(x, i32(p.w)) + PAD);
  return i32(ld8(img[p.base + u32(reflect101(y, i32(p.h)) + PAD) * p.pwq + (c >> 2u)], c));
}
fn row(y: i32, x: i32) -> i32 { return s(2 * x, y) * 6 + (s(2 * x - 1, y) + s(2 * x + 1, y)) * 4 + s(2 * x - 2, y) + s(2 * x + 2, y); }
fn down_px(x: i32, y: i32) -> u32 {
  let r0 = row(2 * y - 2, x); let r1 = row(2 * y - 1, x); let r2 = row(2 * y, x); let r3 = row(2 * y + 1, x); let r4 = row(2 * y + 2, x);
  return u32((r2 * 6 + (r1 + r3) * 4 + r0 + r4 + 128) >> 8u);
}
@compute @workgroup_size(16, 16)
fn main(@builtin(global_invocation_id) gid: vec3<u32>) {
  let wq = gid.x; let py = gid.y;
  if (wq >= p.pwq2 || py >= p.ph2) { return; }
  let yi = reflect101(i32(py) - PAD, i32(p.h2));   // border bytes = REFLECT_101 of the level-(l+1) interior (pad pass fused)
  var word: u32 = 0u;
  for (var k: u32 = 0u; k < 4u; k++) {
    let xi = reflect101(i32(wq * 4u + k) - PAD, i32(p.w2));
    word |= down_px(xi, yi) << (k * 8u);
  }
  img[p.base2 + py * p.pwq2 + wq] = word;
}

)WGSL";
static const char* const k_scharr = R"WGSL(
// calcSharrDeriv (4.0.1 lkpyramid.cpp): dx/dy as i16 pairs packed in one u32 per padded pixel ((dx & 0xffff) | (dy << 16));
// ring of 21 = 0 (derivBorder CONSTANT).
@group(0) @binding(0) var<storage, read> src: array<u32>;         // packed padded level
@group(0) @binding(1) var<storage, read_write> deriv: array<u32>; // one u32 per padded pixel at dbase, pitch pw
@group(0) @binding(2) var<uniform> pl: array<P, 4>;   // one P per level, z = level
var<private> p: P;
fn s(x: i32, y: i32) -> i32 {
  let c = u32(reflect101(x, i32(p.w)) + PAD);
  return i32(ld8(src[p.base + u32(reflect101(y, i32(p.h)) + PAD) * p.pwq + (c >> 2u)], c));
}
fn t0(x: i32, y: i32) -> i32 { return (s(x, y - 1) + s(x, y + 1)) * 3 + s(x, y) * 10; }
fn t1(x: i32, y: i32) -> i32 { return s(x, y + 1) - s(x, y - 1); }
@compute @workgroup_size(16, 16, 1)
fn main(@builtin(global_invocation_id) gid: vec3<u32>) {
  p = pl[gid.z];
  let x = i32(gid.x); let y = i32(gid.y);
  if (x >= i32(p.pw) || y >= i32(p.ph)) { return; }
  let xi = x - PAD; let yi = y - PAD;
  let o = p.dbase + u32(y) * p.pw + u32(x);
  if (xi < 0 || yi < 0 || xi >= i32(p.w) || yi >= i32(p.h)) { deriv[o] = 0u; return; }
  let dx = t0(xi + 1, yi) - t0(xi - 1, yi);
  let dy = (t1(xi + 1, yi) + t1(xi - 1, yi)) * 3 + t1(xi, yi) * 10;
  deriv[o] = (u32(dx) & 0xffffu) | (u32(dy) << 16u);
}

)WGSL";
static const char* const k_pack_u8 = R"WGSL(
// Level-0 interior (packed padded) -> contiguous packed u8 (w*h bytes) for readback. One thread per output word.
@group(0) @binding(0) var<storage, read> img: array<u32>;
@group(0) @binding(1) var<storage, read_write> outp: array<u32>;
@group(0) @binding(2) var<uniform> p: P;
@compute @workgroup_size(256)
fn main(@builtin(global_invocation_id) gid: vec3<u32>) {
  let n = p.w * p.h; let i4 = gid.x;
  if (i4 * 4u >= n) { return; }
  var word: u32 = 0u;
  for (var k: u32 = 0u; k < 4u; k++) {
    let i = i4 * 4u + k;
    if (i < n) { let x = i % p.w; let y = i / p.w; let c = x + u32(PAD); word |= ld8(img[p.base + (y + u32(PAD)) * p.pwq + (c >> 2u)], c) << (k * 8u); }
  }
  outp[i4] = word;
}

)WGSL";
static const char* const k_unpack_u8 = R"WGSL(
// Packed contiguous u8 (already CLAHE'd) -> level-0 interior of the packed padded buffer. One thread per padded word.
@group(0) @binding(0) var<storage, read> src: array<u32>;
@group(0) @binding(1) var<storage, read_write> dst: array<u32>;
@group(0) @binding(2) var<uniform> p: P;
@compute @workgroup_size(16, 16)
fn main(@builtin(global_invocation_id) gid: vec3<u32>) {
  let wq = gid.x; let py = gid.y;
  if (wq >= p.pwq || py >= p.ph) { return; }
  let yi = reflect101(i32(py) - PAD, i32(p.h));
  var word: u32 = 0u;
  for (var k: u32 = 0u; k < 4u; k++) {
    let xi = reflect101(i32(wq * 4u + k) - PAD, i32(p.w)); let i = u32(yi) * p.w + u32(xi);
    word |= ((src[i >> 2u] >> ((i & 3u) * 8u)) & 255u) << (k * 8u);
  }
  dst[p.base + py * p.pwq + wq] = word;
}

)WGSL";
static const char* const k_lk_track = R"WGSL(
// Sparse pyramidal LK, one thread per point, all levels in-thread. Bit-for-bit port of OpenCV 4.0.1
// cv::detail::LKTrackerInvoker as compiled for arm64 (CV_NEON path): fixed-point W_BITS=14 patch/bilinear,
// Every float product feeding an add is written fma(x,y,0.0): Metal contracts a*b+c even in strict mode.
// float accumulators split exactly as NEON does it (4 lanes for x<20 / x<16, scalar tail, lane sum at the end).
struct LKP {
  n: u32, levels: u32, maxlevel: u32, flags: u32,
  lv: array<vec4<u32>, 4>,    // per level: (w, h, pwq (words per padded row), base (word offset))  image pyramids (I and J share geometry)
  dlv: array<vec4<u32>, 4>,   // per level: (w, h, pw, dbase) derivative pyramid of I
};
@group(0) @binding(0) var<storage, read> I: array<u32>;
@group(0) @binding(1) var<storage, read> J: array<u32>;
@group(0) @binding(2) var<storage, read> dI: array<u32>;   // packed i16 pairs
@group(0) @binding(3) var<storage, read> prevPts: array<vec2<f32>>;
@group(0) @binding(4) var<storage, read_write> nextPts: array<vec2<f32>>;
@group(0) @binding(5) var<storage, read_write> status: array<u32>;
@group(0) @binding(6) var<uniform> q: LKP;
const WIN: i32 = 21;
const PADI: i32 = 21;
const HALF: f32 = 10.0;              // (winSize-1)*0.5f
const FLT_SCALE: f32 = 1.0 / 1048576.0;   // 1.f/(1<<20)
const FLT_EPSILON: f32 = 1.1920929e-7;
// Correctly rounded sqrt / division. The GPU's own sqrt/divide are not guaranteed correctly rounded (M3 sqrt: 26 % off by
// 1 ulp even in strict mode; A16 unknown). Start from the hardware result (within 1 ulp) and fix it with EXACT integer
// midpoint tests on the mantissas (64-bit arithmetic emulated with two u32).
fn mul64(a: u32, b: u32) -> vec2<u32> {   // a*b -> (lo, hi), a,b < 2^32
  let a0 = a & 0xffffu; let a1 = a >> 16u; let b0 = b & 0xffffu; let b1 = b >> 16u;
  let p00 = a0 * b0; let p01 = a0 * b1; let p10 = a1 * b0; let p11 = a1 * b1;
  let mid = (p00 >> 16u) + (p01 & 0xffffu) + (p10 & 0xffffu);
  let lo = (p00 & 0xffffu) | (mid << 16u);
  let hi = p11 + (p01 >> 16u) + (p10 >> 16u) + (mid >> 16u);
  return vec2<u32>(lo, hi);
}
fn shl64(m: u32, s: u32) -> vec2<u32> {   // m << s, s < 64
  if (s >= 32u) { return vec2<u32>(0u, m << (s - 32u)); }
  if (s == 0u) { return vec2<u32>(m, 0u); }
  return vec2<u32>(m << s, m >> (32u - s));
}
fn lt64(a: vec2<u32>, b: vec2<u32>) -> bool { return a.y < b.y || (a.y == b.y && a.x < b.x); }
fn ge64(a: vec2<u32>, b: vec2<u32>) -> bool { return !lt64(a, b); }
fn mant(f: f32) -> u32 { return (bitcast<u32>(f) & 0x7fffffu) | 0x800000u; }
fn expo(f: f32) -> i32 { return i32((bitcast<u32>(f) >> 23u) & 255u) - 127; }
// x = mx*2^(ex-23) (normal, > 0); candidate y = my*2^(ey-23). sqrt(x) >= y + ulp/2  <=>  x >= (2my+1)^2 * 2^(2ey-48)
//   <=> mx * 2^(ex - 2ey + 25) >= (2my+1)^2.   Likewise sqrt(x) < y - ulp/2 <=> mx * 2^(ex-2ey+25) < (2my-1)^2.
fn sqrt_rn(x: f32) -> f32 {
  var y = sqrt(x);
  if (!(x > 0.0) || y <= 0.0 || expo(x) < -120 || expo(x) > 120) { return y; }
  for (var it = 0; it < 2; it++) {
    let my = mant(y); let s = expo(x) - 2 * expo(y) + 25;
    if (s < 0 || s > 40) { return y; }
    let X = shl64(mant(x), u32(s));
    let up = mul64(2u * my + 1u, 2u * my + 1u); let dn = mul64(2u * my - 1u, 2u * my - 1u);
    if (ge64(X, up)) { y = bitcast<f32>(bitcast<u32>(y) + 1u); continue; }
    if (lt64(X, dn)) { y = bitcast<f32>(bitcast<u32>(y) - 1u); continue; }
    break;
  }
  return y;
}
// q = a/d (a,d > 0 normal): a/d >= q + ulp/2  <=>  ma*2^(ea-23) >= (2mq+1)*2^(eq-24) * md*2^(ed-23)
//   <=> ma * 2^(ea - eq - ed + 24) >= (2mq+1)*md ;  a/d < q - ulp/2 <=> ma * 2^(...) < (2mq-1)*md
fn div_rn_pos(a: f32, d: f32) -> f32 {
  var q = a / d;
  if (!(a > 0.0) || !(d > 0.0) || !(q > 0.0) || expo(a) < -120 || expo(a) > 120 || expo(d) < -120 || expo(d) > 120) { return q; }
  for (var it = 0; it < 2; it++) {
    let mq = mant(q); let s = expo(a) - expo(q) - expo(d) + 24;
    if (s < 0 || s > 40) { return q; }
    let Aa = shl64(mant(a), u32(s));
    let up = mul64(2u * mq + 1u, mant(d)); let dn = mul64(2u * mq - 1u, mant(d));
    if (ge64(Aa, up)) { q = bitcast<f32>(bitcast<u32>(q) + 1u); continue; }
    if (lt64(Aa, dn)) { q = bitcast<f32>(bitcast<u32>(q) - 1u); continue; }
    break;
  }
  return q;
}
fn div_rn(a: f32, d: f32) -> f32 {
  let neg = (a < 0.0) != (d < 0.0);
  let r = div_rn_pos(abs(a), abs(d));
  return select(r, -r, neg);
}
fn descale(v: i32, n: u32) -> i32 { return (v + (1i << (n - 1u))) >> n; }   // CV_DESCALE == NEON vqrshl by -n
fn cvRound(x: f32) -> i32 { return i32(round(x)); }   // lrint: nearest, ties to even
fn cvFloor(x: f32) -> i32 { return i32(floor(x)); }
fn rdI(l: u32, x: i32, y: i32) -> i32 { let c = u32(x + PADI); return i32((I[q.lv[l].w + u32(y + PADI) * q.lv[l].z + (c >> 2u)] >> ((c & 3u) * 8u)) & 255u); }
fn rdJ(l: u32, x: i32, y: i32) -> i32 { let c = u32(x + PADI); return i32((J[q.lv[l].w + u32(y + PADI) * q.lv[l].z + (c >> 2u)] >> ((c & 3u) * 8u)) & 255u); }
fn rdD(l: u32, x: i32, y: i32) -> vec2<i32> { let v = dI[q.dlv[l].w + u32(y + PADI) * q.dlv[l].z + u32(x + PADI)]; return vec2<i32>((i32(v << 16u)) >> 16u, i32(v) >> 16u); }
var<private> IWin: array<i32, 441>;
var<private> DIx: array<i32, 441>;
var<private> DIy: array<i32, 441>;
@compute @workgroup_size(32)
fn main(@builtin(global_invocation_id) gid: vec3<u32>) {
  let idx = gid.x;
  if (idx >= q.n) { return; }
  var st: u32 = 1u;
  var next = nextPts[idx];
  for (var lvl: i32 = i32(q.maxlevel); lvl >= 0; lvl--) {
    let l = u32(lvl);
    let cols = i32(q.lv[l].x); let rows = i32(q.lv[l].y);
    let scale = 1.0 / f32(1i << u32(lvl));
    var prevPt = prevPts[idx] * scale;
    var nextPt: vec2<f32>;
    if (lvl == i32(q.maxlevel)) { nextPt = nextPts[idx] * scale; } else { nextPt = next * 2.0; }
    next = nextPt;
    prevPt = prevPt - vec2<f32>(HALF, HALF);
    let ipx = cvFloor(prevPt.x); let ipy = cvFloor(prevPt.y);
    if (ipx < -WIN || ipx >= cols || ipy < -WIN || ipy >= rows) { if (lvl == 0) { st = 0u; } continue; }
    var a = prevPt.x - f32(ipx); var b = prevPt.y - f32(ipy);
    var iw00 = cvRound(fma((1.0 - a) * (1.0 - b), 16384.0, 0.0));
    var iw01 = cvRound(fma(a * (1.0 - b), 16384.0, 0.0));
    var iw10 = cvRound(fma((1.0 - a) * b, 16384.0, 0.0));
    var iw11 = 16384 - iw00 - iw01 - iw10;
    var nA11 = vec4<f32>(0.0); var nA12 = vec4<f32>(0.0); var nA22 = vec4<f32>(0.0);
    var iA11: f32 = 0.0; var iA12: f32 = 0.0; var iA22: f32 = 0.0;
    for (var y: i32 = 0; y < WIN; y++) {
      for (var x: i32 = 0; x < WIN; x++) {
        let sx = ipx + x; let sy = ipy + y;
        let v = descale(rdI(l, sx, sy) * iw00 + rdI(l, sx + 1, sy) * iw01 + rdI(l, sx, sy + 1) * iw10 + rdI(l, sx + 1, sy + 1) * iw11, 9u);
        let d00 = rdD(l, sx, sy); let d01 = rdD(l, sx + 1, sy); let d10 = rdD(l, sx, sy + 1); let d11 = rdD(l, sx + 1, sy + 1);
        let ix = descale(d00.x * iw00 + d01.x * iw01 + d10.x * iw10 + d11.x * iw11, 14u);
        let iy = descale(d00.y * iw00 + d01.y * iw01 + d10.y * iw10 + d11.y * iw11, 14u);
        let o = y * WIN + x;
        IWin[o] = v; DIx[o] = ix; DIy[o] = iy;
        if (x < 20) {   // NEON: 5 groups of 4 lanes, lane = x & 3, float accumulate per lane
          let lane = x & 3;
          nA11[lane] += f32(ix * ix); nA12[lane] += f32(ix * iy); nA22[lane] += f32(iy * iy);
        } else {        // scalar tail x == 20
          iA11 += f32(ix * ix); iA12 += f32(ix * iy); iA22 += f32(iy * iy);
        }
      }
    }
    iA11 += ((nA11.x + nA11.y) + nA11.z) + nA11.w;
    iA12 += ((nA12.x + nA12.y) + nA12.z) + nA12.w;
    iA22 += ((nA22.x + nA22.y) + nA22.z) + nA22.w;
    let A11 = iA11 * FLT_SCALE; let A12 = iA12 * FLT_SCALE; let A22 = iA22 * FLT_SCALE;
    var D = fma(A11, A22, 0.0) - fma(A12, A12, 0.0);
    let minEig = div_rn(A22 + A11 - sqrt_rn(fma(A11 - A22, A11 - A22, 0.0) + fma(4.0 * A12, A12, 0.0)), f32(2 * WIN * WIN));
    if (minEig < 1e-4 || D < FLT_EPSILON) { if (lvl == 0) { st = 0u; } continue; }
    D = div_rn(1.0, D);
    nextPt = nextPt - vec2<f32>(HALF, HALF);
    var prevDelta = vec2<f32>(0.0, 0.0);
    for (var j: i32 = 0; j < 30; j++) {
      let inx = cvFloor(nextPt.x); let iny = cvFloor(nextPt.y);
      if (inx < -WIN || inx >= cols || iny < -WIN || iny >= rows) { if (lvl == 0) { st = 0u; } break; }
      a = nextPt.x - f32(inx); b = nextPt.y - f32(iny);
      iw00 = cvRound(fma((1.0 - a) * (1.0 - b), 16384.0, 0.0));
      iw01 = cvRound(fma(a * (1.0 - b), 16384.0, 0.0));
      iw10 = cvRound(fma((1.0 - a) * b, 16384.0, 0.0));
      iw11 = 16384 - iw00 - iw01 - iw10;
      var nB1 = vec4<f32>(0.0); var nB2 = vec4<f32>(0.0);
      var ib1: f32 = 0.0; var ib2: f32 = 0.0;
      for (var y: i32 = 0; y < WIN; y++) {
        // NEON: two groups of 8 (x = 0..7, 8..15): lane i gets int (p[i] + p[i+4]) then float-accumulates
        for (var g: i32 = 0; g < 16; g += 8) {
          var s1 = vec4<i32>(0); var s2 = vec4<i32>(0);
          for (var k: i32 = 0; k < 8; k++) {
            let x = g + k; let sx = inx + x; let sy = iny + y; let o = y * WIN + x;
            let diff = descale(rdJ(l, sx, sy) * iw00 + rdJ(l, sx + 1, sy) * iw01 + rdJ(l, sx, sy + 1) * iw10 + rdJ(l, sx + 1, sy + 1) * iw11, 9u) - IWin[o];
            s1[k & 3] += diff * DIx[o]; s2[k & 3] += diff * DIy[o];
          }
          nB1 += vec4<f32>(s1); nB2 += vec4<f32>(s2);
        }
        for (var x: i32 = 16; x < WIN; x++) {   // scalar tail
          let sx = inx + x; let sy = iny + y; let o = y * WIN + x;
          let diff = descale(rdJ(l, sx, sy) * iw00 + rdJ(l, sx + 1, sy) * iw01 + rdJ(l, sx, sy + 1) * iw10 + rdJ(l, sx + 1, sy + 1) * iw11, 9u) - IWin[o];
          ib1 += f32(diff * DIx[o]); ib2 += f32(diff * DIy[o]);
        }
      }
      ib1 += ((nB1.x + nB1.y) + nB1.z) + nB1.w;
      ib2 += ((nB2.x + nB2.y) + nB2.z) + nB2.w;
      let b1 = ib1 * FLT_SCALE; let b2 = ib2 * FLT_SCALE;
      let delta = vec2<f32>((fma(A12, b2, 0.0) - fma(A22, b1, 0.0)) * D, (fma(A12, b1, 0.0) - fma(A11, b2, 0.0)) * D);
      nextPt = nextPt + delta;
      next = nextPt + vec2<f32>(HALF, HALF);
      if (dot(delta, delta) <= 1e-4) { break; }    // CPU: double ddot vs criteria.epsilon (0.01^2)
      if (j > 0 && abs(delta.x + prevDelta.x) < 0.01 && abs(delta.y + prevDelta.y) < 0.01) { next = next - delta * 0.5; break; }
      prevDelta = delta;
    }
  }
  nextPts[idx] = next;
  status[idx] = st;
}

)WGSL";
static const char* const k_lk_track_wg = R"WGSL(
// Sparse pyramidal LK, ONE WORKGROUP PER POINT. Same bit-for-bit semantics as lk_track.wgsl (OpenCV 4.0.1
// LKTrackerInvoker, arm64/NEON float accumulation order): the 441 bilinear samples / integer products are computed by
// 256 threads in parallel into workgroup memory; every float accumulation is done serially by thread 0 in NEON order
// (4 lanes for x<20 / int-paired 8-groups for x<16, scalar tails, lane sum ((0+1)+2)+3). Products feeding adds use fma(x,y,0.0).
struct LKP {
  n: u32, levels: u32, maxlevel: u32, flags: u32,
  lv: array<vec4<u32>, 4>,    // per level: (w, h, pwq (words per padded row), base (word offset))
  dlv: array<vec4<u32>, 4>,   // per level: (w, h, pw, dbase)
};
@group(0) @binding(0) var<storage, read> I: array<u32>;
@group(0) @binding(1) var<storage, read> J: array<u32>;
@group(0) @binding(2) var<storage, read> dI: array<u32>;   // packed i16 pairs
@group(0) @binding(3) var<storage, read> prevPts: array<vec2<f32>>;
@group(0) @binding(4) var<storage, read_write> nextPts: array<vec2<f32>>;
@group(0) @binding(5) var<storage, read_write> status: array<u32>;
@group(0) @binding(6) var<uniform> q: LKP;
const WIN: i32 = 21;
const NPIX: u32 = 441u;
const PADI: i32 = 21;
const HALF: f32 = 10.0;
const FLT_SCALE: f32 = 1.0 / 1048576.0;
const FLT_EPSILON: f32 = 1.1920929e-7;
// Correctly rounded sqrt / division. The GPU's own sqrt/divide are not guaranteed correctly rounded (M3 sqrt: 26 % off by
// 1 ulp even in strict mode; A16 unknown). Start from the hardware result (within 1 ulp) and fix it with EXACT integer
// midpoint tests on the mantissas (64-bit arithmetic emulated with two u32).
fn mul64(a: u32, b: u32) -> vec2<u32> {   // a*b -> (lo, hi), a,b < 2^32
  let a0 = a & 0xffffu; let a1 = a >> 16u; let b0 = b & 0xffffu; let b1 = b >> 16u;
  let p00 = a0 * b0; let p01 = a0 * b1; let p10 = a1 * b0; let p11 = a1 * b1;
  let mid = (p00 >> 16u) + (p01 & 0xffffu) + (p10 & 0xffffu);
  let lo = (p00 & 0xffffu) | (mid << 16u);
  let hi = p11 + (p01 >> 16u) + (p10 >> 16u) + (mid >> 16u);
  return vec2<u32>(lo, hi);
}
fn shl64(m: u32, s: u32) -> vec2<u32> {   // m << s, s < 64
  if (s >= 32u) { return vec2<u32>(0u, m << (s - 32u)); }
  if (s == 0u) { return vec2<u32>(m, 0u); }
  return vec2<u32>(m << s, m >> (32u - s));
}
fn lt64(a: vec2<u32>, b: vec2<u32>) -> bool { return a.y < b.y || (a.y == b.y && a.x < b.x); }
fn ge64(a: vec2<u32>, b: vec2<u32>) -> bool { return !lt64(a, b); }
fn mant(f: f32) -> u32 { return (bitcast<u32>(f) & 0x7fffffu) | 0x800000u; }
fn expo(f: f32) -> i32 { return i32((bitcast<u32>(f) >> 23u) & 255u) - 127; }
// x = mx*2^(ex-23) (normal, > 0); candidate y = my*2^(ey-23). sqrt(x) >= y + ulp/2  <=>  x >= (2my+1)^2 * 2^(2ey-48)
//   <=> mx * 2^(ex - 2ey + 25) >= (2my+1)^2.   Likewise sqrt(x) < y - ulp/2 <=> mx * 2^(ex-2ey+25) < (2my-1)^2.
fn sqrt_rn(x: f32) -> f32 {
  var y = sqrt(x);
  if (!(x > 0.0) || y <= 0.0 || expo(x) < -120 || expo(x) > 120) { return y; }
  for (var it = 0; it < 2; it++) {
    let my = mant(y); let s = expo(x) - 2 * expo(y) + 25;
    if (s < 0 || s > 40) { return y; }
    let X = shl64(mant(x), u32(s));
    let up = mul64(2u * my + 1u, 2u * my + 1u); let dn = mul64(2u * my - 1u, 2u * my - 1u);
    if (ge64(X, up)) { y = bitcast<f32>(bitcast<u32>(y) + 1u); continue; }
    if (lt64(X, dn)) { y = bitcast<f32>(bitcast<u32>(y) - 1u); continue; }
    break;
  }
  return y;
}
// q = a/d (a,d > 0 normal): a/d >= q + ulp/2  <=>  ma*2^(ea-23) >= (2mq+1)*2^(eq-24) * md*2^(ed-23)
//   <=> ma * 2^(ea - eq - ed + 24) >= (2mq+1)*md ;  a/d < q - ulp/2 <=> ma * 2^(...) < (2mq-1)*md
fn div_rn_pos(a: f32, d: f32) -> f32 {
  var q = a / d;
  if (!(a > 0.0) || !(d > 0.0) || !(q > 0.0) || expo(a) < -120 || expo(a) > 120 || expo(d) < -120 || expo(d) > 120) { return q; }
  for (var it = 0; it < 2; it++) {
    let mq = mant(q); let s = expo(a) - expo(q) - expo(d) + 24;
    if (s < 0 || s > 40) { return q; }
    let Aa = shl64(mant(a), u32(s));
    let up = mul64(2u * mq + 1u, mant(d)); let dn = mul64(2u * mq - 1u, mant(d));
    if (ge64(Aa, up)) { q = bitcast<f32>(bitcast<u32>(q) + 1u); continue; }
    if (lt64(Aa, dn)) { q = bitcast<f32>(bitcast<u32>(q) - 1u); continue; }
    break;
  }
  return q;
}
fn div_rn(a: f32, d: f32) -> f32 {
  let neg = (a < 0.0) != (d < 0.0);
  let r = div_rn_pos(abs(a), abs(d));
  return select(r, -r, neg);
}
fn descale(v: i32, n: u32) -> i32 { return (v + (1i << (n - 1u))) >> n; }
fn cvRound(x: f32) -> i32 { return i32(round(x)); }
fn cvFloor(x: f32) -> i32 { return i32(floor(x)); }
fn rdI(l: u32, x: i32, y: i32) -> i32 { let c = u32(x + PADI); return i32((I[q.lv[l].w + u32(y + PADI) * q.lv[l].z + (c >> 2u)] >> ((c & 3u) * 8u)) & 255u); }
fn rdJ(l: u32, x: i32, y: i32) -> i32 { let c = u32(x + PADI); return i32((J[q.lv[l].w + u32(y + PADI) * q.lv[l].z + (c >> 2u)] >> ((c & 3u) * 8u)) & 255u); }
fn rdD(l: u32, x: i32, y: i32) -> vec2<i32> { let v = dI[q.dlv[l].w + u32(y + PADI) * q.dlv[l].z + u32(x + PADI)]; return vec2<i32>((i32(v << 16u)) >> 16u, i32(v) >> 16u); }
fn weights(a: f32, b: f32) -> vec4<i32> {
  let iw00 = cvRound(fma((1.0 - a) * (1.0 - b), 16384.0, 0.0));
  let iw01 = cvRound(fma(a * (1.0 - b), 16384.0, 0.0));
  let iw10 = cvRound(fma((1.0 - a) * b, 16384.0, 0.0));
  return vec4<i32>(iw00, iw01, iw10, 16384 - iw00 - iw01 - iw10);
}
var<workgroup> IWin: array<i32, 441>;
var<workgroup> DIx: array<i32, 441>;
var<workgroup> DIy: array<i32, 441>;
var<workgroup> P1: array<i32, 441>;
var<workgroup> P2: array<i32, 441>;
var<workgroup> P3: array<i32, 441>;
var<workgroup> s_ipt: vec2<i32>;
var<workgroup> s_iw: vec4<i32>;
var<workgroup> s_flag: i32;       // 0 = go on, 1 = skip level, 2 = stop iterating
var<workgroup> s_nextPt: vec2<f32>;
var<workgroup> s_next: vec2<f32>;
var<workgroup> s_status: u32;
var<workgroup> s_A: vec3<f32>;
var<workgroup> s_D: f32;
var<workgroup> s_prevDelta: vec2<f32>;
var<workgroup> s_acc: array<vec3<f32>, 5>;
@compute @workgroup_size(64)
fn main(@builtin(workgroup_id) wg: vec3<u32>, @builtin(local_invocation_index) lid: u32) {
  let idx = wg.x;
  if (idx >= q.n) { return; }
  if (lid == 0u) { s_status = 1u; s_next = nextPts[idx]; }
  workgroupBarrier();
  for (var lvl: i32 = i32(q.maxlevel); lvl >= 0; lvl--) {
    let l = u32(lvl);
    let cols = i32(q.lv[l].x); let rows = i32(q.lv[l].y);
    workgroupBarrier();
    if (lid == 0u) {
      let scale = 1.0 / f32(1i << u32(lvl));
      var prevPt = prevPts[idx] * scale;
      var nextPt: vec2<f32>;
      if (lvl == i32(q.maxlevel)) { nextPt = nextPts[idx] * scale; } else { nextPt = s_next * 2.0; }
      s_next = nextPt;
      s_nextPt = nextPt;
      prevPt = prevPt - vec2<f32>(HALF, HALF);
      let ipx = cvFloor(prevPt.x); let ipy = cvFloor(prevPt.y);
      s_ipt = vec2<i32>(ipx, ipy);
      if (ipx < -WIN || ipx >= cols || ipy < -WIN || ipy >= rows) { if (lvl == 0) { s_status = 0u; } s_flag = 1; }
      else { s_flag = 0; s_iw = weights(prevPt.x - f32(ipx), prevPt.y - f32(ipy)); }
    }
    let f0 = workgroupUniformLoad(&s_flag);
    if (f0 == 1) { continue; }
    let ipx = s_ipt.x; let ipy = s_ipt.y; let iw = s_iw;
    for (var o: u32 = lid; o < NPIX; o += 64u) {
      let y = i32(o / 21u); let x = i32(o % 21u); let sx = ipx + x; let sy = ipy + y;
      let v = descale(rdI(l, sx, sy) * iw.x + rdI(l, sx + 1, sy) * iw.y + rdI(l, sx, sy + 1) * iw.z + rdI(l, sx + 1, sy + 1) * iw.w, 9u);
      let d00 = rdD(l, sx, sy); let d01 = rdD(l, sx + 1, sy); let d10 = rdD(l, sx, sy + 1); let d11 = rdD(l, sx + 1, sy + 1);
      let ix = descale(d00.x * iw.x + d01.x * iw.y + d10.x * iw.z + d11.x * iw.w, 14u);
      let iy = descale(d00.y * iw.x + d01.y * iw.y + d10.y * iw.z + d11.y * iw.w, 14u);
      IWin[o] = v; DIx[o] = ix; DIy[o] = iy; P1[o] = ix * ix; P2[o] = ix * iy; P3[o] = iy * iy;
    }
    workgroupBarrier();
    // NEON order = 5 independent float chains: lane i (i = x & 3, x < 20) and the scalar tail (x == 20). Threads 0..3 run the
    // lane chains, thread 4 the tail chain (each exactly in row-major order as the CPU does); thread 0 then combines
    // iA += ((l0 + l1) + l2) + l3 in the CPU's order.
    if (lid < 5u) {
      var a11: f32 = 0.0; var a12: f32 = 0.0; var a22: f32 = 0.0;
      if (lid < 4u) { for (var y: i32 = 0; y < WIN; y++) { for (var x: i32 = i32(lid); x < 20; x += 4) { let o = u32(y * WIN + x); a11 += f32(P1[o]); a12 += f32(P2[o]); a22 += f32(P3[o]); } } }
      else { for (var y: i32 = 0; y < WIN; y++) { let o = u32(y * WIN + 20); a11 += f32(P1[o]); a12 += f32(P2[o]); a22 += f32(P3[o]); } }
      s_acc[lid] = vec3<f32>(a11, a12, a22);
    }
    workgroupBarrier();
    if (lid == 0u) {
      let iA11 = s_acc[4].x + (((s_acc[0].x + s_acc[1].x) + s_acc[2].x) + s_acc[3].x);   // CPU: tail += ((l0 + l1) + l2) + l3
      let iA12 = s_acc[4].y + (((s_acc[0].y + s_acc[1].y) + s_acc[2].y) + s_acc[3].y);   // CPU: tail += ((l0 + l1) + l2) + l3
      let iA22 = s_acc[4].z + (((s_acc[0].z + s_acc[1].z) + s_acc[2].z) + s_acc[3].z);   // CPU: tail += ((l0 + l1) + l2) + l3
      let A11 = iA11 * FLT_SCALE; let A12 = iA12 * FLT_SCALE; let A22 = iA22 * FLT_SCALE;
      let D = fma(A11, A22, 0.0) - fma(A12, A12, 0.0);
      let minEig = div_rn(A22 + A11 - sqrt_rn(fma(A11 - A22, A11 - A22, 0.0) + fma(4.0 * A12, A12, 0.0)), f32(2 * WIN * WIN));
      if (minEig < 1e-4 || D < FLT_EPSILON) { if (lvl == 0) { s_status = 0u; } s_flag = 1; }
      else { s_flag = 0; s_A = vec3<f32>(A11, A12, A22); s_D = div_rn(1.0, D); s_nextPt = s_nextPt - vec2<f32>(HALF, HALF); s_prevDelta = vec2<f32>(0.0, 0.0); }
    }
    let f1 = workgroupUniformLoad(&s_flag);
    if (f1 == 1) { continue; }
    for (var j: i32 = 0; j < 30; j++) {
      workgroupBarrier();
      if (lid == 0u) {
        let inx = cvFloor(s_nextPt.x); let iny = cvFloor(s_nextPt.y);
        if (inx < -WIN || inx >= cols || iny < -WIN || iny >= rows) { if (lvl == 0) { s_status = 0u; } s_flag = 2; }
        else { s_flag = 0; s_ipt = vec2<i32>(inx, iny); s_iw = weights(s_nextPt.x - f32(inx), s_nextPt.y - f32(iny)); }
      }
      let f2 = workgroupUniformLoad(&s_flag);
      if (f2 == 2) { break; }
      let inx = s_ipt.x; let iny = s_ipt.y; let jw = s_iw;
      for (var o: u32 = lid; o < NPIX; o += 64u) {
        let y = i32(o / 21u); let x = i32(o % 21u); let sx = inx + x; let sy = iny + y;
        let diff = descale(rdJ(l, sx, sy) * jw.x + rdJ(l, sx + 1, sy) * jw.y + rdJ(l, sx, sy + 1) * jw.z + rdJ(l, sx + 1, sy + 1) * jw.w, 9u) - IWin[o];
        P1[o] = diff * DIx[o]; P2[o] = diff * DIy[o];
      }
      workgroupBarrier();
      if (lid < 5u) {
        var b1: f32 = 0.0; var b2: f32 = 0.0;
        if (lid < 4u) {   // lane chain: per row, per 8-group g in {0, 8}: int (p[g+lane] + p[g+lane+4]) then float accumulate
          for (var y: i32 = 0; y < WIN; y++) { for (var g: i32 = 0; g < 16; g += 8) { let o = u32(y * WIN + g + i32(lid)); b1 += f32(P1[o] + P1[o + 4u]); b2 += f32(P2[o] + P2[o + 4u]); } }
        } else {          // scalar tail x = 16..20, row-major
          for (var y: i32 = 0; y < WIN; y++) { for (var x: i32 = 16; x < WIN; x++) { let o = u32(y * WIN + x); b1 += f32(P1[o]); b2 += f32(P2[o]); } }
        }
        s_acc[lid] = vec3<f32>(b1, b2, 0.0);
      }
      workgroupBarrier();
      if (lid == 0u) {
        let ib1 = s_acc[4].x + (((s_acc[0].x + s_acc[1].x) + s_acc[2].x) + s_acc[3].x);   // CPU: tail += ((l0 + l1) + l2) + l3
        let ib2 = s_acc[4].y + (((s_acc[0].y + s_acc[1].y) + s_acc[2].y) + s_acc[3].y);   // CPU: tail += ((l0 + l1) + l2) + l3
        let b1 = ib1 * FLT_SCALE; let b2 = ib2 * FLT_SCALE;
        let A = s_A; let D = s_D;
        let delta = vec2<f32>((fma(A.y, b2, 0.0) - fma(A.z, b1, 0.0)) * D, (fma(A.y, b1, 0.0) - fma(A.x, b2, 0.0)) * D);
        s_nextPt = s_nextPt + delta;
        s_next = s_nextPt + vec2<f32>(HALF, HALF);
        if (dot(delta, delta) <= 1e-4) { s_flag = 2; }
        else if (j > 0 && abs(delta.x + s_prevDelta.x) < 0.01 && abs(delta.y + s_prevDelta.y) < 0.01) { s_next = s_next - delta * 0.5; s_flag = 2; }
        else { s_flag = 0; s_prevDelta = delta; }
      }
      let f3 = workgroupUniformLoad(&s_flag);
      if (f3 == 2) { break; }
    }
  }
  workgroupBarrier();
  if (lid == 0u) { nextPts[idx] = s_next; status[idx] = s_status; }
}

)WGSL";
static const char* const k_fp_selfcheck = R"WGSL(
// Device floating-point primitive self-check. inp: 4 f32 per item (a in [0.5,2), b, c, d); outp: 12 f32 per item.
@group(0) @binding(0) var<storage, read> inp: array<f32>;
@group(0) @binding(1) var<storage, read_write> outp: array<f32>;
// Correctly rounded sqrt / division. The GPU's own sqrt/divide are not guaranteed correctly rounded (M3 sqrt: 26 % off by
// 1 ulp even in strict mode; A16 unknown). Start from the hardware result (within 1 ulp) and fix it with EXACT integer
// midpoint tests on the mantissas (64-bit arithmetic emulated with two u32).
fn mul64(a: u32, b: u32) -> vec2<u32> {   // a*b -> (lo, hi), a,b < 2^32
  let a0 = a & 0xffffu; let a1 = a >> 16u; let b0 = b & 0xffffu; let b1 = b >> 16u;
  let p00 = a0 * b0; let p01 = a0 * b1; let p10 = a1 * b0; let p11 = a1 * b1;
  let mid = (p00 >> 16u) + (p01 & 0xffffu) + (p10 & 0xffffu);
  let lo = (p00 & 0xffffu) | (mid << 16u);
  let hi = p11 + (p01 >> 16u) + (p10 >> 16u) + (mid >> 16u);
  return vec2<u32>(lo, hi);
}
fn shl64(m: u32, s: u32) -> vec2<u32> {   // m << s, s < 64
  if (s >= 32u) { return vec2<u32>(0u, m << (s - 32u)); }
  if (s == 0u) { return vec2<u32>(m, 0u); }
  return vec2<u32>(m << s, m >> (32u - s));
}
fn lt64(a: vec2<u32>, b: vec2<u32>) -> bool { return a.y < b.y || (a.y == b.y && a.x < b.x); }
fn ge64(a: vec2<u32>, b: vec2<u32>) -> bool { return !lt64(a, b); }
fn mant(f: f32) -> u32 { return (bitcast<u32>(f) & 0x7fffffu) | 0x800000u; }
fn expo(f: f32) -> i32 { return i32((bitcast<u32>(f) >> 23u) & 255u) - 127; }
// x = mx*2^(ex-23) (normal, > 0); candidate y = my*2^(ey-23). sqrt(x) >= y + ulp/2  <=>  x >= (2my+1)^2 * 2^(2ey-48)
//   <=> mx * 2^(ex - 2ey + 25) >= (2my+1)^2.   Likewise sqrt(x) < y - ulp/2 <=> mx * 2^(ex-2ey+25) < (2my-1)^2.
fn sqrt_rn(x: f32) -> f32 {
  var y = sqrt(x);
  if (!(x > 0.0) || y <= 0.0 || expo(x) < -120 || expo(x) > 120) { return y; }
  for (var it = 0; it < 2; it++) {
    let my = mant(y); let s = expo(x) - 2 * expo(y) + 25;
    if (s < 0 || s > 40) { return y; }
    let X = shl64(mant(x), u32(s));
    let up = mul64(2u * my + 1u, 2u * my + 1u); let dn = mul64(2u * my - 1u, 2u * my - 1u);
    if (ge64(X, up)) { y = bitcast<f32>(bitcast<u32>(y) + 1u); continue; }
    if (lt64(X, dn)) { y = bitcast<f32>(bitcast<u32>(y) - 1u); continue; }
    break;
  }
  return y;
}
// q = a/d (a,d > 0 normal): a/d >= q + ulp/2  <=>  ma*2^(ea-23) >= (2mq+1)*2^(eq-24) * md*2^(ed-23)
//   <=> ma * 2^(ea - eq - ed + 24) >= (2mq+1)*md ;  a/d < q - ulp/2 <=> ma * 2^(...) < (2mq-1)*md
fn div_rn_pos(a: f32, d: f32) -> f32 {
  var q = a / d;
  if (!(a > 0.0) || !(d > 0.0) || !(q > 0.0) || expo(a) < -120 || expo(a) > 120 || expo(d) < -120 || expo(d) > 120) { return q; }
  for (var it = 0; it < 2; it++) {
    let mq = mant(q); let s = expo(a) - expo(q) - expo(d) + 24;
    if (s < 0 || s > 40) { return q; }
    let Aa = shl64(mant(a), u32(s));
    let up = mul64(2u * mq + 1u, mant(d)); let dn = mul64(2u * mq - 1u, mant(d));
    if (ge64(Aa, up)) { q = bitcast<f32>(bitcast<u32>(q) + 1u); continue; }
    if (lt64(Aa, dn)) { q = bitcast<f32>(bitcast<u32>(q) - 1u); continue; }
    break;
  }
  return q;
}
fn div_rn(a: f32, d: f32) -> f32 {
  let neg = (a < 0.0) != (d < 0.0);
  let r = div_rn_pos(abs(a), abs(d));
  return select(r, -r, neg);
}
@compute @workgroup_size(64)
fn main(@builtin(global_invocation_id) gid: vec3<u32>) {
  let i = gid.x; let o = i * 4u; let O = i * 14u;
  let a = inp[o]; let b = inp[o + 1u]; let c = inp[o + 2u]; let d = inp[o + 3u];
  let ia = i32(a * 65536.0 * 500.0);            // ~ up to 2^25: exercises int->float rounding
  outp[O + 0u] = 1.0 / a;                  // division
  outp[O + 1u] = sqrt(a);                  // sqrt
  outp[O + 2u] = f32(ia * 3 + 1);          // int->float (large, needs rounding)
  outp[O + 3u] = fma(a, b, 0.0) + fma(c, d, 0.0);   // guarded mul-add (no contraction)
  outp[O + 4u] = round(a * 8.0 + 0.5);     // ties (a*8 is exact-ish) -> half-even?
  outp[O + 5u] = a * b;                    // single multiply
  outp[O + 6u] = a + b;                    // single add
  outp[O + 7u] = (fma(a, b, 0.0) - fma(c, d, 0.0)) * (1.0 / (a + 1.0));   // LK delta shape
  outp[O + 8u] = floor(a * 1000.0 - 0.5);  // floor
  outp[O + 9u] = a * (1.0 / 1048576.0);    // FLT_SCALE multiply
  outp[O + 10u] = f32(i32(-(ia * 3 + 1)));  // negative int->float
  outp[O + 11u] = (a + b) * c - d * a;     // unguarded: contraction detector
  outp[O + 12u] = sqrt_rn(a);
  outp[O + 13u] = div_rn(1.0, a + 1.0);
}

)WGSL";
}
