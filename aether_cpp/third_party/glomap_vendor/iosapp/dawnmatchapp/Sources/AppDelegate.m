#import <UIKit/UIKit.h>
#import <os/log.h>
#import <mach/mach.h>

extern int dawn_match_run_all(char* out, int out_cap);

static double PhysFootprintMB(void) {
  task_vm_info_data_t info;
  mach_msg_type_number_t count = TASK_VM_INFO_COUNT;
  if (task_info(mach_task_self(), TASK_VM_INFO, (task_info_t)&info, &count) ==
      KERN_SUCCESS)
    return info.phys_footprint / (1024.0 * 1024.0);
  return -1;
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
      printf("WAIT_COOL thermal=%ld t=%ds\n", (long)pi.thermalState, waited);
      fflush(stdout);
      [NSThread sleepForTimeInterval:10]; waited += 10;
    }
    printf("DAWN_BENCH_START thermal=%ld\n", (long)pi.thermalState); fflush(stdout);
    os_log(OS_LOG_DEFAULT, "DAWN_BENCH_START");
    char out[256]; out[0] = 0;
    NSDate* t0 = [NSDate date];
    int rc = dawn_match_run_all(out, sizeof(out));
    double wall = -[t0 timeIntervalSinceNow];
    printf("DAWN_BENCH_RESULT rc=%d wall=%.2fs peak=%.0fMB %s\n",
           rc, wall, PhysFootprintMB(), out); fflush(stdout);
    os_log(OS_LOG_DEFAULT, "DAWN_BENCH_RESULT rc=%d wall=%.2f %{public}s", rc, wall, out);
    NSLog(@"DAWN_BENCH_RESULT rc=%d wall=%.2f %s", rc, wall, out);
    printf("DAWN_BENCH_DONE\n"); fflush(stdout);
    os_log(OS_LOG_DEFAULT, "DAWN_BENCH_DONE");
  });
  return YES;
}
@end
