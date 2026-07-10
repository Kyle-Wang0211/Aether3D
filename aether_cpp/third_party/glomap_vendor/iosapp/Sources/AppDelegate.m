#import <UIKit/UIKit.h>
#import <ImageIO/ImageIO.h>
#import <os/log.h>
#import <unistd.h>
#import <stdio.h>
#import <mach/mach.h>

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
                              int gref, int giter, int gloss, double gftol,
                              int (*thermal_fn)(), char* out_json, int out_cap);
// Real-scenario streaming sim: frame-paced register+BA, per-frame RSS+thermal.
extern int aether_realsim_bench(const char* db_path, const char* image_path,
                                int defer, int skipfin, int frame_interval_ms,
                                int local_loss_type, double local_loss_scale,
                                int global_loss_type, double global_loss_scale,
                                int lnum,
                                int (*thermal_fn)(), char* out_json, int out_cap);
// [AETHER] GLOMAP full global SfM bench (C ABI from bench/glomap_bench.cc) — device
// A/B vs COLMAP incremental: same db, RA+GP+BA+retriangulation, time+mem+reproj.
extern int glomap_bench(const char* db_path, char* out_json, int out_cap);
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

// [AETHER] On-screen real-time console — mirror stdout+stderr (printf + glog progress +
// the final SFM_ASYNC line) to a full-screen UITextView so device-test logs are read
// directly off the phone screen. No USB stream / os_log / root needed (those drop on
// flaky USB and were losing results). STANDARD for ALL device tests going forward.
static UITextView* g_logView = nil;
static dispatch_source_t g_logSrc = nil;
static void AppendScreenLog(NSString* s) {
  dispatch_async(dispatch_get_main_queue(), ^{
    if (!g_logView || !s) return;
    NSString* t = [g_logView.text stringByAppendingString:s];
    if (t.length > 240000) t = [t substringFromIndex:t.length - 160000];  // cap buffer
    g_logView.text = t;
    [g_logView scrollRangeToVisible:NSMakeRange(t.length, 0)];  // autoscroll
  });
}
static FILE* g_logFile = NULL;
static void StartScreenLogMirror(void) {
  // [AETHER] also tee the full console to Documents/aether_console.log so the COMPLETE
  // log can be pulled off-device after a run (devicectl device copy from) — no root, no
  // live stream, survives USB drops. The on-screen view is capped/scrolling; this file
  // is the full record.
  NSString* docs = NSSearchPathForDirectoriesInDomains(
      NSDocumentDirectory, NSUserDomainMask, YES).firstObject;
  g_logFile = fopen(
      [docs stringByAppendingPathComponent:@"aether_console.log"].UTF8String, "w");
  int fds[2];
  if (pipe(fds) != 0) return;
  dup2(fds[1], STDOUT_FILENO);
  dup2(fds[1], STDERR_FILENO);
  setvbuf(stdout, NULL, _IONBF, 0);
  setvbuf(stderr, NULL, _IONBF, 0);
  const int rfd = fds[0];  // scalar capture (blocks can't capture C arrays)
  g_logSrc = dispatch_source_create(DISPATCH_SOURCE_TYPE_READ, rfd, 0,
      dispatch_get_global_queue(QOS_CLASS_UTILITY, 0));
  dispatch_source_set_event_handler(g_logSrc, ^{
    char buf[8192];
    ssize_t n = read(rfd, buf, sizeof(buf) - 1);
    if (n > 0) {
      if (g_logFile) { fwrite(buf, 1, (size_t)n, g_logFile); fflush(g_logFile); }
      NSString* s = [[NSString alloc] initWithBytes:buf length:n
                                           encoding:NSUTF8StringEncoding];
      AppendScreenLog(s);
    }
  });
  dispatch_resume(g_logSrc);
}

