// sift_dog_cand_reset.wgsl — [COMPACT 2026-09-14] 每八度开跑前把候选计数器清零。
// 压缩刀每八度三次 dispatch:reset → A(检测+压缩追加) → B(密集精化)。
// 放在同一个 compute pass 里:WebGPU 规定同 pass 内的 dispatch 按序执行并隐式同步,
// 所以 B 一定读得到 A 写完的候选表。
@group(0) @binding(0) var<storage, read_write> cand_counter : atomic<u32>;

@compute @workgroup_size(1, 1, 1)
fn main() { atomicStore(&cand_counter, 0u); }
