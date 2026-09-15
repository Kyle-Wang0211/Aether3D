// pwdense_c_sim.c — simulator-only backend of the pwdense_* ABI (the product never runs the dense stage on a
// simulator; this keeps both simulator architectures linkable, like pwofficial_sim_backend.c).
#include <string.h>
#include "pwdense_c.h"

int32_t pwdense_abi_version(void) { return PWDENSE_ABI_VERSION; }
int32_t pwdense_available(void) { return 0; }
int32_t pwdense_options_default(pwdense_options_t* o) {
    if (!o) return 2;
    memset(o, 0, sizeof *o);
    o->width = 768; o->height = 576; o->nsrc = 9; o->webgpu = 1; o->noise_seed = 0x5EEDDEE5ULL;
    return 0;
}
const char* pwdense_default_model_path(void) { return ""; }
int32_t pwdense_run(const pwdense_frame_t* frames, int32_t n_frames, const float* points_xyz, int32_t n_points,
                    const pwdense_options_t* opts, pwdense_progress_fn progress, void* user, pwdense_stats_t* out_stats) {
    (void)frames; (void)n_frames; (void)points_xyz; (void)n_points; (void)opts; (void)progress; (void)user;
    if (out_stats) { memset(out_stats, 0, sizeof *out_stats); strncpy(out_stats->error, "dense stage unavailable on the simulator", sizeof out_stats->error - 1); }
    return -1;
}
