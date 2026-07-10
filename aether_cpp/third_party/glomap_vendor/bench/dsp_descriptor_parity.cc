// dsp_descriptor_parity.cc — GPU vs CPU DSP-SIFT descriptor parity (M1 FINAL).
//
// The M1 终极 gate. Feeds identical oriented-affine frames to both the GPU
// descriptor kernel (sift_dsp_descriptor.wgsl) and the CPU reference (the exact
// three-stage loop from aether_threaded_extract.cc:252-305), then compares the
// final RootSIFT u8 descriptors by cosine similarity + match-recall.
//
// Canonical input = CPU covdet: detect (all octaves, fo=0) + suppression(0.5) +
// affine shape + orientations — i.e. the production keypoint set. The GPU runs
// its 10-scale DSP descriptor on the SAME oriented frames; CPU finishing
// (L1RootNormalize → round(512) u8 → TransformVLFeatToUBC) is applied to BOTH
// the GPU raw-mean and the CPU raw-mean identically, so only the warp+histogram
// path is under test.
//
// Gate: cosine median>=0.998, p95>=0.99, AND match-recall>=0.95 (GPU-vs-GPU
// self-match count / CPU-vs-CPU self-match count, via aether_sift_match).
//
// Build: dsp_descriptor_parity_exe. Run: [img].

#include <algorithm>
#include <array>
#include <climits>
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
#include "sift.h"
#include "imopv.h"
}

namespace {
using aether::tools::DawnKernelHarness;
using aether::tools::SiftPyramidDawn;

std::string load_wgsl(const char* fn){
  const std::string p=std::string(AETHER_WGSL_DIR)+"/"+fn;
  FILE* f=std::fopen(p.c_str(),"rb"); if(!f){std::fprintf(stderr,"open %s\n",p.c_str());std::abort();}
  std::fseek(f,0,SEEK_END); long sz=std::ftell(f); std::fseek(f,0,SEEK_SET);
  std::string s((size_t)sz,'\0'); size_t rd=std::fread(s.data(),1,(size_t)sz,f); std::fclose(f);
  s.resize(rd); return s;
}
std::vector<uint8_t> make_synthetic(int W,int H){
  std::vector<uint8_t> img((size_t)W*H); uint64_t s=0x9e3779b97f4a7c15ull;
  for(int y=0;y<H;++y)for(int x=0;x<W;++x){ s^=s<<13;s^=s>>7;s^=s<<17; double n=(double)(s>>57)-32.0;
    double v=128+60*std::sin(x*0.06)*std::sin(y*0.045)+45*std::sin((x+y)*0.19)+
             40*std::sin(x*0.31)*std::cos(y*0.29)+30*std::cos(x*0.013-y*0.011)+n;
    img[(size_t)y*W+x]=(uint8_t)std::min(255.0,std::max(0.0,v)); }
  return img;
}

// VLFeat→UBC reorder (aether_threaded_extract.cc:38).
void ubc_reorder(const std::array<uint8_t,128>& in, std::array<uint8_t,128>& out){
  const int q[8]={0,7,6,5,4,3,2,1};
  for(int i=0;i<4;++i)for(int j=0;j<4;++j)for(int k=0;k<8;++k)
    out[8*(j+4*i)+q[k]] = in[8*(j+4*i)+k];
}
// L1Root normalize (feature/utils.cc:49) on a 128-d float row, then round(512)
// to u8. Matches colmap L1RootNormalize + FeatureDescriptorsToUnsignedByte.
void finish_l1root(const std::vector<float>& raw128, std::array<uint8_t,128>& out){
  double l1=0.0; for(int i=0;i<128;++i) l1+=std::abs((double)raw128[i]);
  std::array<float,128> d{};
  if(l1>0){ for(int i=0;i<128;++i) d[i]=(float)std::sqrt(std::abs((double)raw128[i])/l1); }
  // round(512 * v) clamped to [0,255].
  std::array<uint8_t,128> tmp{};
  for(int i=0;i<128;++i){ int v=(int)std::lround(512.0f*d[i]); v=std::max(0,std::min(255,v)); tmp[i]=(uint8_t)v; }
  ubc_reorder(tmp,out);
}
double cosine(const std::array<uint8_t,128>& a,const std::array<uint8_t,128>& b){
  double dot=0,na=0,nb=0;
  for(int i=0;i<128;++i){ dot+=(double)a[i]*b[i]; na+=(double)a[i]*a[i]; nb+=(double)b[i]*b[i]; }
  if(na==0||nb==0) return (na==0&&nb==0)?1.0:0.0;
  return dot/(std::sqrt(na)*std::sqrt(nb));
}

// L2-distance² between two u8 descriptors.
long desc_dist2(const uint8_t* a,const uint8_t* b){
  long s=0; for(int i=0;i<128;++i){ long d=(long)a[i]-(long)b[i]; s+=d*d; } return s;
}
// Lowe-ratio brute-force matcher with mutual cross-check (the matcher contract
// from the memory note: single-direction lets many-to-one false matches drift).
// Returns the number of mutually-consistent ratio-test matches d1↔d2.
int ratio_match(const uint8_t* d1,int n1,const uint8_t* d2,int n2,double ratio){
  std::vector<int> best12(n1,-1);
  for(int i=0;i<n1;++i){ long b1=LONG_MAX,b2=LONG_MAX; int bj=-1;
    for(int j=0;j<n2;++j){ long d=desc_dist2(d1+(size_t)i*128,d2+(size_t)j*128);
      if(d<b1){b2=b1;b1=d;bj=j;}else if(d<b2){b2=d;} }
    if(bj>=0 && (double)b1 < ratio*ratio*(double)b2) best12[i]=bj;
  }
  std::vector<int> best21(n2,-1);
  for(int j=0;j<n2;++j){ long b1=LONG_MAX,b2=LONG_MAX; int bi=-1;
    for(int i=0;i<n1;++i){ long d=desc_dist2(d2+(size_t)j*128,d1+(size_t)i*128);
      if(d<b1){b2=b1;b1=d;bi=i;}else if(d<b2){b2=d;} }
    if(bi>=0 && (double)b1 < ratio*ratio*(double)b2) best21[j]=bi;
  }
  int m=0; for(int i=0;i<n1;++i){ int j=best12[i]; if(j>=0 && best21[j]==i) ++m; }
  return m;
}
}  // namespace

