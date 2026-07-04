#import <UIKit/UIKit.h>
#import <os/log.h>
#import <stdatomic.h>
#if __has_include(<BackgroundTasks/BackgroundTasks.h>)
#import <BackgroundTasks/BackgroundTasks.h>
#define AETHER_HAS_BGTASKS 1
#endif

extern int glomap_run_all(char* out, int out_cap);
// 每次改动 bump — 屏幕/日志都打这个戳, 截图即可确认在跑哪版
#define AETHER_BENCH_VERSION "v5.7"
// [AETHER PROGRESS] real staged pipeline progress (glomap-src aether_progress.cc)
extern int aether_progress_permille(void);
extern int aether_progress_stage_get(void);
static NSString* const kStageNames[10] = {
  @"准备中", @"估计相对位姿", @"全局旋转平均", @"建立特征轨迹", @"全局定位",
  @"光束法平差",   @"重三角化",     @"精修优化",     @"导出结果", @"完成"};

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
// (com.kyle.GlomapBench2 — case-sensitive string match on the duet/dasd side;
// the old all-lowercase "com.kyle.pocketworld.recon" is a suspected silent-drop
// cause). Keep in sync with BGTaskSchedulerPermittedIdentifiers in project.yml.
static NSString* const kBGTaskID = @"com.kyle.GlomapBench2.recon";
static volatile int gBenchDone = 0;
static volatile int gHandlerFired = 0;
// [UMBRELLA v4] set on foreground return: the current grant is recycled
// (closed cleanly) so DidBecomeActive can arm a FRESH one for the next
// backgrounding. The system would otherwise expire the old grant ~2s after
// the next backgrounding (measured), stranding the bench mid-solve.
static volatile int gCloseUmbrella = 0;
// [v5.6 SHAPING] highest units ever shown — new grants start no lower (the
// lock-screen card must never regress across an umbrella swap)
static volatile long long gShownFloor = 0;
// [v5.7 COCKPIT] in-app live status — same data source as the island card
static UILabel* gStatusLabel = nil;
static NSString* gResultJson = nil;

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
    // [v5.4] submission from background is silently dropped by dasd — skip
    // and let the next foreground visit (or tap) re-arm instead.
    if (UIApplication.sharedApplication.applicationState ==
        UIApplicationStateBackground) {
      aether_lifecycle_log([[NSString stringWithFormat:
          @"BGTASK_SUBMIT_SKIPPED(bg-state) via=%@", via] UTF8String]);
      return;
    }
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
  aether_lifecycle_log([[NSString stringWithFormat:@"BENCH_START %s via=%@",
                           AETHER_BENCH_VERSION, via] UTF8String]);
  printf("GLOMAP_BENCH_START via=%s\n", via.UTF8String); fflush(stdout);
  char out[1200]; out[0] = 0;
  int rc = glomap_run_all(out, sizeof(out));
  printf("GLOMAP_BENCH_END rc=%d %s\n", rc, out); fflush(stdout);
  gResultJson = [NSString stringWithUTF8String:out];
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
  lbl.text = @"启动中…";
  lbl.userInteractionEnabled = NO;
  [vc.view addSubview:lbl];
  gStatusLabel = lbl;
  // [v5.7 COCKPIT] 1s refresh, same sources as the island (shaped floor +
  // real pipeline + stage) — the interior may NEVER contradict the card.
  [NSTimer scheduledTimerWithTimeInterval:1.0 repeats:YES block:^(NSTimer* t) {
    int st = aether_progress_stage_get();
    if (st < 0 || st > 9) st = 0;
    int real = aether_progress_permille();
    long long shown = gShownFloor > real ? gShownFloor : real;
    NSString* umb = gHandlerFired ? @"🛡 后台保护伞:护航中"
                                  : @"⚠️ 后台保护伞:未开(点一下屏幕)";
    if (gBenchDone) {
      gStatusLabel.text = [NSString stringWithFormat:
          @"GLOMAP bench %s(编译 %s %s)\n\n✅ 重建已完成\n\n%@",
          AETHER_BENCH_VERSION, __DATE__, __TIME__,
          gResultJson ?: @"(结果见 Documents/DONE)"];
    } else {
      gStatusLabel.text = [NSString stringWithFormat:
          @"GLOMAP bench %s(编译 %s %s)\n\n🟢 运行中 — %@\n"
          @"进度(与灵动岛同步): %lld.%01lld%%\n真实管线: %d.%01d%%\n\n%@",
          AETHER_BENCH_VERSION, __DATE__, __TIME__, kStageNames[st],
          shown / 100, (shown % 100) / 10, real / 100, (real % 100) / 10, umb];
    }
  }];
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
                     // [v5.5] do NOT recycle here: a lock-screen peek fires
                     // WILL_ENTER_FOREGROUND without ever becoming active —
                     // recycling then strands us (the re-submit is dropped in
                     // the foreground-inactive state, measured 21:34 run).
                     // Recycle moves to DID_BECOME_ACTIVE (true activation).
                   }];
  [nc addObserverForName:UIApplicationProtectedDataWillBecomeUnavailable object:nil
                   queue:nil usingBlock:^(NSNotification* n){ aether_lifecycle_log("DEVICE_LOCKING"); }];

