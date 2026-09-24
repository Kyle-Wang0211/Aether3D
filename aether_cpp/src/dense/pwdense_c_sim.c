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
/* [v2 2026-09-15] progressive delivery: same stub answer as pwdense_run. */
int32_t pwdense_run2(const pwdense_frame_t* frames, int32_t n_frames, const float* points_xyz, int32_t n_points,
                     const pwdense_options_t* opts, pwdense_progress_fn progress, pwdense_chunk_fn chunk, void* user,
                     pwdense_stats_t* out_stats) {
    (void)chunk;
    return pwdense_run(frames, n_frames, points_xyz, n_points, opts, progress, user, out_stats);
}
/* [v3 2026-09-16] NV12-capable frames: same stub answer (the simulator never runs the dense stage). */
int32_t pwdense_run3(const pwdense_frame_v3_t* frames, int32_t n_frames, const float* points_xyz, int32_t n_points,
                     const pwdense_options_t* opts, pwdense_progress_fn progress, pwdense_chunk_fn chunk, void* user,
                     pwdense_stats_t* out_stats) {
    (void)frames; (void)n_frames; (void)chunk;
    return pwdense_run(NULL, 0, points_xyz, n_points, opts, progress, user, out_stats);
}
