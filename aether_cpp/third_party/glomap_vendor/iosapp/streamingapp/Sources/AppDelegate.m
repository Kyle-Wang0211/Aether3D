// StreamingBench AppDelegate — Step-2 full-pipeline streaming harness driver.
//
// GlomapBench/GpuSiftBench device-harness pattern:
//   * full-screen on-screen UITextView console mirroring stdout+stderr
//   * tee the COMPLETE console to Documents/aether_console.log
//   * continuous phys_footprint sampler -> peak RSS (jetsam metric)
//   * thermalState (NSProcessInfo) logged before + after the run
//
// The streaming run is heavy (~10+ min over 414 frames at 2s pacing + COLMAP
// register passes), so we DON'T auto-start on launch — there's a big START
// button. The user taps START; the run executes on a background queue and
// mirrors everything to the on-screen console + the log file. Run the app TWICE
// to see the Dawn pipeline cache go cold→warm (init_ms should drop on run 2).
//
// Inputs expected in the app's Documents container (pushed via devicectl):
//   Documents/frames/<cell_*_slot_*.jpg>        (the 414 capture JPEGs)
//   Documents/streaming_manifest.json           (per-frame pose+intrinsics)

#import <UIKit/UIKit.h>
#import <os/log.h>
#import <unistd.h>
#import <stdio.h>
#import <mach/mach.h>

// streaming_run.mm
extern int streaming_run_all(const char* shader_root, const char* frames_dir,
                             const char* manifest_path, int max_frames,
                             int jitter, int register_every_n, int max_edge,
                             int clear_cache, char* out, int out_cap);

static UITextView* g_logView = nil;
static dispatch_source_t g_logSrc = nil;
static FILE* g_logFile = NULL;

static void AppendScreenLog(NSString* s) {
  dispatch_async(dispatch_get_main_queue(), ^{
    if (!g_logView || !s) return;
    NSString* t = [g_logView.text stringByAppendingString:s];
    if (t.length > 400000) t = [t substringFromIndex:t.length - 280000];
    g_logView.text = t;
    [g_logView scrollRangeToVisible:NSMakeRange(t.length, 0)];
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
      usleep(200000);
    }
  });
}

@interface AppDelegate : UIResponder <UIApplicationDelegate>
@property(strong, nonatomic) UIWindow* window;
@property(nonatomic) BOOL running;
@end

@implementation AppDelegate

- (void)runStreaming:(int)clearCache {
  if (self.running) return;
  self.running = YES;
  dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
    NSProcessInfo* pi = [NSProcessInfo processInfo];
    printf("STREAM_BENCH_START thermal_before=%ld (0=nominal..3=critical) "
           "physmem_GB=%.1f clear_cache=%d\n",
           (long)pi.thermalState,
           (double)pi.physicalMemory / (1024.0*1024.0*1024.0), clearCache);
    fflush(stdout);

    NSString* shaderRoot = [[NSBundle mainBundle] resourcePath];
    NSString* docs = NSSearchPathForDirectoriesInDomains(
        NSDocumentDirectory, NSUserDomainMask, YES).firstObject;
    NSString* framesDir = [docs stringByAppendingPathComponent:@"frames"];
    NSString* manifest =
        [docs stringByAppendingPathComponent:@"streaming_manifest.json"];

    NSFileManager* fm = [NSFileManager defaultManager];
    if (![fm fileExistsAtPath:manifest]) {
      printf("STREAM_NO_MANIFEST %s missing — push it with devicectl copy to\n",
             manifest.UTF8String);
      fflush(stdout);
      self.running = NO;
      return;
    }
    NSArray* jpgs = [fm contentsOfDirectoryAtPath:framesDir error:nil];
    printf("STREAM_INPUTS frames_dir=%s (%lu files) manifest=%s\n",
           framesDir.UTF8String, (unsigned long)(jpgs ? jpgs.count : 0),
           manifest.UTF8String);
    fflush(stdout);

    // Config: full 414 frames, jitter pacing on, PER-FRAME interleaved register,
    // downsample 4K->~2112 long edge (production 4K->2K). max_frames=0 = all.
    // To smoke-test fast, change max_frames to e.g. 40 here.
    int max_frames = 0;        // 0 = all 414
    int jitter = 1;            // 2s ± variance + occasional drain pauses
    // [gpu-sift-s1 FIX-2] Registration is PER FRAME. The interleaved
    // add_and_register path registers every fed frame (the cloud grows per-frame).
    // This value does NOT gate registration (see streaming_run.mm: it is consumed
    // only as `global_ba_marker`, a cosmetic deferred-global-BA log cadence flag).
    // Renamed to make clear it is NOT a register cadence.
    int global_ba_log_marker_every = 25;  // cosmetic BA-log cadence ONLY (not register)
    int register_every_n = global_ba_log_marker_every;
    int max_edge = 2112;       // 4224 -> 2112 (half; ~2K production downsample)

    g_peak_mb = 0.0;
    char out[1024]; out[0] = 0;
    NSDate* t0 = [NSDate date];
    int rc = streaming_run_all(shaderRoot.UTF8String, framesDir.UTF8String,
                               manifest.UTF8String, max_frames, jitter,
                               register_every_n, max_edge, clearCache, out,
                               sizeof(out));
    double wall = -[t0 timeIntervalSinceNow];

    NSProcessInfo* pi2 = [NSProcessInfo processInfo];
    printf("STREAM_BENCH_RESULT rc=%d wall=%.1fs peak_RSS_MB=%.0f "
           "thermal_after=%ld\n  %s\n",
           rc, wall, g_peak_mb, (long)pi2.thermalState, out);
    fflush(stdout);
    printf("STREAM_BENCH_DONE (log saved to Documents/aether_console.log)\n");
    fflush(stdout);
    self.running = NO;
  });
}

