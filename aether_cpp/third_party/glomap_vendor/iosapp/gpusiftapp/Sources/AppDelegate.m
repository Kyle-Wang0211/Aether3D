// GpuSiftBench AppDelegate — GlomapBench device-harness pattern:
//   * full-screen on-screen UITextView console mirroring stdout+stderr (read the
//     log straight off the phone screen; survives USB drops, no root/os_log).
//   * tee the COMPLETE console to Documents/aether_console.log (pull after the run
//     via `xcrun devicectl device copy from` — no root).
//   * continuous phys_footprint sampler -> peak RSS (the iOS jetsam metric).
//   * thermalState (NSProcessInfo) logged before + after the run.
// It inits the GPU DSP-SIFT extractor ONCE then runs extract() x10 on the bundled
// 4224x2376 sift_test.jpg (decoded to row-major float grayscale 0..255).

#import <UIKit/UIKit.h>
#import <ImageIO/ImageIO.h>
#import <os/log.h>
#import <unistd.h>
#import <stdio.h>
#import <mach/mach.h>

// Runner (gpu_sift_run.mm). gray = row-major float intensity (0..255), w*h.
extern int gpu_sift_run_all(const char* shader_root, const float* gray,
                            int w, int h, char* out, int out_cap);

// ── On-screen console: mirror stdout+stderr to a full-screen UITextView + tee
//    the full stream to Documents/aether_console.log. ──
static UITextView* g_logView = nil;
static dispatch_source_t g_logSrc = nil;
static FILE* g_logFile = NULL;

static void AppendScreenLog(NSString* s) {
  dispatch_async(dispatch_get_main_queue(), ^{
    if (!g_logView || !s) return;
    NSString* t = [g_logView.text stringByAppendingString:s];
    if (t.length > 240000) t = [t substringFromIndex:t.length - 160000];  // cap
    g_logView.text = t;
    [g_logView scrollRangeToVisible:NSMakeRange(t.length, 0)];  // autoscroll
  });
}

static void StartScreenLogMirror(void) {
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
  const int rfd = fds[0];
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

// ── Continuous phys_footprint sampler -> peak RSS (iOS jetsam metric). ──
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
      usleep(200000);  // 200ms
    }
  });
}

// ── Decode a JPEG to a row-major float grayscale buffer (0..255) at maxEdge. ──
//    Returns malloc'd float[w*h]; caller frees. *outW/*outH set on success.
static float* DecodeGrayFloat(NSString* path, int maxEdge, int* outW, int* outH) {
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
  uint8_t* gray8 = (uint8_t*)calloc((size_t)w * h, 1);
  CGColorSpaceRef cs = CGColorSpaceCreateDeviceGray();
  CGContextRef ctx = CGBitmapContextCreate(gray8, w, h, 8, w, cs,
                                           (CGBitmapInfo)kCGImageAlphaNone);
  CGColorSpaceRelease(cs);
  if (!ctx) { free(gray8); CGImageRelease(cg); return NULL; }
  CGContextTranslateCTM(ctx, 0, h); CGContextScaleCTM(ctx, 1, -1);
  CGContextDrawImage(ctx, CGRectMake(0, 0, w, h), cg);
  CGContextRelease(ctx); CGImageRelease(cg);
  float* grayf = (float*)malloc(sizeof(float) * (size_t)w * h);
  for (size_t i = 0; i < (size_t)w * h; ++i) grayf[i] = (float)gray8[i];
  free(gray8);
  *outW = w; *outH = h; return grayf;
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

  UITextView* tv = [[UITextView alloc] initWithFrame:vc.view.bounds];
  tv.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
  tv.backgroundColor = [UIColor blackColor];
  tv.textColor = [UIColor greenColor];
  tv.font = [UIFont fontWithName:@"Menlo" size:9.0] ?: [UIFont systemFontOfSize:9.0];
  tv.editable = NO;
  tv.text = @"[GpuSiftBench on-screen console]\n";
  if (@available(iOS 11.0, *)) {
    tv.contentInsetAdjustmentBehavior = UIScrollViewContentInsetAdjustmentNever;
  }
  [vc.view addSubview:tv];
  g_logView = tv;
  StartScreenLogMirror();
  StartMemSampler();

  dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
    NSProcessInfo* pi = [NSProcessInfo processInfo];
    printf("GPUSIFT_BENCH_START thermal_before=%ld (0=nominal..3=critical)\n",
           (long)pi.thermalState); fflush(stdout);
    os_log(OS_LOG_DEFAULT, "GPUSIFT_BENCH_START");

    // shaders/wgsl/*.wgsl are bundled (the shaders dir is a folder reference in
    // Resources). shader_root = bundle path; the extractor appends
    // "/shaders/wgsl/<name>.wgsl".
    NSString* shaderRoot = [[NSBundle mainBundle] resourcePath];

    NSString* jpg = [[NSBundle mainBundle] pathForResource:@"sift_test" ofType:@"jpg"];
    if (!jpg) { printf("GPUSIFT_NO_IMAGE sift_test.jpg not in bundle\n"); fflush(stdout); }

    int w = 0, h = 0;
    float* gray = jpg ? DecodeGrayFloat(jpg, 4224, &w, &h) : NULL;
    if (!gray) {
      printf("GPUSIFT_DECODE_FAIL\n"); fflush(stdout);
      os_log(OS_LOG_DEFAULT, "GPUSIFT_DECODE_FAIL");
      return;
    }
    printf("GPUSIFT_IMG_DECODED %dx%d (float gray 0..255)\n", w, h); fflush(stdout);

    g_peak_mb = 0.0;  // reset so PEAK reflects init+10-frame run
    char out[512]; out[0] = 0;
    NSDate* t0 = [NSDate date];
    int rc = gpu_sift_run_all(shaderRoot.UTF8String, gray, w, h, out, sizeof(out));
    double wall = -[t0 timeIntervalSinceNow];
    free(gray);

    NSProcessInfo* pi2 = [NSProcessInfo processInfo];
    printf("GPUSIFT_BENCH_RESULT rc=%d wall=%.2fs peak_RSS_MB=%.0f "
           "thermal_after=%ld | %s\n",
           rc, wall, g_peak_mb, (long)pi2.thermalState, out); fflush(stdout);
    os_log(OS_LOG_DEFAULT, "GPUSIFT_BENCH_RESULT rc=%d peak_MB=%.0f %{public}s",
           rc, g_peak_mb, out);
    printf("GPUSIFT_BENCH_DONE (log saved to Documents/aether_console.log)\n");
    fflush(stdout);
    os_log(OS_LOG_DEFAULT, "GPUSIFT_BENCH_DONE");
  });
  return YES;
}
@end
