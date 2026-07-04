// On-device GLOMAP global-mapper benchmark harness (iOS, A16).
//
// Runs glomap_bench() (GLOMAP GlobalMapper: rotation averaging + global
// positioning + global BA + retriangulation + pruning) over a prebuilt 396-frame
// COLMAP db, and measures the CROWN JEWEL number: PEAK phys_footprint RSS vs the
// ~3072MB jetsam limit — the post-capture memory question that decides whether
// "capture-time = ARKit + keyframe storage only, all SfM = one post-capture
// GLOMAP pass" is viable.
//
// Post-capture scenario: ARKit is STOPPED (capture ended), so GLOMAP gets the
// whole memory budget. We sample phys_footprint on a background thread every
// 100ms for the duration of the solve to capture the true peak (host was 1.99GB).

#import <Foundation/Foundation.h>
#import <mach/mach.h>
#import <os/proc.h>  // os_proc_available_memory (iOS 13+): headroom before jetsam

#include <atomic>
#include <cstdio>
#include <cstring>
#include <thread>

#include <os/log.h>

extern "C" int glomap_bench(const char* db_path, char* out_json, int out_cap);
extern "C" int glomap_bench_write(const char* db_path, const char* out_dir,
                                  char* out_json, int out_cap);

namespace {
// [UNPLUG-SAFE TEMPLATE] All output lands in the app container so the run
// survives USB unplug / detached launch (no --console). run4 died to SIGKILL
// purely because --console ties the app lifetime to the USB tunnel. Files:
//   Documents/run.log      — harness milestones (GLOMAP_* lines)
//   Documents/run_full.log — full stdout+stderr (glog stages, progress bars)
//   Documents/DONE         — written last, contains the final RESULT line;
//                            host polls `devicectl copy from` for it.
FILE* g_runlog = nullptr;
void logline(const char* s) {
  printf("%s\n", s); fflush(stdout);
  if (g_runlog) { fprintf(g_runlog, "%s\n", s); fflush(g_runlog); }
  os_log(OS_LOG_DEFAULT, "%{public}s", s);
}

double PhysFootprintMB() {
  task_vm_info_data_t info;
  mach_msg_type_number_t count = TASK_VM_INFO_COUNT;
  if (task_info(mach_task_self(), TASK_VM_INFO, (task_info_t)&info, &count) ==
      KERN_SUCCESS)
    return info.phys_footprint / (1024.0 * 1024.0);
  return -1;
}
int read_thermal() { return (int)[NSProcessInfo processInfo].thermalState; }
}  // namespace

