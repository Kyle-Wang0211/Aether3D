// dense_preproc.cc — see header. Verbatim port of the 'o' pipeline pre-proc.
#include "dense_preproc.h"

#include <algorithm>
#include <cmath>
#include <iterator>
#include <string>

namespace aether::dense {

std::array<float, 9> scaled_K(const std::array<float, 9>& K_npz) {
    // K[1, :] *= PROC_H / NPZ_H  (row 1 = fy/cy row). float32 throughout.
    std::array<float, 9> K = K_npz;
    const float s = static_cast<float>(PROC_H) / static_cast<float>(NPZ_H);
    K[3] *= s; K[4] *= s; K[5] *= s;   // row index 1 -> elements 3,4,5
    return K;
}

std::array<float, 32> make_proj_stage(const std::array<float, 16>& w2c,
                                      const std::array<float, 9>& K, float scale) {
    // proj shape (2,4,4): [0]=w2c (16 floats), [1]=K padded into 4x4 then rows 0..1 * scale.
    std::array<float, 32> out{};
    for (int i = 0; i < 16; ++i) out[i] = w2c[i];      // proj[0] = w2c
    // proj[1] = zeros(4x4); proj[1][:3,:3] = K; then proj[1][:2,:] *= scale.
    // K row r, col c -> proj[1] index 16 + r*4 + c.
    for (int r = 0; r < 3; ++r)
        for (int c = 0; c < 3; ++c)
            out[16 + r * 4 + c] = K[r * 3 + c];
    // scale the first TWO rows of proj[1] (all 4 columns), matching proj[:,1,:2,:] *= f.
    for (int c = 0; c < 4; ++c) {
        out[16 + 0 * 4 + c] *= scale;
        out[16 + 1 * 4 + c] *= scale;
    }
    return out;
}

std::array<float, NUM_DEPTH> depth_values(float depth_min, float depth_max) {
    // np.linspace(1/depth_max, 1/depth_min, NUM_DEPTH, dtype=float32). numpy computes
    // the ramp in FLOAT64 (start/stop are Python float64; arange*step+start promotes to
    // f64) and casts each element to float32 at the end -> must match in double, not f32.
    // The float inputs are promoted to double first (== Python's float(np.float32(x))).
    const double start = 1.0 / static_cast<double>(depth_max);
    const double stop = 1.0 / static_cast<double>(depth_min);
    const double step = (stop - start) / static_cast<double>(NUM_DEPTH - 1);
    std::array<float, NUM_DEPTH> dv{};
    for (int i = 0; i < NUM_DEPTH; ++i)
        dv[i] = static_cast<float>(start + static_cast<double>(i) * step);
    dv[NUM_DEPTH - 1] = static_cast<float>(stop);   // numpy pins the endpoint
    return dv;
}

namespace {
// np.percentile 的默认 'linear' 插值:虚拟下标 = q/100*(n-1),取整后线性插值。
// 排的是**值**不是下标,所以排序稳定性在这里不影响结果。
double percentile_linear(std::vector<double>& sorted, double q) {
    const std::size_t n = sorted.size();
    if (n == 1) return sorted[0];
    const double vi = q / 100.0 * static_cast<double>(n - 1);
    const double lo = std::floor(vi);
    const double gamma = vi - lo;
    const std::size_t i0 = static_cast<std::size_t>(lo);
    const std::size_t i1 = std::min(i0 + 1, n - 1);
    return sorted[i0] * (1.0 - gamma) + sorted[i1] * gamma;
}
}  // namespace

std::vector<std::string> covis_select(const std::string& ref,
                                      const std::vector<FrameObs>& pool,
                                      const std::vector<std::array<float, 3>>& points,
                                      int k) {
    const FrameObs* r = nullptr;
    for (const auto& f : pool)
        if (f.name == ref) { r = &f; break; }
    if (r == nullptr || r->point_ids.size() < 8) return {};

    constexpr double t0 = 5.0, s1 = 1.0, s2 = 10.0;
    // (score, name);生产是 `scored.sort(reverse=True)` 对元组降序 ⇒ 分数高的在前,
    // 分数相同则**名字大的**在前。这里逐字复刻,包括 tie-break 方向。
    std::vector<std::pair<double, std::string>> scored;
    for (const auto& m : pool) {
        if (m.name == ref) continue;
        std::vector<int> shared;
        std::set_intersection(r->point_ids.begin(), r->point_ids.end(),
                              m.point_ids.begin(), m.point_ids.end(),
                              std::back_inserter(shared));
        if (shared.size() < 5) continue;

        double sc = 0.0;
        for (int pid : shared) {
            const auto& P = points[static_cast<std::size_t>(pid)];
            double v1[3] = {P[0] - r->center[0], P[1] - r->center[1], P[2] - r->center[2]};
            double v2[3] = {P[0] - m.center[0], P[1] - m.center[1], P[2] - m.center[2]};
            const double n1 = std::sqrt(v1[0] * v1[0] + v1[1] * v1[1] + v1[2] * v1[2]) + 1e-9;
            const double n2 = std::sqrt(v2[0] * v2[0] + v2[1] * v2[1] + v2[2] * v2[2]) + 1e-9;
            for (int i = 0; i < 3; ++i) { v1[i] /= n1; v2[i] /= n2; }
            double dot = v1[0] * v2[0] + v1[1] * v2[1] + v1[2] * v2[2];
            dot = std::min(1.0, std::max(-1.0, dot));
            const double ang = std::acos(dot) * 180.0 / M_PI;
            const double sig = (ang <= t0) ? s1 : s2;
            sc += std::exp(-(ang - t0) * (ang - t0) / (2.0 * sig * sig));
        }
        scored.emplace_back(sc, m.name);
    }
    if (static_cast<int>(scored.size()) < k) return {};

    std::sort(scored.begin(), scored.end(),
              [](const auto& a, const auto& b) { return b < a; });   // reverse=True
    std::vector<std::string> out;
    for (int i = 0; i < k; ++i) out.push_back(scored[static_cast<std::size_t>(i)].second);
    return out;
}

std::vector<std::string> nearest(const std::string& ref,
                                 const std::vector<FrameObs>& pool,
                                 int k, double min_base) {
    const FrameObs* r = nullptr;
    for (const auto& f : pool)
        if (f.name == ref) { r = &f; break; }
    if (r == nullptr) return {};

    // 生产:sorted((dist, m) ...) 元组升序 ⇒ 距离相同按名字升序。
    std::vector<std::pair<double, std::string>> d;
    for (const auto& m : pool) {
        if (m.name == ref) continue;
        const double dx = m.center[0] - r->center[0];
        const double dy = m.center[1] - r->center[1];
        const double dz = m.center[2] - r->center[2];
        d.emplace_back(std::sqrt(dx * dx + dy * dy + dz * dz), m.name);
    }
    std::sort(d.begin(), d.end());

    std::vector<std::string> out;
    for (const auto& [dist, name] : d) {
        if (dist < min_base) continue;
        out.push_back(name);
        if (static_cast<int>(out.size()) == k) break;
    }
    return out;
}

std::pair<float, float> drange(const std::vector<float>& obs_pts_world,
                               const std::array<float, 16>& w2c, double s_al) {
    const std::pair<float, float> kFallback{static_cast<float>(0.3 / s_al),
                                            static_cast<float>(4.0 / s_al)};
    const std::size_t n_pts = obs_pts_world.size() / 3;
    if (n_pts < 8) return kFallback;

    // 生产在这一步把 w2c 提到 float64(`w2c_of[n].astype(np.float64)`)。
    std::vector<double> z;
    z.reserve(n_pts);
    const double cut = 0.05 / s_al;
    for (std::size_t i = 0; i < n_pts; ++i) {
        const double x = obs_pts_world[i * 3];
        const double y = obs_pts_world[i * 3 + 1];
        const double w = obs_pts_world[i * 3 + 2];
        const double zc = static_cast<double>(w2c[8]) * x + static_cast<double>(w2c[9]) * y +
                          static_cast<double>(w2c[10]) * w + static_cast<double>(w2c[11]);
        if (zc > cut) z.push_back(zc);
    }
    // ⚠️ 生产在**过滤之后**还查一次 < 8(独立 runner 的 metric_depth_range 没有这一步)。
    if (z.size() < 8) return kFallback;

    std::sort(z.begin(), z.end());
    const double lo = percentile_linear(z, 2.0);
    const double hi = percentile_linear(z, 99.5);
    return {static_cast<float>(std::max(0.1 / s_al, lo * 0.70)),
            static_cast<float>(hi * 1.5)};
}

std::array<float, 3> cam_center(const std::array<float, 16>& w2c) {
    // -R^T @ t;R = w2c[:3,:3](row-major),t = w2c[:3,3]。
    const float t0 = w2c[3], t1 = w2c[7], t2 = w2c[11];
    return {-(w2c[0] * t0 + w2c[4] * t1 + w2c[8] * t2),
            -(w2c[1] * t0 + w2c[5] * t1 + w2c[9] * t2),
            -(w2c[2] * t0 + w2c[6] * t1 + w2c[10] * t2)};
}

std::vector<int> select_views(const std::vector<std::array<float, 16>>& w2c,
                              int ref_local, int n_view, float min_base) {
    const int n = static_cast<int>(w2c.size());
    std::vector<std::array<float, 3>> c(n);
    for (int i = 0; i < n; ++i) c[i] = cam_center(w2c[i]);

    std::vector<double> d(n);
    for (int i = 0; i < n; ++i) {
        const double dx = c[i][0] - c[ref_local][0];
        const double dy = c[i][1] - c[ref_local][1];
        const double dz = c[i][2] - c[ref_local][2];
        d[i] = std::sqrt(dx * dx + dy * dy + dz * dz);
    }

    std::vector<int> order(n);
    for (int i = 0; i < n; ++i) order[i] = i;
    std::stable_sort(order.begin(), order.end(),
                     [&](int a, int b) { return d[a] < d[b]; });

    std::vector<int> cand;
    for (int j : order)
        if (j != ref_local && d[j] >= static_cast<double>(min_base)) cand.push_back(j);
    if (static_cast<int>(cand.size()) < n_view - 1) {
        // 窗口太紧凑,基线门筛不出足够候选 → 退回纯最近(生产同款 fail-open)。
        cand.clear();
        for (int j : order)
            if (j != ref_local) cand.push_back(j);
    }

    std::vector<int> out{ref_local};
    for (int i = 0; i < n_view - 1 && i < static_cast<int>(cand.size()); ++i)
        out.push_back(cand[i]);
    return out;
}


std::pair<float, float> metric_depth_range(const std::vector<float>& pts_world,
                                           const std::array<float, 16>& w2c_ref) {
    constexpr std::pair<float, float> kFallback{0.3f, 4.0f};
    const std::size_t n_pts = pts_world.size() / 3;
    if (n_pts < 8) return kFallback;   // 观测太少,百分位没有意义

    std::vector<double> z;
    z.reserve(n_pts);
    for (std::size_t i = 0; i < n_pts; ++i) {
        const float x = pts_world[i * 3], y = pts_world[i * 3 + 1], w = pts_world[i * 3 + 2];
        // 只要相机系 z:w2c 第三行 · p + t_z。
        const float zc = w2c_ref[8] * x + w2c_ref[9] * y + w2c_ref[10] * w + w2c_ref[11];
        if (zc > 0.05f) z.push_back(static_cast<double>(zc));
    }
    // 生产在这里会让 numpy 抛异常;端上不能崩 → 兜底(见头文件说明)。
    if (z.empty()) return kFallback;

    std::sort(z.begin(), z.end());
    const double lo = percentile_linear(z, 2.0);
    const double hi = percentile_linear(z, 99.5);
    return {static_cast<float>(std::max(0.1, lo * 0.70)),
            static_cast<float>(hi * 1.5)};
}

}  // namespace aether::dense
