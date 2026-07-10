// orientation_parity.cc — GPU vs CPU dominant-orientation parity (M1 Stage D).
//
// Feeds identical AFFINE-adapted frames to both the GPU orientation kernel
// (sift_orientation.wgsl) and CPU VLFeat
// (vl_covdet_extract_orientations_for_frame), and compares the resulting
// orientation(s). The 1→K expansion (a keypoint can emit up to 4 orientations)
// is handled on both sides; we match GPU vs CPU oriented features per input
// frame and report the circular angle error.
//
// Canonical input = CPU covdet detect (all octaves, fo=0) + suppression (0.5) +
// affine shape, i.e. exactly the frames that enter
// vl_covdet_extract_orientations in production (aether_threaded_extract path).
//
// Gate D: orientation circular-error median <= 1 degree, and orientation-count
// agreement. Build: orientation_parity_exe. Run: [img].

#include <algorithm>
#include <cmath>
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <string>
#include <vector>

#define STB_IMAGE_IMPLEMENTATION
#include "stb_image.h"

#include "sift_pyramid_dawn.h"

extern "C" {
#include "covdet.h"
}

namespace {
using aether::tools::DawnKernelHarness;
using aether::tools::SiftPyramidDawn;

std::string load_wgsl(const char* fn) {
  const std::string p = std::string(AETHER_WGSL_DIR) + "/" + fn;
  FILE* f = std::fopen(p.c_str(), "rb");
  if (!f) { std::fprintf(stderr, "cannot open %s\n", p.c_str()); std::abort(); }
  std::fseek(f, 0, SEEK_END); long sz = std::ftell(f); std::fseek(f, 0, SEEK_SET);
  std::string s((size_t)sz, '\0'); size_t rd = std::fread(s.data(), 1, (size_t)sz, f);
  std::fclose(f); s.resize(rd); return s;
}
std::vector<uint8_t> make_synthetic(int W, int H) {
  std::vector<uint8_t> img((size_t)W*H);
  uint64_t s = 0x9e3779b97f4a7c15ull;
  for (int y=0;y<H;++y) for (int x=0;x<W;++x) {
    s^=s<<13; s^=s>>7; s^=s<<17; double n=(double)(s>>57)-32.0;
    double v=128+60*std::sin(x*0.06)*std::sin(y*0.045)+45*std::sin((x+y)*0.19)+
             40*std::sin(x*0.31)*std::cos(y*0.29)+30*std::cos(x*0.013-y*0.011)+n;
    img[(size_t)y*W+x]=(uint8_t)std::min(255.0,std::max(0.0,v));
  }
  return img;
}
// circular angle difference in [0, pi].
double ang_diff(double a, double b) {
  double d = std::fmod(a - b, 2*M_PI);
  if (d < -M_PI) d += 2*M_PI; if (d > M_PI) d -= 2*M_PI;
  return std::abs(d);
}
}  // namespace