- (void)onStart:(UIButton*)b { [self runStreaming:0]; }
- (void)onColdStart:(UIButton*)b { [self runStreaming:1]; }

- (BOOL)application:(UIApplication*)app didFinishLaunchingWithOptions:(NSDictionary*)opt {
  self.window = [[UIWindow alloc] initWithFrame:[[UIScreen mainScreen] bounds]];
  UIViewController* vc = [UIViewController new];
  vc.view.backgroundColor = [UIColor blackColor];
  self.window.rootViewController = vc;
  [self.window makeKeyAndVisible];

  CGRect bounds = vc.view.bounds;
  CGFloat btnH = 64;
  UITextView* tv = [[UITextView alloc]
      initWithFrame:CGRectMake(0, 0, bounds.size.width,
                               bounds.size.height - btnH)];
  tv.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
  tv.backgroundColor = [UIColor blackColor];
  tv.textColor = [UIColor greenColor];
  tv.font = [UIFont fontWithName:@"Menlo" size:9.0] ?: [UIFont systemFontOfSize:9.0];
  tv.editable = NO;
  tv.text = @"[StreamingBench] Tap START to run the full ①②③ streaming harness "
            @"(414 frames @2s pacing, ~10+ min).\n"
            @"First run: init compiles GPU shaders (~30s, cache=cold). Run again "
            @"for cache=warm.\nUse COLD START to force-clear the pipeline cache.\n\n";
  if (@available(iOS 11.0, *))
    tv.contentInsetAdjustmentBehavior = UIScrollViewContentInsetAdjustmentNever;
  [vc.view addSubview:tv];
  g_logView = tv;

  UIButton* start = [UIButton buttonWithType:UIButtonTypeSystem];
  start.frame = CGRectMake(0, bounds.size.height - btnH, bounds.size.width * 0.6, btnH);
  start.autoresizingMask = UIViewAutoresizingFlexibleTopMargin | UIViewAutoresizingFlexibleWidth;
  [start setTitle:@"▶ START (use cache)" forState:UIControlStateNormal];
  start.titleLabel.font = [UIFont boldSystemFontOfSize:18];
  start.backgroundColor = [UIColor colorWithRed:0 green:0.4 blue:0 alpha:1];
  [start setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
  [start addTarget:self action:@selector(onStart:) forControlEvents:UIControlEventTouchUpInside];
  [vc.view addSubview:start];

  UIButton* cold = [UIButton buttonWithType:UIButtonTypeSystem];
  cold.frame = CGRectMake(bounds.size.width * 0.6, bounds.size.height - btnH,
                          bounds.size.width * 0.4, btnH);
  cold.autoresizingMask = UIViewAutoresizingFlexibleTopMargin | UIViewAutoresizingFlexibleLeftMargin;
  [cold setTitle:@"COLD START\n(clear cache)" forState:UIControlStateNormal];
  cold.titleLabel.numberOfLines = 2;
  cold.titleLabel.textAlignment = NSTextAlignmentCenter;
  cold.titleLabel.font = [UIFont systemFontOfSize:13];
  cold.backgroundColor = [UIColor colorWithRed:0.4 green:0.2 blue:0 alpha:1];
  [cold setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
  [cold addTarget:self action:@selector(onColdStart:) forControlEvents:UIControlEventTouchUpInside];
  [vc.view addSubview:cold];

  StartScreenLogMirror();
  StartMemSampler();
  printf("STREAM_BENCH_READY tap START to run\n"); fflush(stdout);
  return YES;
}
@end
