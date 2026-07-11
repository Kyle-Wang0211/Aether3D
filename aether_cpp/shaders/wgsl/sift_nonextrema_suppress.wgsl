// sift_nonextrema_suppress.wgsl — global non-extrema suppression (Stage B++).
//
// GPU port of VLFeat vl_covdet_detect's non-extrema suppression (covdet.c:2104-
// 2139, default tol = VL_COVDET_AA_... no — self->nonExtremaSuppression = 0.5 set
// in vl_covdet_new, covdet.c:1536). A GLOBAL, cross-octave pass on the unified
// keypoint buffer: a feature j is suppressed (peakScore→0) when a NEARBY,
// SAME-SCALE, STRICTLY-STRONGER feature i exists:
//   sigma_j < (1+tol) sigma_i  &&  sigma_i < (1+tol) sigma_j  (within ~half octave)
//   |x_i - x_j| < tol*sigma_i   &&  |y_i - y_j| < tol*sigma_i  (image-frame px)
//   |score_i|  > |score_j|                                     (strict)
//
// PARALLEL ("simultaneous") semantics: one thread per j scans all i using the
// ORIGINAL scores. This differs from VLFeat's index-order SEQUENTIAL loop only
// in the rare case where a suppressor i is itself suppressed by an even stronger
// k BEFORE i's own outer-loop turn — then VLFeat skips i as a suppressor, but
// the parallel pass still lets i suppress j. The host A/B (dog_detect_parity)
// quantifies this gap; it is well within the recall/precision gate on real data.
//
// Output: a per-keypoint keep flag (1 = survives, 0 = suppressed). The host
// compacts (or a later GPU stage uses the flag to gate work). NOTE: the geometry
// uses i's sigma for BOTH the scale-window and the spatial radius, matching
// VLFeat (the outer loop's `sigma` is feature i's).
//
// KpRecord layout (must match sift_dog_detect.wgsl KP_STRIDE=8):
//   [0]=x [1]=y [2]=sigma [3]=peakScore [4]=edgeScore [5]=o [6]=s [7]=pad
const KP_STRIDE : u32 = 8u;

struct Params {
  count : u32,   // number of keypoints in kp_buffer
  tol   : f32,   // suppression tolerance (0.5 default)
};

@group(0) @binding(0) var<storage, read>       kp_buffer : array<u32>;  // count * KP_STRIDE
@group(0) @binding(1) var<storage, read_write> keep      : array<u32>;  // [count] 0/1
@group(0) @binding(2) var<uniform>             P         : Params;

fn kp_x(i : u32)     -> f32 { return bitcast<f32>(kp_buffer[i * KP_STRIDE + 0u]); }
fn kp_y(i : u32)     -> f32 { return bitcast<f32>(kp_buffer[i * KP_STRIDE + 1u]); }
fn kp_sigma(i : u32) -> f32 { return bitcast<f32>(kp_buffer[i * KP_STRIDE + 2u]); }
fn kp_score(i : u32) -> f32 { return bitcast<f32>(kp_buffer[i * KP_STRIDE + 3u]); }

@compute @workgroup_size(64, 1, 1)
fn main(@builtin(global_invocation_id) gid : vec3<u32>) {
  let j : u32 = gid.x;
  if (j >= P.count) { return; }

  let xj : f32 = kp_x(j);
  let yj : f32 = kp_y(j);
  let sj : f32 = kp_sigma(j);
  let scj : f32 = abs(kp_score(j));
  let onePlusTol : f32 = 1.0 + P.tol;

  var suppressed : bool = false;
  for (var i : u32 = 0u; i < P.count; i = i + 1u) {
    if (i == j) { continue; }
    let si : f32 = kp_sigma(i);
    let sci : f32 = abs(kp_score(i));
    // VLFeat condition with roles: i = suppressor (outer), j = victim (inner).
    //   sigma_j < (1+tol) sigma_i && sigma_i < (1+tol) sigma_j
    //   |dx| < tol*sigma_i && |dy| < tol*sigma_i  (sigma_i = suppressor's sigma)
    //   |score_i| > |score_j|
    if (sj < onePlusTol * si && si < onePlusTol * sj &&
        abs(kp_x(i) - xj) < P.tol * si && abs(kp_y(i) - yj) < P.tol * si &&
        sci > scj) {
      suppressed = true;
      break;
    }
  }
  keep[j] = select(1u, 0u, suppressed);
}
