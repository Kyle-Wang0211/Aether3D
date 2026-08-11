// pwofficial_telemetry.mm — on-device capture telemetry (memory + thermal), FFI-safe.
//
// Callable via dlsym from ANY isolate (pure C ABI, no platform channel), so
// the SfM worker isolate can sample it right after each add_frame — i.e. at
// the per-frame memory PEAK — and fold the numbers into its frame_done log.
//
// What the public iOS API actually exposes (and what it does NOT):
//   • phys_footprint — the jetsam-relevant resident cost of the app, the same
//     number the OS uses to decide when to kill you. Read via
//     task_info(TASK_VM_INFO). This is the memory figure that matters.
//   • thermalState — ProcessInfo's 4-level bucket
//     (0 nominal / 1 fair / 2 serious / 3 critical). Apple does NOT expose a
//     numeric die/CPU temperature through any public API; this bucket is the
//     only thermal signal available to a shipping app.

#import <Foundation/Foundation.h>
#import <mach/mach.h>

extern "C" {

// Fills the out-params (any may be NULL). Returns 0 on success, non-zero if
// the mach query failed (thermal is still filled).
__attribute__((visibility("default"), used))
int pwofficial_telemetry(double* phys_footprint_mb,
                         double* footprint_peak_mb,
                         int* thermal_state) {
  int rc = 0;

  if (phys_footprint_mb || footprint_peak_mb) {
    task_vm_info_data_t info;
    mach_msg_type_number_t count = TASK_VM_INFO_COUNT;
    const kern_return_t kr = task_info(mach_task_self(), TASK_VM_INFO,
                                       reinterpret_cast<task_info_t>(&info),
                                       &count);
    if (kr == KERN_SUCCESS) {
      const double footprint =
          static_cast<double>(info.phys_footprint) / (1024.0 * 1024.0);
      if (phys_footprint_mb) *phys_footprint_mb = footprint;
      // The public TASK_VM_INFO layout has no historical high-water field, so
      // the caller tracks the true session peak as a running max of this
      // instantaneous footprint (see the SfM worker). Mirror current here.
      if (footprint_peak_mb) *footprint_peak_mb = footprint;
    } else {
      rc = 1;
      if (phys_footprint_mb) *phys_footprint_mb = -1.0;
      if (footprint_peak_mb) *footprint_peak_mb = -1.0;
    }
  }

  if (thermal_state) {
    *thermal_state =
        static_cast<int>([[NSProcessInfo processInfo] thermalState]);
  }
  return rc;
}

}  // extern "C"
