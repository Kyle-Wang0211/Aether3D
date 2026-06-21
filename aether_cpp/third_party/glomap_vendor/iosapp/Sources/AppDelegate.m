#import <UIKit/UIKit.h>
#import <ImageIO/ImageIO.h>
#import <os/log.h>

extern int aether_dsp_sift_extract(const uint8_t* gray, int width, int height,
                                   int max_features, float* out_xy,
                                   uint8_t* out_desc, int out_cap, int* out_count);
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
    while (pi.thermalState >= NSProcessInfoThermalStateSerious && waited < 1200) {
      printf("WAIT_COOL thermal=%ld\n", (long)pi.thermalState); fflush(stdout);
      [NSThread sleepForTimeInterval:10]; waited += 10;
    }
    printf("BENCH_START thermal=%ld\n", (long)pi.thermalState); fflush(stdout);
    os_log(OS_LOG_DEFAULT, "BENCH_START");

    const int cap = 20000, K = 25;
    NSString* jA = [[NSBundle mainBundle] pathForResource:@"sift_test" ofType:@"jpg"];
    NSString* jB = [[NSBundle mainBundle] pathForResource:@"sift_test2" ofType:@"jpg"];
    if (!jB) jB = jA;   // fallback: self-match (timing still valid)
    uint8_t* dA = (uint8_t*)malloc((size_t)128 * cap);
    uint8_t* dB = (uint8_t*)malloc((size_t)128 * cap);
    int nA = ExtractFrame(jA, 2048, dA, cap);
    int nB = ExtractFrame(jB, 2048, dB, cap);
    printf("MATCH_EXTRACT nA=%d nB=%d\n", nA, nB); fflush(stdout);
    os_log(OS_LOG_DEFAULT, "MATCH_EXTRACT nA=%d nB=%d", nA, nB);

    struct { const char* name; int (*fn)(const uint8_t*, int, const uint8_t*, int, double, int*); } variants[] = {
      {"naive", aether_gpu_match},
      {"tiled", aether_gpu_match_tiled},
      {"gemm",  aether_gpu_match_gemm},
    };
    for (int v = 0; v < 3; ++v) {
      int nm = 0;
      // warmup (pipeline JIT) then timed
      variants[v].fn(dA, nA, dB, nB, 0.7, &nm);
      NSDate* t = [NSDate date];
      int rc = variants[v].fn(dA, nA, dB, nB, 0.7, &nm);
      double ms = -[t timeIntervalSinceNow] * 1000.0;
      printf("MATCH_BENCH %s rc=%d pair_ms=%.1f matches=%d perframe_ms=%.0f(K=%d)\n",
             variants[v].name, rc, ms, nm, ms * K, K); fflush(stdout);
      os_log(OS_LOG_DEFAULT, "MATCH_BENCH %{public}s rc=%d pair_ms=%.1f matches=%d",
             variants[v].name, rc, ms, nm);
      NSLog(@"MATCH_BENCH %s rc=%d pair_ms=%.1f matches=%d", variants[v].name, rc, ms, nm);
    }
    free(dA); free(dB);
    printf("BENCH_DONE\n"); fflush(stdout);
    os_log(OS_LOG_DEFAULT, "BENCH_DONE");
  });
  return YES;
}
@end
