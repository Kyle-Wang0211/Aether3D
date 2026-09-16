// host_gpu_extract_warmup_stub.cc — HOST-ONLY no-op definition of the extract
// warm-up C ABI, so the host bench targets that link pwofficial_core on the CPU
// route link again. Never compiled into anything that ships.
//
// [HOST-LINK 2026-09-16] official_aether_sfm_c.cc (declaration at ~175-185)
// declares aether_dsp_sift_extract_gpu_warmup as __attribute__((weak_import))
// on Darwin. On Mach-O that is a weak *import*: dyld may bind it to NULL at run
// time, but ld64 still demands a definition at static-link time. The only real
// definitions are the Dawn TUs — bench/dsp_sift_gpu_c.cc (the iOS carrier's
// TU, aether_cpp/CMakeLists.txt ~501) and official_pipeline/src/
// official_dsp_sift_gpu_c.cc (in no target) — and no host bench that merely
// links the CPU route compiles either of them. Result at HEAD (28ca8b48+):
//   Undefined symbols for architecture arm64:
//     "_aether_dsp_sift_extract_gpu_warmup", referenced from:
//       _aether_sfm_create in libpwofficial_core.a(official_aether_sfm_c.cc.o)
// (2026-09-10 the same break hit archived_refeed_gpuextract_exe.)
//
// Same rationale as the per-bench aether_dsp_sift_extract_gpu / _v2 /
// aether_sed_last_stages stubs in sfm_replay_bench.cc — except this one lives
// in ONE shared TU instead of being copied into every bench: the copy-paste
// stub sets have already drifted once (sfm_finalize_resume_bench.cc,
// 2026-08-13 note). Add this TU to a target's source list in
// glomap_vendor/CMakeLists.txt (AETHER_HOST_WARMUP_STUB_SRC).
//
// Contract mirrored from dsp_sift_gpu_c.cc:417 — zero every out-param, return
// -1 = "Dawn extractor unavailable". KickExtractWarmupOnce treats -1 as the
// documented unavailable case (n_new_pipelines=-1 in the extract_warmup_v1
// line), and its mode gate (OFFICIAL_AETHER_EXTRACT_WARMUP unset ⇒ mode 0)
// returns before the symbol is even touched, so no bench output can change.
//
// Do NOT add this TU to any target that also compiles bench/dsp_sift_gpu_c.cc
// (archived_refeed_gpuextract_exe, preclamp_instr_v1_production_integration_exe,
// the *_parity / gpu_extract_* exes, the iOS carrier): that would be a
// duplicate strong definition.

extern "C" int aether_dsp_sift_extract_gpu_warmup(double* out_init_ms,
                                                  double* out_compile_ms,
                                                  double* out_msl_ms,
                                                  unsigned* out_msl_n,
                                                  double* out_pso_ms,
                                                  unsigned* out_pso_n) {
  if (out_init_ms) *out_init_ms = 0.0;
  if (out_compile_ms) *out_compile_ms = 0.0;
  if (out_msl_ms) *out_msl_ms = 0.0;
  if (out_msl_n) *out_msl_n = 0u;
  if (out_pso_ms) *out_pso_ms = 0.0;
  if (out_pso_n) *out_pso_n = 0u;
  return -1;  // Dawn extractor unavailable on host → warm-up is a no-op
}
