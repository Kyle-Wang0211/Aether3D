// Byte-exact parity test: compute the 'o' pre-proc for a fixed input, write float32
// binary. A Python reference computes the same; the bytes must be identical.
#include "dense_preproc.h"
#include <cstdio>
#include <fstream>
#include <sstream>
#include <string>
#include <array>
#include <vector>
using namespace aether::dense;

int main(int argc, char** argv) {
    // Fixed test input (realistic 896x512 intrinsics + a w2c + depth range).
    std::array<float, 9> K_npz = {  // as if baked at 504-tall (row1 will be scaled)
        712.3f, 0.0f, 447.9f,
        0.0f, 701.6f, 251.4f,
        0.0f, 0.0f, 1.0f};
    std::array<float, 16> w2c = {
        0.9975f, -0.0123f, 0.0701f, -0.1532f,
        0.0140f, 0.9994f, -0.0301f, 0.0442f,
       -0.0698f, 0.0310f, 0.9971f, 0.2087f,
        0.0f, 0.0f, 0.0f, 1.0f};
    float dmin = 0.2168f, dmax = 1.9834f;

    FILE* f = fopen("cpp_preproc.bin", "wb");
    // (1) scaled_K
    auto Ks = scaled_K(K_npz);
    fwrite(Ks.data(), sizeof(float), 9, f);
    // (2) make_proj_stage for all 4 stages, using the SCALED K (as the pipeline does)
    for (float s : STAGE_SCALES) {
        auto p = make_proj_stage(w2c, Ks, s);
        fwrite(p.data(), sizeof(float), 32, f);
    }
    // (3) depth_values
    auto dv = depth_values(dmin, dmax);
    fwrite(dv.data(), sizeof(float), NUM_DEPTH, f);
    fclose(f);

    // (4) select_views / metric_depth_range —— 输入由参考发生器写出的 raw f32
    //     (同一份数据喂两边,否则比的是两组不同输入的结果,不是 parity)。
    const char* dir = argc > 1 ? argv[1] : ".";
    char path[1024];
    snprintf(path, sizeof(path), "%s/ref_preproc.w2c.bin", dir);
    FILE* fw = fopen(path, "rb");
    if (!fw) { printf("MISSING %s\n", path); return 2; }
    std::vector<std::array<float, 16>> w2cs;
    std::array<float, 16> m{};
    while (fread(m.data(), sizeof(float), 16, fw) == 16) w2cs.push_back(m);
    fclose(fw);

    snprintf(path, sizeof(path), "%s/ref_preproc.pts.bin", dir);
    FILE* fp = fopen(path, "rb");
    if (!fp) { printf("MISSING %s\n", path); return 2; }
    std::vector<float> pts;
    float v;
    while (fread(&v, sizeof(float), 1, fp) == 1) pts.push_back(v);
    fclose(fp);

    auto sel = select_views(w2cs, /*ref_local=*/0, /*n_view=*/5);
    auto [rmin, rmax] = metric_depth_range(pts, w2cs[0]);

    FILE* g = fopen("cpp_preproc.sel.txt", "w");
    for (std::size_t i = 0; i < sel.size(); ++i)
        fprintf(g, "%s%d", i ? "," : "", sel[i]);
    fprintf(g, "\n%.9g,%.9g\n", static_cast<double>(rmin), static_cast<double>(rmax));
    fclose(g);

    // (5) 'o' 路径:covis_select / nearest / drange —— 同一份输入喂两边。
    snprintf(path, sizeof(path), "%s/ref_preproc.opts.bin", dir);
    FILE* fo = fopen(path, "rb");
    if (!fo) { printf("MISSING %s\n", path); return 2; }
    std::vector<std::array<float, 3>> opts;
    std::array<float, 3> P{};
    while (fread(P.data(), sizeof(float), 3, fo) == 3) opts.push_back(P);
    fclose(fo);

    snprintf(path, sizeof(path), "%s/ref_preproc.oobs.txt", dir);
    std::ifstream fi(path);
    if (!fi) { printf("MISSING %s\n", path); return 2; }
    std::vector<FrameObs> pool;
    std::string line;
    while (std::getline(fi, line)) {
        if (line.empty()) continue;
        std::istringstream ss(line);
        FrameObs fo2;
        ss >> fo2.name >> fo2.center[0] >> fo2.center[1] >> fo2.center[2];
        int id;
        while (ss >> id) fo2.point_ids.push_back(id);
        pool.push_back(std::move(fo2));
    }

    auto cv = covis_select(pool[0].name, pool, opts, 4);
    auto nr = nearest(pool[0].name, pool, 4, 0.06);
    std::array<float, 16> w2c_o{1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1, -1, 0, 0, 0, 1};
    std::vector<float> flat;
    for (const auto& q : opts) { flat.push_back(q[0]); flat.push_back(q[1]); flat.push_back(q[2]); }
    auto [dlo, dhi] = drange(flat, w2c_o, 1.37);

    FILE* h = fopen("cpp_preproc.opath.txt", "w");
    if (cv.empty()) fprintf(h, "NONE\n");
    else {
        for (std::size_t i = 0; i < cv.size(); ++i) fprintf(h, "%s%s", i ? "," : "", cv[i].c_str());
        fprintf(h, "\n");
    }
    for (std::size_t i = 0; i < nr.size(); ++i) fprintf(h, "%s%s", i ? "," : "", nr[i].c_str());
    fprintf(h, "\n%.9g,%.9g\n", static_cast<double>(dlo), static_cast<double>(dhi));
    fclose(h);

    printf("wrote cpp_preproc.{bin,sel.txt,opath.txt}\n");
    return 0;
}