// Entry point invoked by AppDelegate on a background QoS thread.
extern "C" int glomap_run_all(char* out, int out_cap) {
  if (out && out_cap > 0) out[0] = 0;

  NSString* docs = NSSearchPathForDirectoriesInDomains(
      NSDocumentDirectory, NSUserDomainMask, YES).firstObject;

  // [UNPLUG-SAFE] container-file logging: clear stale markers, open run.log,
  // and redirect stdout+stderr into run_full.log so GLOMAP's glog stage lines
  // and progress bars are preserved without any USB/console session.
  NSFileManager* fm = [NSFileManager defaultManager];
  [fm removeItemAtPath:[docs stringByAppendingPathComponent:@"DONE"] error:nil];
  // [AETHER FIX] Do NOT delete run.log here — AppDelegate writes the hybrid-mode
  // diagnostic markers (BGTASK_REGISTERED/SUBMITTED, BENCH_START via=...) BEFORE
  // this runs; deleting ate exactly the lines needed to debug the background
  // path. Rotate instead: rename to run.prev.log (one-run history).
  [fm removeItemAtPath:[docs stringByAppendingPathComponent:@"run.prev.log"] error:nil];
  [fm moveItemAtPath:[docs stringByAppendingPathComponent:@"run.log"]
              toPath:[docs stringByAppendingPathComponent:@"run.prev.log"] error:nil];
  [fm removeItemAtPath:[docs stringByAppendingPathComponent:@"run_full.log"] error:nil];
  g_runlog = fopen([docs stringByAppendingPathComponent:@"run.log"].UTF8String, "a");
  freopen([docs stringByAppendingPathComponent:@"run_full.log"].UTF8String, "a", stdout);
  freopen([docs stringByAppendingPathComponent:@"run_full.log"].UTF8String, "a", stderr);
  setvbuf(stdout, nullptr, _IOLBF, 0);  // line-buffered so tail-by-pull sees progress
  setvbuf(stderr, nullptr, _IOLBF, 0);

  // [AETHER FIX] Prefer the dense414 fixture by its REAL name; fall back to
  // glomap_396.db (legacy: dense414 was once pushed UNDER that name, which
  // silently ran the wrong fixture when a real 396 db landed there).
  // [AETHER] Documents/DBCONFIG (one line = db filename) overrides fixture
  // choice — lets the host switch fixtures by pushing a tiny file instead of
  // overwriting big dbs in place (a 256MB copy onto an existing 884MB file
  // leaves a corrupt tail: "0.12s bench" bug).
  NSString* cfg = [NSString stringWithContentsOfFile:
      [docs stringByAppendingPathComponent:@"DBCONFIG"]
      encoding:NSUTF8StringEncoding error:nil];
  cfg = [cfg stringByTrimmingCharactersInSet:
      [NSCharacterSet whitespaceAndNewlineCharacterSet]];
  NSString* dbp = nil; bool have = false;
  if (cfg.length > 0) {
    dbp = [docs stringByAppendingPathComponent:cfg];
    have = [[NSFileManager defaultManager] fileExistsAtPath:dbp];
  }
  if (!have) {
    dbp = [docs stringByAppendingPathComponent:@"dense414.db"];
    have = [[NSFileManager defaultManager] fileExistsAtPath:dbp];
  }
  if (!have) {
    dbp = [docs stringByAppendingPathComponent:@"glomap_396.db"];
    have = [[NSFileManager defaultManager] fileExistsAtPath:dbp];
  }
  { char b[256]; snprintf(b, sizeof(b), "GLOMAP_DB present=%d path=%s",
                          (int)have, dbp.UTF8String); logline(b); }
  if (!have) { logline("GLOMAP_FAIL no db (push glomap_396.db to Documents)"); return 1; }

  // [ENTITLEMENT DIAGNOSTIC] os_proc_available_memory() = bytes we can still
  // allocate before jetsam. At baseline (nothing allocated yet) available + our
  // current footprint ≈ the TOTAL memory cap. This tells us DIRECTLY whether the
  // increased-memory-limit entitlement took effect: ~3GB cap => entitlement NOT
  // active; ~4.1GB cap => active. (os_proc_available_memory returns 0 if unavailable.)
  { double avail_mb = (double)os_proc_available_memory() / (1024.0 * 1024.0);
    double foot_mb = PhysFootprintMB();
    char b[192]; snprintf(b, sizeof(b),
      "GLOMAP_MEMLIMIT avail=%.0fMB footprint=%.0fMB est_cap=%.0fMB "
      "(=%s entitlement)", avail_mb, foot_mb, avail_mb + foot_mb,
      (avail_mb + foot_mb > 3500.0 ? "~4.1G ACTIVE" : "~3G NOT-active"));
    logline(b); }

  { char b[128]; snprintf(b, sizeof(b),
      "GLOMAP_START baseline_rss=%.0fMB thermal=%d (POST-CAPTURE: ARKit stopped, "
      "full memory budget)", PhysFootprintMB(), read_thermal()); logline(b); }

  // ── peak-RSS sampler thread: poll phys_footprint every 100ms during solve ──
  std::atomic<bool> stop{false};
  std::atomic<double> peak{0.0};
  std::thread sampler([&]() {
    double p = 0; int tick = 0;
    while (!stop.load()) {
      double rss = PhysFootprintMB();
      if (rss > p) p = rss;
      peak.store(p);
      if (++tick % 50 == 0) {  // ~every 5s
        char b[128]; snprintf(b, sizeof(b),
            "GLOMAP_RSS now=%.0fMB peak=%.0fMB thermal=%d", rss, p, read_thermal());
        logline(b);
      }
      [NSThread sleepForTimeInterval:0.1];
    }
  });

  // ── run GLOMAP + write NATIVE colmap model to Documents/glomap_out ──
  NSString* outDir = [docs stringByAppendingPathComponent:@"glomap_out"];
  [[NSFileManager defaultManager] removeItemAtPath:outDir error:nil];  // clean
  [[NSFileManager defaultManager] createDirectoryAtPath:outDir
      withIntermediateDirectories:YES attributes:nil error:nil];
  char gj[1024]; gj[0] = 0;
  NSDate* t0 = [NSDate date];
  int rc = glomap_bench_write(dbp.UTF8String, outDir.UTF8String, gj, sizeof(gj));
  double wall = -[t0 timeIntervalSinceNow];
  { char b[256]; snprintf(b, sizeof(b), "GLOMAP_MODEL_OUT %s/0 (export via devicectl)",
                          outDir.UTF8String); logline(b); }

  stop.store(true);
  if (sampler.joinable()) sampler.join();
  double peak_mb = peak.load();

  char r[1200];
  snprintf(r, sizeof(r),
      "GLOMAP_RESULT rc=%d wall=%.1fs PEAK_RSS=%.0fMB (cap 4096MB → %s) "
      "thermal=%d json=%s",
      rc, wall, peak_mb, (peak_mb < 4096.0 ? "SAFE" : "OVER"), read_thermal(), gj);
  logline(r);
  logline("GLOMAP_DONE");
  // [UNPLUG-SAFE] terminal marker: host polls `devicectl copy from Documents/DONE`;
  // its presence == run complete, its content == the final RESULT line.
  { FILE* d = fopen([docs stringByAppendingPathComponent:@"DONE"].UTF8String, "w");
    if (d) { fprintf(d, "%s\n", r); fclose(d); } }
  if (g_runlog) { fclose(g_runlog); g_runlog = nullptr; }
  if (out && out_cap > 0) { strncpy(out, r, out_cap - 1); out[out_cap - 1] = 0; }
  return rc;
}
