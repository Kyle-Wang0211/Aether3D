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
    int waited = 0;
    while (pi.thermalState >= NSProcessInfoThermalStateCritical && waited < 1200) {
      printf("WAIT_COOL thermal=%ld\n", (long)pi.thermalState); fflush(stdout);
      [NSThread sleepForTimeInterval:10]; waited += 10;
    }
    printf("BENCH_START thermal=%ld\n", (long)pi.thermalState); fflush(stdout);
    os_log(OS_LOG_DEFAULT, "BENCH_START");

    const int cap = 30000;
    NSString* jA = [[NSBundle mainBundle] pathForResource:@"sift_test" ofType:@"jpg"];

    // EXTRACT_BENCH: threaded DSP-SIFT vs serial. Correctness (bit-identical
    // selfcheck) + speedup at 2048 (recipe) and 4224 (target quality route).
    int resolutions[] = {2048, 4224};
    for (int r = 0; r < 2; ++r) {
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
