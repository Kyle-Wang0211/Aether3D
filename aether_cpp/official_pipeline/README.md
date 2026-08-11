# Pocketworld official-route native source copy

This directory is the physically independent source side of the second
Pocketworld capture pipeline. Its initial implementation is copied from the
shipping `pwsfm_*` adapter, DSP-SIFT extractor, Metal matcher, and streaming
COLMAP runtime. The exact frozen source is `ea77244a` plus the required
build-time dirty `aether_ghost_mask.h` (`d32694cb...`); this combination
reproduces the shipping adapter object byte-for-byte. The later b930
resume/tombstone changes are deliberately excluded. Shared files outside this
directory are third-party COLMAP, PoseLib, Ceres, glog, Dawn, and platform
dependencies only.

The only intentional initial behavior deltas are ownership names: the public
ABI is `pwofficial_*`, every runtime key is `OFFICIAL_AETHER_*`, and native
sidecars are official-prefixed. Defaults and algorithm branches are unchanged.

Build the independent core with:

```sh
./aether_cpp/official_pipeline/build_ios_core.sh
```

The resulting `libpwofficial_core.a` is packaged by Pocketworld's
`vendor/official_sfm/scripts/build_xcframework.sh` inside a dynamic framework.
The framework hides all internal COLMAP/Aether/C++ symbols and exports only the
frozen `pwofficial_*` ABI. The end-to-end rebuild and parity gates are run by
Pocketworld's `vendor/official_sfm/scripts/rebuild_native.sh`.
