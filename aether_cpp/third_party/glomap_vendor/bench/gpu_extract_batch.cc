// gpu_extract_batch.cc — batch GPU DSP-SIFT over a frame list, for the
// "GPU-extract -> full SfM -> 9-gate" frontend validation. Reuses the
// persistent pipeline-cached harness (dsp_sift_gpu_c) so all N frames share one
// Dawn init + compiled pipelines (warm ~0.24s/frame on M3).
//
// Input : frames.txt, each line "<name>\t<abs_jpeg_path>"
// Output: <outdir>/<name>.feat  binary =
//           int32 n_kp
//           float32 xy[2*n_kp]        (COLMAP x,y at native resolution)
//           uint8   desc[128*n_kp]    (finished RootSIFT, COLMAP-compatible)
//
// Usage: gpu_extract_batch_exe frames.txt outdir [max_feat=8192]

#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <fstream>
#include <string>
#include <vector>

#define STB_IMAGE_IMPLEMENTATION
#include "stb_image.h"

extern "C" int aether_dsp_sift_extract_gpu(const uint8_t*, int, int, int, int,
                                           float*, uint8_t*, int, int*);

int main(int argc, char** argv) {
    if (argc < 3) {
        std::fprintf(stderr, "usage: %s frames.txt outdir [max_feat=8192]\n", argv[0]);
        return 2;
    }
    const std::string list_path = argv[1];
    const std::string outdir = argv[2];
    const int max_feat = (argc > 3) ? std::atoi(argv[3]) : 8192;

    std::ifstream in(list_path);
    if (!in) { std::fprintf(stderr, "cannot open %s\n", list_path.c_str()); return 2; }

    const int cap = 40000;
    std::vector<float> xy(2 * cap);
    std::vector<uint8_t> desc((size_t)128 * cap);

    std::string line;
    int done = 0, total_kp = 0, failed = 0;
    while (std::getline(in, line)) {
        if (line.empty()) continue;
        auto tab = line.find('\t');
        if (tab == std::string::npos) continue;
        std::string name = line.substr(0, tab);
        std::string path = line.substr(tab + 1);

        int W = 0, H = 0, ch = 0;
        uint8_t* d = stbi_load(path.c_str(), &W, &H, &ch, 1);  // grayscale
        if (!d) { std::fprintf(stderr, "  [FAIL load] %s\n", path.c_str()); ++failed; continue; }

        int n = 0;
        int rc = aether_dsp_sift_extract_gpu(d, W, H, max_feat, 0,
                                             xy.data(), desc.data(), cap, &n);
        stbi_image_free(d);
        if (rc != 0) { std::fprintf(stderr, "  [FAIL extract rc=%d] %s\n", rc, name.c_str()); ++failed; continue; }

        std::string outp = outdir + "/" + name + ".feat";
        std::ofstream out(outp, std::ios::binary);
        int32_t n32 = n;
        out.write(reinterpret_cast<const char*>(&n32), sizeof(n32));
        out.write(reinterpret_cast<const char*>(xy.data()), (std::streamsize)sizeof(float) * 2 * n);
        out.write(reinterpret_cast<const char*>(desc.data()), (std::streamsize)128 * n);
        out.close();

        total_kp += n;
        if (++done % 40 == 0)
            std::printf("[batch] %d frames, last=%s n_kp=%d\n", done, name.c_str(), n);
    }
    std::printf("[batch] DONE frames=%d total_kp=%d mean=%.0f failed=%d\n",
                done, total_kp, done ? (double)total_kp / done : 0.0, failed);
    return failed ? 1 : 0;
}