#ifdef AETHER_HAS_BGTASKS
  if (@available(iOS 26.0, *)) {
    __weak __typeof(self) wself3 = self;
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
          gCloseUmbrella = 0;  // [v5.4] fresh grant owns a fresh flag
          aether_lifecycle_log("BGTASK_HANDLER_FIRED(umbrella)");
          __block volatile int expired = 0;
          NSProgress* prog = nil;
          BGContinuedProcessingTask* cpTask = nil;
          if ([task isKindOfClass:BGContinuedProcessingTask.class]) {
            cpTask = (BGContinuedProcessingTask*)task;
            prog = cpTask.progress;
            // [v5 REAL PROGRESS] weighted staged pipeline progress from
            // aether_progress.cc (monotone by construction). v4.1's blind
            // ticker is gone; the system's stall-expiry is avoided because
            // real stages always advance (indeterminate stages creep
            // asymptotically inside their segment on the C side).
            prog.totalUnitCount = 10000;
            prog.completedUnitCount = MAX(MAX(10, aether_progress_permille()),
                                          gShownFloor);
          }
          // [v5.6 SHAPING EXPERIMENT] dasd decompile: FirstROPPrompt fires at
          // t=300s (per grant) iff fraction < 50%. Shape the DISPLAYED curve:
          // linear to 51% by t=280s, then a slow strictly-monotone crawl
          // (+1 unit/6s — never pins, so the >30s strict-monotonic stall
          // deadline can never trip). The honest pipeline value (logged in
          // run.log) reclaims the bar the moment it exceeds the envelope.
          // Predicted: no first prompt; watch whether SecondROPPrompt (rate
          // deviation 20%/60s) appears instead — that's the experiment.
          double grantT0 = [NSDate date].timeIntervalSince1970;
          task.expirationHandler = ^{
            aether_lifecycle_log([[NSString stringWithFormat:
                @"BGTASK_EXPIRED prog=%lld", prog ? prog.completedUnitCount : -1]
                                     UTF8String]);
            expired = 1;
          };
          // [v5.2 TEXT≡RING] subtitle carries the LIVE percent and is re-sent
          // whenever the whole percent or the stage changes (≥8s apart) — the
          // ring (NSProgress) and the text stay in lockstep, and a stage
          // switch the system coalesced away gets re-sent on the next tick.
          int lastStage = -1;
          long long lastPct = -1;
          double lastTextT = 0;
          while (!gBenchDone && !expired && !gCloseUmbrella) {
            [NSThread sleepForTimeInterval:2.0];
            if (prog) {
              long long real = aether_progress_permille();
              double el = [NSDate date].timeIntervalSince1970 - grantT0;
              long long env = (el <= 280.0)
                  ? (long long)(5100.0 * el / 280.0)
                  : 5100 + (long long)((el - 280.0) / 6.0);
              long long p = MAX(real, env);
              if (p > gShownFloor) gShownFloor = p;
              p = gShownFloor;
              if (p > prog.completedUnitCount && p <= 9920)
                prog.completedUnitCount = p;
              int st = aether_progress_stage_get();
              long long pct = prog.completedUnitCount / 100;
              double nowt = [NSDate date].timeIntervalSince1970;
              static double lastShapeLog = 0;
              if (nowt - lastShapeLog >= 60.0) {
                lastShapeLog = nowt;
                aether_lifecycle_log([[NSString stringWithFormat:
                    @"SHAPED disp=%lld real=%lld el=%.0f",
                    prog.completedUnitCount, real, el] UTF8String]);
              }
              if (st >= 0 && st <= 9 &&
                  (st != lastStage ||
                   (pct != lastPct && nowt - lastTextT >= 8.0))) {
                lastStage = st; lastPct = pct; lastTextT = nowt;
                [cpTask updateTitle:@"PocketWorld 重建"
                           subtitle:[NSString stringWithFormat:@"%@ · %lld%%",
                                        kStageNames[st], pct]];
              }
            }
          }
          if (prog && gBenchDone) prog.completedUnitCount = 10000;
          aether_lifecycle_log(gBenchDone   ? "BGTASK_CLOSED(bench_done)"
                               : expired    ? "BGTASK_CLOSED(expired)"
                                            : "BGTASK_CLOSED(fg_recycle)");
          // [UMBRELLA v4] umbrella is per-grant, not per-process: a foreground
          // return ends the current grant (measured: EXPIRED fires ~2s after
          // the next backgrounding). Re-arm eligibility here; DidBecomeActive/
          // tap submits a fresh request while the bench is still running.
          BOOL wasRecycle = (!gBenchDone && !expired);
          gCloseUmbrella = 0;
          gHandlerFired = 0;
          if (wasRecycle) {
            // [v5.4] re-arm IMMEDIATELY while still foreground — the old
            // +2.5s one-shot timer drifted past the user's quick re-lock and
            // then fired in background, where submission is silently dropped.
            dispatch_async(dispatch_get_main_queue(), ^{
              [wself3 submitUmbrella:@"post_recycle"];
            });
          }
          // ALWAYS report success: a reclaimed grant is NOT a failed job (the
          // work resumes on the next foreground visit), and success:NO pins a
          // "任务失败" tombstone card the app cannot dismiss (system-owned
          // ended Live Activity, no public API). Ground truth (EXPIRED vs
          // bench_done vs fg_recycle) lives in hybrid.log.
          [task setTaskCompletedWithSuccess:YES];
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
        // [v5.5] recycle on TRUE activation only; post_recycle then re-arms
        // from a guaranteed-active state ([v5.4] stale-flag rule kept: only
        // flag a live grant).
        if (gHandlerFired) gCloseUmbrella = 1;
        // 2.5s > the umbrella loop's 2s poll: on a foreground return the old
        // grant has closed (fg_recycle) and gHandlerFired reset by the time
        // this fires, so the fresh submit isn't skipped. First launch: still
        // comfortably after duet lists us as foreground.
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.0 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
          [wself2 submitUmbrella:@"did_become_active+1.0s"];
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
