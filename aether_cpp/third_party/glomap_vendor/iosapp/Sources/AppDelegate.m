#import <UIKit/UIKit.h>
#import <ImageIO/ImageIO.h>
#import <os/log.h>

extern int aether_dsp_sift_extract(const uint8_t* gray, int width, int height,
                                   int max_features, float* out_xy,
                                   uint8_t* out_desc, int out_cap, int* out_count);
extern int aether_dsp_sift_extract_threaded(const uint8_t* gray, int width, int height,
                                            int max_features, int num_threads,
                                            float* out_xy, uint8_t* out_desc,
                                            int out_cap, int* out_count);
extern int aether_dsp_sift_selfcheck(const uint8_t* gray, int width, int height,
                                     int max_features, int num_threads,
                                     int* out_n_serial, int* out_n_threaded,
                                     int* out_max_abs_desc_diff);
extern int aether_gpu_match(const uint8_t*, int, const uint8_t*, int, double, int*);
extern int aether_gpu_match_tiled(const uint8_t*, int, const uint8_t*, int, double, int*);
extern int aether_gpu_match_gemm(const uint8_t*, int, const uint8_t*, int, double, int*);
// Per-frame SLA bench: run incremental SfM on a prebuilt db, return per-frame
// registration deltas (the real-hardware BA cost the desktop could only estimate).
extern int aether_perframe_bench(const char* db_path, const char* image_path,
                                 int defer, int lnum, int liter, int mt,
                                 int gref, int giter, double* out_deltas_ms,
                                 int max_deltas, int* out_n_deltas,
                                 double* out_reproj, int* out_n_reg,
                                 double* out_total_ms);
// Async-finalize validation: local (instant) vs refined (background) time+reproj.
// gref/giter = global-BA finalize iteration cap; thermal_fn samples NSProcessInfo.
extern int aether_async_bench(const char* db_path, const char* image_path,
                              int gref, int giter, int gloss, int (*thermal_fn)(),
                              char* out_json, int out_cap);
// Real-scenario streaming sim: frame-paced register+BA, per-frame RSS+thermal.
extern int aether_realsim_bench(const char* db_path, const char* image_path,
                                int defer, int skipfin, int frame_interval_ms,
                                int local_loss_type, double local_loss_scale,
                                int global_loss_type, double global_loss_scale,
                                int (*thermal_fn)(), char* out_json, int out_cap);
static int read_thermal(void) {
  return (int)[NSProcessInfo processInfo].thermalState;  // 0=nominal..3=critical
}

static int cmp_d(const void* a, const void* b) {
  double x = *(const double*)a, y = *(const double*)b;
  return (x < y) ? -1 : (x > y) ? 1 : 0;
}
static double pctl(const double* s, int n, double p) {
  if (n <= 0) return 0;
  double k = (n - 1) * p / 100.0; int f = (int)k; int c = (f + 1 < n) ? f + 1 : f;
  return s[f] + (s[c] - s[f]) * (k - f);
}

static uint8_t* DecodeGray(NSString* path, int maxEdge, int* outW, int* outH) {
  CGImageSourceRef src = CGImageSourceCreateWithURL(
      (__bridge CFURLRef)[NSURL fileURLWithPath:path], NULL);
  if (!src) return NULL;
  NSDictionary* opts = @{
    (id)kCGImageSourceCreateThumbnailFromImageAlways : @YES,
    (id)kCGImageSourceThumbnailMaxPixelSize : @(maxEdge),
    (id)kCGImageSourceCreateThumbnailWithTransform : @YES,
  };
  CGImageRef cg = CGImageSourceCreateThumbnailAtIndex(src, 0, (__bridge CFDictionaryRef)opts);
  CFRelease(src);
  if (!cg) return NULL;
  int w = (int)CGImageGetWidth(cg), h = (int)CGImageGetHeight(cg);
  uint8_t* gray = (uint8_t*)calloc((size_t)w * h, 1);
  CGColorSpaceRef cs = CGColorSpaceCreateDeviceGray();
  CGContextRef ctx = CGBitmapContextCreate(gray, w, h, 8, w, cs, (CGBitmapInfo)kCGImageAlphaNone);
  CGColorSpaceRelease(cs);
  if (!ctx) { free(gray); CGImageRelease(cg); return NULL; }
  CGContextTranslateCTM(ctx, 0, h); CGContextScaleCTM(ctx, 1, -1);
  CGContextDrawImage(ctx, CGRectMake(0, 0, w, h), cg);
  CGContextRelease(ctx); CGImageRelease(cg);
  *outW = w; *outH = h; return gray;
}

