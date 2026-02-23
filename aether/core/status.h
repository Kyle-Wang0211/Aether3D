// SPDX-License-Identifier: LicenseRef-Aether3D-Proprietary
// Copyright (c) 2024-2026 Aether3D. All rights reserved.

#ifndef AETHER_CORE_STATUS_H
#define AETHER_CORE_STATUS_H

namespace aether {
namespace core {

enum class Status : int {
    kOk = 0,
    kInvalidArgument = -1,
    kOutOfRange = -2,
    kResourceExhausted = -3,
};

inline bool is_ok(Status s) { return static_cast<int>(s) == 0; }

}  // namespace core
}  // namespace aether

#endif  // AETHER_CORE_STATUS_H