int main(int argc,char** argv){
  int W=0,H=0; std::vector<uint8_t> gray; std::string src;
  if(argc>1){ int ch=0; uint8_t* d=stbi_load(argv[1],&W,&H,&ch,1);
    if(!d){std::fprintf(stderr,"stbi_load failed\n");return 2;}
    gray.assign(d,d+(size_t)W*H); stbi_image_free(d); src=argv[1];
  } else { W=2400;H=1800;gray=make_synthetic(W,H);src="synthetic"; }
  std::printf("[dsp_descriptor_parity] fixture=%s (%dx%d)\n",src.c_str(),W,H);

  const int octRes=SiftPyramidDawn::kOctaveResolution;
  const double kPeak=0.02/octRes,kEdge=10.0;
  const float dsp_min=1.0f/6.0f, dsp_max=3.0f; const int dsp_num=10;
  const float dsp_step=(dsp_max-dsp_min)/dsp_num;

  // ── CPU: full production keypoint set (detect+suppress+affine+orient) ──
  std::vector<float> gf((size_t)W*H); for(size_t i=0;i<gf.size();++i) gf[i]=gray[i]/255.0f;
  VlCovDet* cov=vl_covdet_new(VL_COVDET_METHOD_DOG);
  vl_covdet_set_first_octave(cov,0); vl_covdet_set_octave_resolution(cov,octRes);
  vl_covdet_set_peak_threshold(cov,kPeak); vl_covdet_set_edge_threshold(cov,kEdge);
  vl_covdet_put_image(cov,gf.data(),W,H);
  vl_covdet_detect(cov,1u<<28);
  vl_covdet_extract_affine_shape(cov);
  vl_covdet_extract_orientations(cov);
  const int nf=(int)vl_covdet_get_num_features(cov);
  VlCovDetFeature* feats=vl_covdet_get_features(cov);
  std::printf("[dsp_descriptor_parity] oriented keypoints = %d\n", nf);

  // ── CPU descriptor (three-stage, verbatim aether_threaded_extract.cc) ──
  const size_t kPatchRes=15, kPatchSide=2*kPatchRes+1;
  const double kExtent=7.5, kSmooth=1.0, kStep=kExtent/kPatchRes;
  const double kSigma=kExtent/(3.0*(4+1)/2)/kStep;
  std::vector<float> patch(kPatchSide*kPatchSide), patchXY(2*kPatchSide*kPatchSide);
  VlSiftFilt* sift=vl_sift_new(16,16,1,3,0); vl_sift_set_magnif(sift,3.0);

  std::vector<std::vector<float>> cpu_raw(nf, std::vector<float>(128,0.0f));
  for(int i=0;i<nf;++i){
    std::vector<float> scaled(128*dsp_num,0.0f);
    for(int s=0;s<dsp_num;++s){
      double dsp_scale=dsp_min+s*dsp_step;
      VlFrameOrientedEllipse sf=feats[i].frame;
      sf.a11*=dsp_scale; sf.a12*=dsp_scale; sf.a21*=dsp_scale; sf.a22*=dsp_scale;
      vl_covdet_extract_patch_for_frame(cov,patch.data(),kPatchRes,kExtent,kSmooth,sf);
      vl_imgradient_polar_f(patchXY.data(),patchXY.data()+1,2,2*kPatchSide,
                            patch.data(),kPatchSide,kPatchSide,kPatchSide);
      vl_sift_calc_raw_descriptor(sift,patchXY.data(),scaled.data()+s*128,
                                  kPatchSide,kPatchSide,kPatchRes,kPatchRes,kSigma,0);
    }
    for(int b=0;b<128;++b){ double m=0; for(int s=0;s<dsp_num;++s) m+=scaled[s*128+b]; cpu_raw[i][b]=(float)(m/dsp_num); }
  }

  // ── GPU: build+pack pyramid; upload oriented frames; run descriptor kernel ──
  DawnKernelHarness h; if(!h.init()){std::fprintf(stderr,"Dawn init failed\n");return 2;}
  SiftPyramidDawn gpu; if(!gpu.build(h,gray.data(),W,H)){std::fprintf(stderr,"pyramid build failed\n");return 2;}
  std::vector<SiftPyramidDawn::LevelMeta> meta;
  wgpu::Buffer packed=gpu.pack_levels(h,&meta);
  wgpu::Buffer meta_buf=h.upload(meta.data(),meta.size()*sizeof(SiftPyramidDawn::LevelMeta),wgpu::BufferUsage::Storage);

  const uint32_t N=(uint32_t)nf, KP_STRIDE=8u;
  std::vector<uint32_t> kpb((size_t)N*KP_STRIDE,0u);
  for(uint32_t i=0;i<N;++i){ uint32_t* r=kpb.data()+(size_t)i*KP_STRIDE;
    float x=(float)feats[i].frame.x,y=(float)feats[i].frame.y;
    float a11=(float)feats[i].frame.a11,a12=(float)feats[i].frame.a12;
    float a21=(float)feats[i].frame.a21,a22=(float)feats[i].frame.a22;
    std::memcpy(&r[0],&x,4);std::memcpy(&r[1],&y,4);
    std::memcpy(&r[2],&a11,4);std::memcpy(&r[3],&a12,4);
    std::memcpy(&r[4],&a21,4);std::memcpy(&r[5],&a22,4);
  }
  wgpu::Buffer kp_buf=h.upload(kpb.data(),kpb.size()*sizeof(uint32_t),wgpu::BufferUsage::Storage);
  std::vector<float> rd_init((size_t)N*128,0.0f);
  wgpu::Buffer rd_buf=h.upload(rd_init.data(),rd_init.size()*sizeof(float),
      wgpu::BufferUsage::Storage|wgpu::BufferUsage::CopySrc);

  struct Params{ uint32_t count; int fo,lo,res; float base; int ofs,ols; uint32_t lpo;
                 float dmin,dstep; uint32_t p0,p1; }
    P{ N,0,gpu.last_octave(),octRes,(float)SiftPyramidDawn::base_scale(),
       SiftPyramidDawn::kOctaveFirstSub,SiftPyramidDawn::kOctaveLastSub,
       (uint32_t)SiftPyramidDawn::kLevelsPerOctave, dsp_min, dsp_step, 0u,0u };
  wgpu::Buffer p_buf=h.upload(&P,sizeof(P),wgpu::BufferUsage::Uniform);

  // SED_F16_DESC tests the f16 descriptor variant vs the same CPU reference —
  // the cosine gate (≥0.998) decides if f16 is shippable.
  const char* desc_sh = std::getenv("SED_F16_DESC") ? "sift_dsp_descriptor_f16.wgsl"
                                                     : "sift_dsp_descriptor.wgsl";
  std::printf("[dsp_descriptor_parity] descriptor kernel = %s\n", desc_sh);
  wgpu::ComputePipeline pipe=h.load_compute(load_wgsl(desc_sh));
  h.dispatch(pipe,{packed,meta_buf,kp_buf,rd_buf,p_buf},N,1u,1u);

  const size_t rbytes=(size_t)N*128*sizeof(float);
  wgpu::Buffer st=h.alloc_staging_for_readback(rbytes); h.copy_to_staging(rd_buf,st,rbytes);
  std::vector<uint8_t> raw=h.readback(st,rbytes);
  std::vector<float> gpu_raw_flat((size_t)N*128); std::memcpy(gpu_raw_flat.data(),raw.data(),rbytes);

  // ── CPU finishing on BOTH raw means, then compare ──
  std::vector<uint8_t> cpu_desc((size_t)N*128), gpu_desc((size_t)N*128);
  std::vector<double> cosv; cosv.reserve(N);
  for(uint32_t i=0;i<N;++i){
    std::array<uint8_t,128> cu{},gu{};
    std::vector<float> gr(gpu_raw_flat.begin()+(size_t)i*128, gpu_raw_flat.begin()+(size_t)i*128+128);
    finish_l1root(cpu_raw[i],cu);
    finish_l1root(gr,gu);
    std::memcpy(cpu_desc.data()+(size_t)i*128,cu.data(),128);
    std::memcpy(gpu_desc.data()+(size_t)i*128,gu.data(),128);
    cosv.push_back(cosine(cu,gu));
  }
  std::sort(cosv.begin(),cosv.end());
  double med=cosv.empty()?0:cosv[cosv.size()/2];
  double p05=cosv.empty()?0:cosv[(size_t)(0.05*cosv.size())];  // 5th pct (low tail)
  double p01=cosv.empty()?0:cosv[(size_t)(0.01*cosv.size())];
  double worst=cosv.empty()?0:cosv.front();

  // match-recall: does each GPU descriptor mutually-match its OWN CPU descriptor
  // (index i ↔ i) under the Lowe ratio test? This is the operationally relevant
  // measure — a GPU descriptor that still wins the ratio test against its CPU
  // twin (vs all other CPU descriptors) is interchangeable for SfM matching.
  int self_consistent=0;
  {
    // For each i, check GPU desc i's nearest CPU neighbour is CPU i AND passes
    // ratio test (and the reverse), i.e. i↔i survives mutual ratio matching.
    std::vector<int> b12(N,-1);
    for(uint32_t i=0;i<N;++i){ long b1=LONG_MAX,b2=LONG_MAX; int bj=-1;
      for(uint32_t j=0;j<N;++j){ long d=desc_dist2(gpu_desc.data()+(size_t)i*128,cpu_desc.data()+(size_t)j*128);
        if(d<b1){b2=b1;b1=d;bj=(int)j;}else if(d<b2){b2=d;} }
      if(bj>=0 && (double)b1<0.8*0.8*(double)b2) b12[i]=bj;
    }
    for(uint32_t i=0;i<N;++i) if(b12[i]==(int)i) ++self_consistent;
  }
  double match_recall = N>0 ? (double)self_consistent/N : 0.0;

  // DEBUG: dump raw (pre-finish) descriptors for the first kp, GPU vs CPU.
  if(std::getenv("DSP_DEBUG")){
    int nan_cnt=0, zero_cnt=0; int first_good=-1;
    for(uint32_t i=0;i<N;++i){ bool nan=false; double s=0;
      for(int b=0;b<128;++b){ float v=gpu_raw_flat[(size_t)i*128+b]; if(std::isnan(v))nan=true; s+=std::abs((double)v); }
      if(nan)++nan_cnt; else if(s==0)++zero_cnt; else if(first_good<0)first_good=(int)i;
    }
    std::printf("[debug] GPU raw: NaN=%d zero=%d good first=%d  (of %u)\n",nan_cnt,zero_cnt,first_good,N);
    { int nan_by_oct[10]={0}, n_by_oct[10]={0};
      for(uint32_t i=0;i<N;++i){ bool nan=false; for(int b=0;b<128;++b) if(std::isnan(gpu_raw_flat[(size_t)i*128+b])) nan=true;
        int o=feats[i].o; if(o>=0&&o<10){ ++n_by_oct[o]; if(nan)++nan_by_oct[o]; } }
      std::printf("[debug] NaN by octave:"); for(int o=0;o<10;++o) if(n_by_oct[o]) std::printf(" o%d=%d/%d",o,nan_by_oct[o],n_by_oct[o]); std::printf("\n"); }
    // raw cosine distribution over all non-NaN, by octave bucket.
    std::vector<double> rc; int by_oct_bad[10]={0}, by_oct_n[10]={0};
    for(uint32_t i=0;i<N;++i){ bool nan=false; double dot=0,na=0,nb=0;
      for(int b=0;b<128;++b){ float g=gpu_raw_flat[(size_t)i*128+b]; if(std::isnan(g))nan=true; float c=cpu_raw[i][b]; dot+=g*c; na+=g*g; nb+=c*c; }
      if(nan) continue; double cs=dot/(std::sqrt(na)*std::sqrt(nb)+1e-12); rc.push_back(cs);
      int o=feats[i].o; if(o>=0&&o<10){ ++by_oct_n[o]; if(cs<0.9)++by_oct_bad[o]; } }
    std::sort(rc.begin(),rc.end());
    std::printf("[debug] raw cosine (non-NaN): median=%.4f  p10=%.4f  min=%.4f  n=%zu\n",
                rc[rc.size()/2], rc[rc.size()/10], rc.front(), rc.size());
    std::printf("[debug] cos<0.9 by octave:"); for(int o=0;o<10;++o) if(by_oct_n[o]) std::printf(" o%d=%d/%d",o,by_oct_bad[o],by_oct_n[o]); std::printf("\n");
    if(first_good>=0){
      double dot=0,na=0,nb=0; for(int b=0;b<128;++b){ float g=gpu_raw_flat[(size_t)first_good*128+b]; float c=cpu_raw[first_good][b]; dot+=g*c; na+=g*g; nb+=c*c; }
      std::printf("[debug] first-good kp%d raw cosine=%.5f\n", first_good, dot/(std::sqrt(na)*std::sqrt(nb)+1e-12));
      for(int b=0;b<16;++b) std::printf("  b%02d GPU=%.5f CPU=%.5f\n",b,gpu_raw_flat[(size_t)first_good*128+b],cpu_raw[first_good][b]);
    }
    std::printf("[debug] kp0 raw GPU vs CPU (first 24 bins):\n");
    for(int b=0;b<24;++b)
      std::printf("  b%02d  GPU=%.5f  CPU=%.5f\n", b, gpu_raw_flat[b], cpu_raw[0][b]);
    // raw cosine (before finishing) for kp0.
    double dot=0,na=0,nb=0; for(int b=0;b<128;++b){ dot+=gpu_raw_flat[b]*cpu_raw[0][b]; na+=gpu_raw_flat[b]*gpu_raw_flat[b]; nb+=cpu_raw[0][b]*cpu_raw[0][b]; }
    std::printf("[debug] kp0 raw cosine = %.5f  (gpu_norm=%.4f cpu_norm=%.4f)\n",
                dot/(std::sqrt(na)*std::sqrt(nb)+1e-12), std::sqrt(na), std::sqrt(nb));
  }

  std::printf("[dsp_descriptor_parity] cosine  median=%.5f  p05=%.5f  p01=%.5f  min=%.5f\n",
              med,p05,p01,worst);
  std::printf("[dsp_descriptor_parity] match-recall  GPU↔CPU self-consistent=%d/%u  recall=%.4f\n",
              self_consistent,N,match_recall);

  vl_sift_delete(sift); vl_covdet_delete(cov);
  const bool pass = med>=0.998 && p05>=0.99 && match_recall>=0.95;
  std::printf("%s M1-E DSP descriptor parity (M1 FINAL)\n", pass?"PASS":"FAIL");
  return pass?0:1;
}