// [AETHER] continuous phys_footprint sampler — peak device memory (≈ the iOS jetsam
// metric) for on-device tests. Prints PEAK_MEM_MB after each bench. STANDARD harness.
static volatile double g_peak_mb = 0.0;
static double CurrentFootprintMB(void) {
  task_vm_info_data_t info;
  mach_msg_type_number_t count = TASK_VM_INFO_COUNT;
  if (task_info(mach_task_self(), TASK_VM_INFO, (task_info_t)&info, &count) ==
      KERN_SUCCESS)
    return (double)info.phys_footprint / (1024.0 * 1024.0);
  return -1.0;
}
static void StartMemSampler(void) {
  dispatch_async(dispatch_get_global_queue(QOS_CLASS_BACKGROUND, 0), ^{
    for (;;) {
      double m = CurrentFootprintMB();
      if (m > g_peak_mb) g_peak_mb = m;
      usleep(300000);  // 300ms
    }
  });
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

  // [AETHER] full-screen on-screen console (read device-test logs off the phone screen)
  UITextView* tv = [[UITextView alloc] initWithFrame:vc.view.bounds];
  tv.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
  tv.backgroundColor = [UIColor blackColor];
  tv.textColor = [UIColor greenColor];
  tv.font = [UIFont fontWithName:@"Menlo" size:9.0] ?: [UIFont systemFontOfSize:9.0];
  tv.editable = NO;
  tv.text = @"[AETHER on-screen console]\n";
  if (@available(iOS 11.0, *)) {
    tv.contentInsetAdjustmentBehavior = UIScrollViewContentInsetAdjustmentNever;
  }
  [vc.view addSubview:tv];
  g_logView = tv;
  StartScreenLogMirror();
  StartMemSampler();

  dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
    NSProcessInfo* pi = [NSProcessInfo processInfo];
    // [AETHER] WAIT_COOL gate REMOVED — extreme-environment stress test: run NOW at
    // whatever thermal state the device is in (incl. Critical=3). Validates the app
    // works hot (real users in hot conditions), not just from a cool baseline.
    printf("BENCH_START thermal=%ld (STRESS: no cool-wait)\n", (long)pi.thermalState); fflush(stdout);
    os_log(OS_LOG_DEFAULT, "BENCH_START");

    // ===== SFM_REALSIM: real-scenario streaming sim — frame every 2s × 396,
    // per-frame RSS+proc+thermal, both backends (full-periodic vs local+defer).
    if (0)  // realsim off — full-414 async (build+finalize) focus this build
    {
      NSString* docs = NSSearchPathForDirectoriesInDomains(
          NSDocumentDirectory, NSUserDomainMask, YES).firstObject;
      NSString* dbp = [docs stringByAppendingPathComponent:@"real414_v313_nodesc.db"];
      if ([[NSFileManager defaultManager] fileExistsAtPath:dbp]) {
        char j[512];
        // [AETHER] keep-CAUCHY local pass-2 now raises per-frame cost; verify the live
        // 2s gate on device. local CAUCHY@1.0 (keep-CAUCHY) + global CAUCHY->DENSE.
        printf("REALSIM_GROUP clean  cauchy1.0 ONLY (CAUCHY@1.0 local+global)\n");
        fflush(stdout);
        j[0] = 0;
        // [AETHER] lnum=10: bigger local window (better preview reproj) — verify it
        // still clears the 2s gate on device (lnum=6 was max 1312ms).
        aether_realsim_bench(dbp.UTF8String, "", 1, 0, 2000, 2, 1.0, 2, 1.0, 10,
                             read_thermal, j, (int)sizeof(j));
        printf("REALSIM_RESULT cauchy1.0 %s\n", j); fflush(stdout);
        os_log(OS_LOG_DEFAULT, "REALSIM_RESULT cauchy1.0 %{public}s", j);
      } else {
        printf("REALSIM_NO_DB\n"); fflush(stdout);
      }
    }
    if (1)  // SFM_ASYNC (COLMAP) — the chosen on-device engine (default)
    {
      NSString* docs = NSSearchPathForDirectoriesInDomains(
          NSDocumentDirectory, NSUserDomainMask, YES).firstObject;
      NSString* dbp = [docs stringByAppendingPathComponent:@"real414_v313_nodesc.db"];
      if ([[NSFileManager defaultManager] fileExistsAtPath:dbp]) {
        char j[512];
        // [AETHER] CAUCHY (gloss=2) finalize. Full-scene (>200 reg frames) routes to
        // SPARSE_SCHUR + EIGEN_SPARSE (Eigen LDLT — Apple Accelerate's sparse Cholesky
        // crashed; EIGEN does not). Device-validated: 396f real414 finalize 959-1044s /
        // reproj 0.9606-0.9608 / 5 passes / no crash / thermal 2 / peak 3.07GB.
        j[0] = 0;
        g_peak_mb = 0.0;  // reset peak so PEAK_MEM_MB reflects this run's finalize
        int rc = aether_async_bench(dbp.UTF8String, "", 5, 50, 2 /*CAUCHY*/,
                                    1e-6 /*gftol: converge-stop*/, read_thermal, j,
                                    (int)sizeof(j));
        printf("SFM_ASYNC cauchy_eigen rc=%d %s\n", rc, j); fflush(stdout);
        printf("SFM_ASYNC_PEAK_MEM_MB=%.1f\n", g_peak_mb); fflush(stdout);
        os_log(OS_LOG_DEFAULT, "SFM_ASYNC cauchy_eigen %{public}s peak_mb=%.1f", j,
               g_peak_mb);
      } else {
        printf("SFM_ASYNC_NO_DB\n"); fflush(stdout);
      }
    }
    if (0)  // GLOMAP_BENCH: kept (gated off) as record. GLOMAP is OUT on device — it
    {       // dies at global positioning (OOM/crash) — re-confirmed 2026-07-08: 50f
            // std::bad_alloc @ global_positioning.cc:92, peak 2.7GB on iPhone 14 Pro.
      NSString* docs = NSSearchPathForDirectoriesInDomains(
          NSDocumentDirectory, NSUserDomainMask, YES).firstObject;
      NSString* dbp = [docs stringByAppendingPathComponent:@"real414_v313_nodesc.db"];
      if ([[NSFileManager defaultManager] fileExistsAtPath:dbp]) {
        char gj[1024];
        gj[0] = 0;
        g_peak_mb = 0.0;
        int grc = glomap_bench(dbp.UTF8String, gj, (int)sizeof(gj));
        printf("GLOMAP_BENCH rc=%d %s\n", grc, gj); fflush(stdout);
        printf("GLOMAP_BENCH_PEAK_MEM_MB=%.1f\n", g_peak_mb); fflush(stdout);
        os_log(OS_LOG_DEFAULT, "GLOMAP_BENCH %{public}s peak_mb=%.1f", gj, g_peak_mb);
      } else {
        printf("GLOMAP_BENCH_NO_DB\n"); fflush(stdout);
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
