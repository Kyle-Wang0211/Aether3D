// SPDX-License-Identifier: LicenseRef-Aether3D-Proprietary
// Copyright (c) 2024-2026 Aether3D. All rights reserved.

#ifndef AETHER_POCKETWORLD_DAWN_DEVICE_SINGLETON_H
#define AETHER_POCKETWORLD_DAWN_DEVICE_SINGLETON_H

// ─── Process-level singleton DawnGPUDevice ─────────────────────────────
//
// Shared by all PocketWorld renderers (splat_iosurface_renderer,
// scene_iosurface_renderer, future plugin renderers). Refcounted by
// active renderer count — when the last renderer is destroyed, the
// device is released so memory-pressure recovery (background → foreground
// after iOS suspended) gets a fresh device on next acquire.
//
// Thread-safety: acquire / release are serialized by the singleton's
// internal mutex.

#include "aether/render/gpu_device.h"

namespace aether {
namespace pocketworld {

/// Returns the singleton GPUDevice (creating it + registering all baked
/// WGSL on first call). Returns nullptr if Dawn device creation fails.
/// Increments the refcount; caller must call dawn_singleton_release()
/// exactly once per acquire.
::aether::render::GPUDevice* dawn_singleton_acquire();

/// Decrements refcount; releases the device when count reaches 0.
void dawn_singleton_release();

}  // namespace pocketworld
}  // namespace aether

#endif  // AETHER_POCKETWORLD_DAWN_DEVICE_SINGLETON_H
