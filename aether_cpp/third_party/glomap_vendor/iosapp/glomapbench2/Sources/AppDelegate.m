#import <UIKit/UIKit.h>
#import <os/log.h>
#import <stdatomic.h>
#if __has_include(<BackgroundTasks/BackgroundTasks.h>)
#import <BackgroundTasks/BackgroundTasks.h>
#define AETHER_HAS_BGTASKS 1
#endif

extern int glomap_run_all(char* out, int out_cap);

// ── [AETHER HYBRID MODE] foreground full-speed + background continued run ──
// iOS suspends (and, as measured on run4: cpu_resource-KILLS, "90s CPU over
// 180s") pure-compute apps in background. iOS 26's BGContinuedProcessingTask is
// the sanctioned path: user-initiated work keeps running after backgrounding,
// with a system progress UI. Strategy:
//   1. register + submit a continued-processing task at launch;
//   2. run the bench INSIDE the task handler (backgrounding transitions
//      seamlessly); fallback to a plain QoS thread if the API is unavailable
//      or submission fails (then background = suspend, as before);
//   3. log every lifecycle transition with timestamps into Documents/run.log —
//      offline we correlate per-stage timings with FG/BG state to measure the
//      real background speed factor, whatever the user does with the phone.

// [UMBRELLA v3] identifier MUST be prefixed with the exact bundle id
// (com.kyle.PocketWorld — case-sensitive string match on the duet/dasd side;
// the old all-lowercase "com.kyle.pocketworld.recon" is a suspected silent-drop
// cause). Keep in sync with BGTaskSchedulerPermittedIdentifiers in project.yml.
static NSString* const kBGTaskID = @"com.kyle.PocketWorld.recon";
static volatile int gBenchDone = 0;
static volatile int gHandlerFired = 0;
// [UMBRELLA v4] set on foreground return: the current grant is recycled
// (closed cleanly) so DidBecomeActive can arm a FRESH one for the next
// backgrounding. The system would otherwise expire the old grant ~2s after
// the next backgrounding (measured), stranding the bench mid-solve.
static volatile int gCloseUmbrella = 0;

static void aether_lifecycle_log(const char* tag) {
  NSString* docs = NSSearchPathForDirectoriesInDomains(
      NSDocumentDirectory, NSUserDomainMask, YES).firstObject;
  // hybrid.log: independent of run.log rotation — survives bench startup.
  NSString* p = [docs stringByAppendingPathComponent:@"hybrid.log"];
  FILE* f = fopen(p.UTF8String, "a");
  if (f) {
    fprintf(f, "AETHER_LIFECYCLE %s t=%.3f\n", tag,
            [NSDate date].timeIntervalSince1970);
    fflush(f); fclose(f);
  }
  os_log(OS_LOG_DEFAULT, "AETHER_LIFECYCLE %{public}s", tag);
}

@interface AppDelegate : UIResponder <UIApplicationDelegate>
@property(strong, nonatomic) UIWindow* window;
@end

@implementation AppDelegate {
  _Atomic int _benchStarted;
  double _lastSubmitT;
}

// [UMBRELLA v3] Submit the continued-processing request from a REAL foreground/
// user context. Root cause of v2's dead handler (Apple forums 807370/801126 +
// DTS): submitting inside didFinishLaunching happens before duet lists the app
// as "foreground", so dasd SILENTLY drops the request — submit returns YES,
// handler never fires, no error (acknowledged framework bug FB21052216).
// v3 therefore submits (a) on first DidBecomeActive and (b) on any screen tap
// (a literal person's action, per the API contract). Debounced; skipped once
// the handler is live. Strategy .fail first to force a diagnosable error
// (code 4 = ImmediateRunIneligible), then .queue as best-effort fallback.
- (void)submitUmbrella:(NSString*)via {
#ifdef AETHER_HAS_BGTASKS
  if (@available(iOS 26.0, *)) {
    if (gHandlerFired || gBenchDone) return;
    double now = [NSDate date].timeIntervalSince1970;
    if (now - _lastSubmitT < 2.0) return;
    _lastSubmitT = now;
    BGContinuedProcessingTaskRequest* req =
        [[BGContinuedProcessingTaskRequest alloc]
            initWithIdentifier:kBGTaskID
                         title:@"PocketWorld 重建"
                      subtitle:@"GLOMAP 全局重建运行中"];
    req.strategy = BGContinuedProcessingTaskRequestSubmissionStrategyFail;
    NSError* err = nil;
    if ([[BGTaskScheduler sharedScheduler] submitTaskRequest:req error:&err]) {
      aether_lifecycle_log([[NSString stringWithFormat:
          @"BGTASK_SUBMITTED(fail-strategy) via=%@", via] UTF8String]);
      return;
    }
    aether_lifecycle_log([[NSString stringWithFormat:
        @"BGTASK_SUBMIT_FAILED(fail-strategy) via=%@ code=%ld %@",
        via, (long)err.code, err.localizedDescription] UTF8String]);
    BGContinuedProcessingTaskRequest* req2 =
        [[BGContinuedProcessingTaskRequest alloc]
            initWithIdentifier:kBGTaskID
                         title:@"PocketWorld 重建"
                      subtitle:@"GLOMAP 全局重建运行中"];
    req2.strategy = BGContinuedProcessingTaskRequestSubmissionStrategyQueue;
    NSError* err2 = nil;
    if ([[BGTaskScheduler sharedScheduler] submitTaskRequest:req2 error:&err2]) {
      aether_lifecycle_log([[NSString stringWithFormat:
          @"BGTASK_SUBMITTED(queue-fallback) via=%@", via] UTF8String]);
    } else {
      aether_lifecycle_log([[NSString stringWithFormat:
          @"BGTASK_SUBMIT_FAILED(queue-fallback) via=%@ code=%ld %@",
          via, (long)err2.code, err2.localizedDescription] UTF8String]);
    }
  }
#endif
}

