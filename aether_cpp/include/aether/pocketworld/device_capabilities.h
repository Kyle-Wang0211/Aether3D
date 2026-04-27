// SPDX-License-Identifier: LicenseRef-Aether3D-Proprietary
// Copyright (c) 2024-2026 Aether3D. All rights reserved.

#ifndef AETHER_CPP_POCKETWORLD_DEVICE_CAPABILITIES_H
#define AETHER_CPP_POCKETWORLD_DEVICE_CAPABILITIES_H

#include <cstdint>

namespace aether::pocketworld {

enum class DeviceTier : std::uint8_t {
    kFlagship,
    kHigh,
    kMid,
    kAndroidHigh,
    kAndroidLow,
    kWeb,
    kUnknown,
};

struct DeviceCapabilities {
    DeviceTier tier{DeviceTier::kUnknown};
    std::uint32_t native_display_w{0};
    std::uint32_t native_display_h{0};
    std::uint32_t base_render_w{0};
    std::uint32_t base_render_h{0};
    bool wcg_supported{false};
    bool edr_supported{false};
    bool metalfx_supported{false};
    int target_fps{60};
};

}  // namespace aether::pocketworld

#endif  // AETHER_CPP_POCKETWORLD_DEVICE_CAPABILITIES_H