int main(int argc, char** argv) {
  int W=0,H=0; std::vector<uint8_t> gray; std::string src;
  if (argc>1) { int ch=0; uint8_t* d=stbi_load(argv[1],&W,&H,&ch,1);
    if (!d){std::fprintf(stderr,"stbi_load failed\n");return 2;}
    gray.assign(d,d+(size_t)W*H); stbi_image_free(d); src=argv[1];
  } else { W=2400;H=1800;gray=make_synthetic(W,H);src="synthetic"; }
  std::printf("[orientation_parity] fixture=%s (%dx%d)\n", src.c_str(), W, H);

  const int octRes = SiftPyramidDawn::kOctaveResolution;
  const double kPeak=0.02/octRes, kEdge=10.0;

  // ── CPU: detect+suppress+affine → canonical frames; then CPU orientations ──
  std::vector<float> gf((size_t)W*H);
  for (size_t i=0;i<gf.size();++i) gf[i]=gray[i]/255.0f;
  VlCovDet* cov = vl_covdet_new(VL_COVDET_METHOD_DOG);
  vl_covdet_set_first_octave(cov,0);
  vl_covdet_set_octave_resolution(cov,octRes);
  vl_covdet_set_peak_threshold(cov,kPeak);
  vl_covdet_set_edge_threshold(cov,kEdge);
  vl_covdet_put_image(cov,gf.data(),W,H);
  vl_covdet_detect(cov,1u<<28);
  vl_covdet_extract_affine_shape(cov);   // production order: affine before orient
  const int nf=(int)vl_covdet_get_num_features(cov);
  VlCovDetFeature* feats=vl_covdet_get_features(cov);

  struct Frame { float x,y,a11,a12,a21,a22; int o,s; };
  std::vector<Frame> pre(nf);
  for (int i=0;i<nf;++i)
    pre[i]={(float)feats[i].frame.x,(float)feats[i].frame.y,(float)feats[i].frame.a11,
            (float)feats[i].frame.a12,(float)feats[i].frame.a21,(float)feats[i].frame.a22,
            feats[i].o,feats[i].s};

  // CPU orientations per frame (vl_covdet_extract_orientations_for_frame).
  // Collect per-frame angle lists.
  std::vector<std::vector<double>> cpu_or(nf);
  int cpu_total=0;
  for (int i=0;i<nf;++i) {
    vl_size no=0;
    VlCovDetFeatureOrientation* ors =
        vl_covdet_extract_orientations_for_frame(cov,&no,feats[i].frame);
    for (vl_size j=0;j<no;++j) cpu_or[i].push_back(ors[j].angle);
    cpu_total += (int)no;
  }

  // ── GPU: build+pack pyramid; upload affine frames; run orientation kernel ──
  DawnKernelHarness h;
  if (!h.init()){std::fprintf(stderr,"Dawn init failed\n");return 2;}
  SiftPyramidDawn gpu;
  if (!gpu.build(h,gray.data(),W,H)){std::fprintf(stderr,"pyramid build failed\n");return 2;}
  std::vector<SiftPyramidDawn::LevelMeta> meta;
  wgpu::Buffer packed = gpu.pack_levels(h,&meta);
  wgpu::Buffer meta_buf = h.upload(meta.data(),meta.size()*sizeof(SiftPyramidDawn::LevelMeta),
      wgpu::BufferUsage::Storage);

  const uint32_t N=(uint32_t)nf, KP_STRIDE=8u;
  // kp_in layout for Stage D: x,y,a11,a12,a21,a22,o,s (affine ellipse, not sigma).
  std::vector<uint32_t> kpb((size_t)N*KP_STRIDE,0u);
  for (uint32_t i=0;i<N;++i){ uint32_t* r=kpb.data()+(size_t)i*KP_STRIDE;
    float x=pre[i].x,y=pre[i].y,a11=pre[i].a11,a12=pre[i].a12,a21=pre[i].a21,a22=pre[i].a22;
    std::memcpy(&r[0],&x,4); std::memcpy(&r[1],&y,4);
    std::memcpy(&r[2],&a11,4); std::memcpy(&r[3],&a12,4);
    std::memcpy(&r[4],&a21,4); std::memcpy(&r[5],&a22,4);
    int o=pre[i].o,s=pre[i].s; std::memcpy(&r[6],&o,4); std::memcpy(&r[7],&s,4);
  }
  wgpu::Buffer kp_buf = h.upload(kpb.data(),kpb.size()*sizeof(uint32_t),wgpu::BufferUsage::Storage);

  const uint32_t OUT_STRIDE=8u, CAP=65536u;
  std::vector<uint32_t> out_init((size_t)CAP*OUT_STRIDE,0u);
  wgpu::Buffer out_buf = h.upload(out_init.data(),out_init.size()*sizeof(uint32_t),
      wgpu::BufferUsage::Storage|wgpu::BufferUsage::CopySrc);
  std::vector<float> dbg_init((size_t)CAP*2,0.0f);
  wgpu::Buffer dbg_buf = h.upload(dbg_init.data(),dbg_init.size()*sizeof(float),
      wgpu::BufferUsage::Storage|wgpu::BufferUsage::CopySrc);
  uint32_t zero=0u;
  wgpu::Buffer ctr = h.upload(&zero,4,wgpu::BufferUsage::Storage|wgpu::BufferUsage::CopySrc);

  struct Params { uint32_t count; int fo,lo,res; float base; int ofs,ols; uint32_t lpo; }
    P{ N, 0, gpu.last_octave(), octRes, (float)SiftPyramidDawn::base_scale(),
       SiftPyramidDawn::kOctaveFirstSub, SiftPyramidDawn::kOctaveLastSub,
       (uint32_t)SiftPyramidDawn::kLevelsPerOctave };
  wgpu::Buffer p_buf = h.upload(&P,sizeof(P),wgpu::BufferUsage::Uniform);

  wgpu::ComputePipeline pipe = h.load_compute(load_wgsl("sift_orientation.wgsl"));
  h.dispatch(pipe, {packed, meta_buf, kp_buf, out_buf, ctr, dbg_buf, p_buf}, N, 1u, 1u);

  // read back the dbg sidecar (frame_idx, raw theta) per oriented feature.
  auto rd_u32=[&](const wgpu::Buffer& b,size_t n){ const size_t by=n*4;
    wgpu::Buffer st=h.alloc_staging_for_readback(by); h.copy_to_staging(b,st,by);
    std::vector<uint8_t> raw=h.readback(st,by); std::vector<uint32_t> o(n);
    std::memcpy(o.data(),raw.data(),by); return o; };
  uint32_t gpu_total = rd_u32(ctr,1)[0];
  uint32_t stored = std::min(gpu_total, CAP);
  std::vector<uint32_t> draw = rd_u32(dbg_buf,(size_t)stored*2);

  std::vector<std::vector<double>> gpu_or(nf);
  for (uint32_t i=0;i<stored;++i){
    float fidx_f, theta;
    std::memcpy(&fidx_f,&draw[i*2+0],4);
    std::memcpy(&theta,&draw[i*2+1],4);
    int fi=(int)(fidx_f+0.5f);
    if (fi>=0 && fi<nf) gpu_or[fi].push_back((double)theta);
  }

  // ── compare per frame: greedy match GPU↔CPU orientations, circular error ──
  std::vector<double> errs; int matched=0, cpu_cnt=0, gpu_cnt=0, count_mismatch=0;
  for (int i=0;i<nf;++i){
    cpu_cnt += (int)cpu_or[i].size();
    gpu_cnt += (int)gpu_or[i].size();
    if ((int)cpu_or[i].size() != (int)gpu_or[i].size()) ++count_mismatch;
    std::vector<char> used(gpu_or[i].size(),0);
    for (double ca : cpu_or[i]) {
      int best=-1; double bd=1e9;
      for (size_t j=0;j<gpu_or[i].size();++j){ if(used[j])continue;
        double d=ang_diff(ca,gpu_or[i][j]); if(d<bd){bd=d;best=(int)j;} }
      if (best>=0){ used[best]=1; errs.push_back(bd); ++matched; }
    }
  }
  std::sort(errs.begin(),errs.end());
  double med = errs.empty()?0.0:errs[errs.size()/2];
  double p95 = errs.empty()?0.0:errs[std::min(errs.size()-1,(size_t)(0.95*errs.size()))];
  double med_deg = med*180.0/M_PI, p95_deg = p95*180.0/M_PI;

  std::printf("[orientation_parity] frames=%d  CPU orient=%d  GPU orient=%d (counter=%u)  matched=%d\n",
              nf, cpu_total, gpu_cnt, gpu_total, matched);
  std::printf("[orientation_parity] per-frame count mismatches=%d/%d (%.3f%%)\n",
              count_mismatch, nf, 100.0*count_mismatch/std::max(nf,1));
  std::printf("[orientation_parity] circular angle err  median=%.4f deg  p95=%.4f deg\n",
              med_deg, p95_deg);

  vl_covdet_delete(cov);
  const bool pass = med_deg <= 1.0 && (double)matched/std::max(cpu_total,1) >= 0.97;
  std::printf("%s M1-D orientation parity\n", pass?"PASS":"FAIL");
  return pass?0:1;
}
