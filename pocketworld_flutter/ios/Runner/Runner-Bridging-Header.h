#import "GeneratedPluginRegistrant.h"

// Plan G W1 + W2 D1 — aether3d_ffi C ABI for cross-platform depth tile +
// mask math (DA3-LARGE-1.1 tile blend + EdgeTAM mask post-process).
// Implementations live in aether_cpp/src/pipeline/{tile_layout, tile_blend,
// mask_post, aether_depth_tile_c}.cpp, vendored as libaether3d_ffi.a via
// scripts/build_ios_xcframework.sh + pod aether3d_ffi.
#import <aether3d_ffi/aether_depth_tile_c.h>