- (void)onScreenTap:(UITapGestureRecognizer*)gr {
  aether_lifecycle_log("SCREEN_TAP");
  [self submitUmbrella:@"screen_tap"];
}

- (void)runBenchOnce:(NSString*)via {
  int expected = 0;
  if (!atomic_compare_exchange_strong(&_benchStarted, &expected, 1)) {
    return;  // already running/ran — exactly-once guard
  }
  aether_lifecycle_log([[NSString stringWithFormat:@"BENCH_START via=%@", via]
                           UTF8String]);
  printf("GLOMAP_BENCH_START via=%s\n", via.UTF8String); fflush(stdout);
  char out[1200]; out[0] = 0;
  int rc = glomap_run_all(out, sizeof(out));
  printf("GLOMAP_BENCH_END rc=%d %s\n", rc, out); fflush(stdout);
  os_log(OS_LOG_DEFAULT, "GLOMAP_BENCH_END rc=%d %{public}s", rc, out);
  gBenchDone = 1;
  aether_lifecycle_log("BENCH_END");
}

- (BOOL)application:(UIApplication*)app didFinishLaunchingWithOptions:(NSDictionary*)opt {
  self.window = [[UIWindow alloc] initWithFrame:[[UIScreen mainScreen] bounds]];
  UIViewController* vc = [UIViewController new];
  vc.view.backgroundColor = [UIColor blackColor];
  UILabel* lbl = [[UILabel alloc] initWithFrame:vc.view.bounds];
  lbl.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
  lbl.textColor = [UIColor whiteColor];
  lbl.font = [UIFont systemFontOfSize:16];
  lbl.numberOfLines = 0;
  lbl.textAlignment = NSTextAlignmentCenter;
  lbl.text = @"GLOMAP bench 运行中\n\n请点击屏幕一次\n(启用后台续跑保护伞)";
  lbl.userInteractionEnabled = NO;
  [vc.view addSubview:lbl];
  self.window.rootViewController = vc;
  [self.window makeKeyAndVisible];
  // Foreground full-speed leg: never auto-lock while frontmost (run4's killer).
  app.idleTimerDisabled = YES;

  // Lifecycle markers → run.log (FG/BG speed attribution offline).
  NSNotificationCenter* nc = NSNotificationCenter.defaultCenter;
  [nc addObserverForName:UIApplicationDidEnterBackgroundNotification object:nil
                   queue:nil usingBlock:^(NSNotification* n){ aether_lifecycle_log("DID_ENTER_BACKGROUND"); }];
  [nc addObserverForName:UIApplicationWillEnterForegroundNotification object:nil
                   queue:nil usingBlock:^(NSNotification* n){
                     aether_lifecycle_log("WILL_ENTER_FOREGROUND");
                     gCloseUmbrella = 1;  // recycle the grant; fresh submit follows
                   }];
  [nc addObserverForName:UIApplicationProtectedDataWillBecomeUnavailable object:nil
                   queue:nil usingBlock:^(NSNotification* n){ aether_lifecycle_log("DEVICE_LOCKING"); }];

#ifdef AETHER_HAS_BGTASKS
  if (@available(iOS 26.0, *)) {
    BOOL reg = [[BGTaskScheduler sharedScheduler]
        registerForTaskWithIdentifier:kBGTaskID
                           usingQueue:dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0)
                        launchHandler:^(__kindof BGTask* task) {
          // [UMBRELLA v2] The bench ALWAYS runs on its own thread (started at
          // launch, full speed). This handler — whenever the system fires it —
          // only holds the continued-processing task OPEN (updating progress)
          // until the bench ends: the live task is what grants background
          // execution. Decouples work from unpredictable handler timing (v1
          // raced a 5s fallback and lost: work landed on a plain thread and
          // froze on backgrounding).
          gHandlerFired = 1;
          aether_lifecycle_log("BGTASK_HANDLER_FIRED(umbrella)");
          __block volatile int expired = 0;
          NSProgress* prog = nil;
          if ([task isKindOfClass:BGContinuedProcessingTask.class]) {
            prog = ((BGContinuedProcessingTask*)task).progress;
            // [v4.1] MEASURED: grant expired 74s after the old 100-unit ticker
            // pinned at its 92% cap (bg throttling stretched the run past the
            // ticker's 9-min horizon) — a stalled progress bar IS the expire
            // trigger. Fine-grained creep: 1000 units, +1/4s, cap 95% → no
            // stall before ~63min, far beyond any bench run.
            prog.totalUnitCount = 1000;
            prog.completedUnitCount = 10;
          }
          task.expirationHandler = ^{
            aether_lifecycle_log([[NSString stringWithFormat:
                @"BGTASK_EXPIRED prog=%lld", prog ? prog.completedUnitCount : -1]
                                     UTF8String]);
            expired = 1;
          };
          int ticks = 0;
          while (!gBenchDone && !expired && !gCloseUmbrella) {
            [NSThread sleepForTimeInterval:2.0];
            ticks++;
            if (prog && ticks % 2 == 0 && prog.completedUnitCount < 950)
              prog.completedUnitCount += 1;  // 4s cadence, cap 95%
          }
          if (prog && gBenchDone) prog.completedUnitCount = 1000;
          aether_lifecycle_log(gBenchDone   ? "BGTASK_CLOSED(bench_done)"
                               : expired    ? "BGTASK_CLOSED(expired)"
                                            : "BGTASK_CLOSED(fg_recycle)");
          // [UMBRELLA v4] umbrella is per-grant, not per-process: a foreground
          // return ends the current grant (measured: EXPIRED fires ~2s after
          // the next backgrounding). Re-arm eligibility here; DidBecomeActive/
          // tap submits a fresh request while the bench is still running.
          gCloseUmbrella = 0;
          gHandlerFired = 0;
          // fg_recycle is a clean handoff, not a failure — only a true
          // expiration reports NO (that's what paints "任务失败" in the UI).
          [task setTaskCompletedWithSuccess:(expired ? NO : YES)];
        }];
    aether_lifecycle_log(reg ? "BGTASK_REGISTERED" : "BGTASK_REGISTER_FAILED");
    if (reg) {
      // [UMBRELLA v3] NO submit here — didFinishLaunching predates duet's
      // foreground listing and the request would be silently dropped. Submit
      // happens on DidBecomeActive (+0.7s, foreground listing settled) and on
      // screen taps (true user action).
      __weak __typeof(self) wself2 = self;
      [nc addObserverForName:UIApplicationDidBecomeActiveNotification object:nil
                       queue:NSOperationQueue.mainQueue
                  usingBlock:^(NSNotification* n) {
        aether_lifecycle_log("DID_BECOME_ACTIVE");
        // 2.5s > the umbrella loop's 2s poll: on a foreground return the old
        // grant has closed (fg_recycle) and gHandlerFired reset by the time
        // this fires, so the fresh submit isn't skipped. First launch: still
        // comfortably after duet lists us as foreground.
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2.5 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
          [wself2 submitUmbrella:@"did_become_active+2.5s"];
        });
      }];
      UITapGestureRecognizer* tap = [[UITapGestureRecognizer alloc]
          initWithTarget:self action:@selector(onScreenTap:)];
      [vc.view addGestureRecognizer:tap];
    }
  } else {
    aether_lifecycle_log("BGTASK_API_UNAVAILABLE");
  }
#else
  aether_lifecycle_log("BGTASK_SDK_MISSING");
#endif

  // [UMBRELLA v2] bench starts immediately on its own thread — full speed in
  // foreground; the submitted continued-processing task (handler above) is the
  // background-execution umbrella.
  dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
    [self runBenchOnce:@"main_thread_umbrella_v2"];
  });
  return YES;
}
@end