static int ExtractFrame(NSString* jpg, int maxEdge, uint8_t* desc, int cap) {
  int w = 0, h = 0; uint8_t* gray = DecodeGray(jpg, maxEdge, &w, &h);
  if (!gray) return -1;
  float* xy = (float*)malloc(sizeof(float) * 2 * cap); int n = 0;
  aether_dsp_sift_extract(gray, w, h, 8192, xy, desc, cap, &n);
  free(gray); free(xy); return n;
}

@interface AppDelegate : UIResponder <UIApplicationDelegate>
@property(strong, nonatomic) UIWindow* window;
@end

@implementation AppDelegate
- (BOOL)application:(UIApplication*)app didFinishLaunchingWithOptions:(NSDictionary*)opt {
  self.window = [[UIWindow alloc] initWithFrame:[[UIScreen mainScreen] bounds]];
  UIViewController* vc = [UIViewController new];
  vc.view.backgroundColor = [UIColor blackColor];
  self.window.rootViewController = vc;
  [self.window makeKeyAndVisible];
  dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
    NSProcessInfo* pi = [NSProcessInfo processInfo];
    // [AETHER] WAIT_COOL gate REMOVED — extreme-environment stress test: run NOW at
    // whatever thermal state the device is in (incl. Critical=3). Validates the app
    // works hot (real users in hot conditions), not just from a cool baseline.
    printf("BENCH_START thermal=%ld (STRESS: no cool-wait)\n", (long)pi.thermalState); fflush(stdout);
    os_log(OS_LOG_DEFAULT, "BENCH_START");

    // ===== SFM_REALSIM: real-scenario streaming sim — frame every 2s × 396,
    // per-frame RSS+proc+thermal, both backends (full-periodic vs local+defer).
    if (0)  // disabled — async-finalize (production-exact) focus this build
    {
      NSString* docs = NSSearchPathForDirectoriesInDomains(
          NSDocumentDirectory, NSUserDomainMask, YES).firstObject;
      NSString* dbp = [docs stringByAppendingPathComponent:@"real414_v313_nodesc.db"];
      if ([[NSFileManager defaultManager] fileExistsAtPath:dbp]) {
        char j[512];
        // CLEAN single-config run: CAUCHY@1.0 ONLY in a fresh process (no orig
        // residual memory / no thermal carryover). defer=1 = local per-frame +
        // global at finalize. Gives clean per-frame proc + RSS + thermal + the
        // location of the big global-BA spike (which frame i= it lands on).
        printf("REALSIM_GROUP clean  cauchy1.0 ONLY (CAUCHY@1.0 local+global)\n");
        fflush(stdout);
        j[0] = 0;
        aether_realsim_bench(dbp.UTF8String, "", 1, 0, 2000, 2, 1.0, 2, 1.0,
                             read_thermal, j, (int)sizeof(j));
        printf("REALSIM_RESULT cauchy1.0 %s\n", j); fflush(stdout);
        os_log(OS_LOG_DEFAULT, "REALSIM_RESULT cauchy1.0 %{public}s", j);
      } else {
        printf("REALSIM_NO_DB\n"); fflush(stdout);
      }
    }
    if (1)  // SFM_ASYNC: production-exact (instant local + async RefineReconstruction)
    {
      NSString* docs = NSSearchPathForDirectoriesInDomains(
          NSDocumentDirectory, NSUserDomainMask, YES).firstObject;
      NSString* dbp = [docs stringByAppendingPathComponent:@"real414_v313_nodesc.db"];
      if ([[NSFileManager defaultManager] fileExistsAtPath:dbp]) {
        char j[512];
        // [AETHER] THE FIX: CAUCHY (gloss=2) now routes to DENSE_SCHUR (Eigen, not the
        // Accelerate sparse Cholesky that crashed) for <=200-frame selected regions.
        // Mac: 22s @ reproj 0.8415 (vs ITERATIVE 76s/0.8459). Validate on device: does
        // Eigen dense Cholesky succeed + real refine_ms + thermal? gref=5 full quality.
        j[0] = 0;
        int rc = aether_async_bench(dbp.UTF8String, "", 5, 50, 2 /*CAUCHY->DENSE*/,
                                    read_thermal, j, (int)sizeof(j));
        printf("SFM_ASYNC cauchy_dense rc=%d %s\n", rc, j); fflush(stdout);
        os_log(OS_LOG_DEFAULT, "SFM_ASYNC cauchy_dense %{public}s", j);
      } else {
        printf("SFM_ASYNC_NO_DB\n"); fflush(stdout);
      }
    }

    // ===== SFM_BENCH: per-frame registration cost on the real-res db =====
    // db (features+matches, 396 frames @2048, 9555 kp/img) is pushed to the app's
    // Documents container. defer=1 (shipped config). Finalize capped (gref1/giter15)
    // for speed — per-frame deltas (the BA-factor we want) are unaffected; reproj
    // is then the capped value (full-finalize reproj is the desktop 1.1455).
    {
      NSString* docs = NSSearchPathForDirectoriesInDomains(
          NSDocumentDirectory, NSUserDomainMask, YES).firstObject;
      NSString* dbp = [docs stringByAppendingPathComponent:@"real414_v313_nodesc.db"];
      if (![[NSFileManager defaultManager] fileExistsAtPath:dbp]) {
        printf("SFM_NO_DB path=%s\n", dbp.UTF8String); fflush(stdout);
        os_log(OS_LOG_DEFAULT, "SFM_NO_DB %{public}s", dbp.UTF8String);
      } else {
        const int maxd = 512;
        double* deltas = (double*)malloc(sizeof(double) * maxd);
        double* srt = (double*)malloc(sizeof(double) * maxd);
        struct { const char* label; int lnum; int liter; } cfgs[] = {
          {"defer_lnum6", 0, 15},   // best reproj (1.1455), desktop max 511ms
          {"defer_lnum4", 4, 15},   // margin (1.1574), desktop max 389ms
        };
        for (int c = 0; c < 0; ++c) {  // per-frame SFM_BENCH gated off this build
          int nd = 0, nreg = 0; double reproj = 0, total = 0;
          printf("SFM_RUN cfg=%s start thermal=%ld\n", cfgs[c].label,
                 (long)[NSProcessInfo processInfo].thermalState); fflush(stdout);
          int rc = aether_perframe_bench(
              dbp.UTF8String, docs.UTF8String, 1, cfgs[c].lnum, cfgs[c].liter,
              6000, 1, 15, deltas, maxd, &nd, &reproj, &nreg, &total);
          memcpy(srt, deltas, sizeof(double) * (nd > 0 ? nd : 1));
          qsort(srt, nd, sizeof(double), cmp_d);
          int over = 0; for (int i = 0; i < nd; ++i) if (deltas[i] > 2000) over++;
          double mx = (nd > 0) ? srt[nd - 1] : 0;
          printf("SFM_BENCH cfg=%s rc=%d nreg=%d total_ms=%.0f n=%d med=%.0f "
                 "p90=%.0f p95=%.0f p99=%.0f max=%.0f over2s=%d\n",
                 cfgs[c].label, rc, nreg, total, nd, pctl(srt,nd,50),
                 pctl(srt,nd,90), pctl(srt,nd,95), pctl(srt,nd,99), mx, over);
          fflush(stdout);
          os_log(OS_LOG_DEFAULT, "SFM_BENCH cfg=%{public}s rc=%d nreg=%d total=%.0f "
                 "med=%.0f p90=%.0f p95=%.0f p99=%.0f max=%.0f over2s=%d",
                 cfgs[c].label, rc, nreg, total, pctl(srt,nd,50), pctl(srt,nd,90),
                 pctl(srt,nd,95), pctl(srt,nd,99), mx, over);
        }
        free(deltas); free(srt);
      }
    }

    const int cap = 30000;
    NSString* jA = [[NSBundle mainBundle] pathForResource:@"sift_test" ofType:@"jpg"];

    // EXTRACT_BENCH: threaded DSP-SIFT vs serial. Correctness (bit-identical
    // selfcheck) + speedup at 2048 (recipe) and 4224 (target quality route).
    int resolutions[] = {2048, 4224};
    for (int r = 0; r < 0; ++r) {  // EXTRACT disabled this build (SFM_BENCH focus)
      const int res = resolutions[r];
      int w = 0, h = 0;
      uint8_t* gray = DecodeGray(jA, res, &w, &h);
      if (!gray) { printf("EXTRACT_DECODE_FAIL res=%d\n", res); fflush(stdout); continue; }
      printf("EXTRACT_RES res=%d img=%dx%d\n", res, w, h); fflush(stdout);
      os_log(OS_LOG_DEFAULT, "EXTRACT_RES res=%d img=%dx%d", res, w, h);

      // correctness gate: serial vs threaded must be bit-identical.
      int ns = 0, nt = 0, maxd = -1;
      int sc = aether_dsp_sift_selfcheck(gray, w, h, 8192, 4, &ns, &nt, &maxd);
      const char* verdict =
          (sc == 0 && ns == nt && ns > 0 && maxd == 0) ? "PASS" : "FAIL";
      printf("EXTRACT_SELFCHECK res=%d sc=%d n_serial=%d n_threaded=%d max_abs_desc_diff=%d %s\n",
             res, sc, ns, nt, maxd, verdict); fflush(stdout);
      os_log(OS_LOG_DEFAULT, "EXTRACT_SELFCHECK res=%d ns=%d nt=%d maxd=%d %{public}s",
             res, ns, nt, maxd, verdict);

      float* xy = (float*)malloc(sizeof(float) * 2 * cap);
      uint8_t* dd = (uint8_t*)malloc((size_t)128 * cap);
      int n = 0;

      NSDate* t0 = [NSDate date];
      aether_dsp_sift_extract(gray, w, h, 8192, xy, dd, cap, &n);
      double sms = -[t0 timeIntervalSinceNow] * 1000.0;
      printf("EXTRACT_BENCH res=%d serial n=%d ms=%.0f\n", res, n, sms); fflush(stdout);
      os_log(OS_LOG_DEFAULT, "EXTRACT_BENCH res=%d serial n=%d ms=%.0f", res, n, sms);

      int tcs[] = {2, 4, 6};
      for (int k = (res >= 4224 ? 1 : 0); k < 3; ++k) {  // 4224: T={4,6}; 2048: T={2,4,6}
        NSDate* t1 = [NSDate date];
        aether_dsp_sift_extract_threaded(gray, w, h, 8192, tcs[k], xy, dd, cap, &n);
        double tms = -[t1 timeIntervalSinceNow] * 1000.0;
        printf("EXTRACT_BENCH res=%d threaded T=%d n=%d ms=%.0f speedup=%.2fx\n",
               res, tcs[k], n, tms, sms / tms); fflush(stdout);
        os_log(OS_LOG_DEFAULT, "EXTRACT_BENCH res=%d threaded T=%d n=%d ms=%.0f speedup=%.2f",
               res, tcs[k], n, tms, sms / tms);
      }
      free(xy); free(dd); free(gray);
    }
    printf("BENCH_DONE\n"); fflush(stdout);
    os_log(OS_LOG_DEFAULT, "BENCH_DONE");
  });
  return YES;
}
@end
