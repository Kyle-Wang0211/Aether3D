// SPDX-License-Identifier: LicenseRef-Aether3D-Proprietary
// Copyright (c) 2024-2026 Aether3D. All rights reserved.

#ifndef AETHER_CPP_POCKETWORLD_BACKGROUND_DOWNLOAD_H
#define AETHER_CPP_POCKETWORLD_BACKGROUND_DOWNLOAD_H

#include <cstdint>
#include <string>

namespace aether::pocketworld {

enum class DownloadStatus : std::uint8_t {
    kPending,
    kInProgress,
    kCompleted,
    kFailed,
};

struct BackgroundDownloadHandle {
    std::uint64_t id{0};
};

BackgroundDownloadHandle start_background_download(
    const std::string& url,
    const std::string& destination_path);

DownloadStatus query_download_status(BackgroundDownloadHandle handle);

void cancel_download(BackgroundDownloadHandle handle);

}  // namespace aether::pocketworld

#endif  // AETHER_CPP_POCKETWORLD_BACKGROUND_DOWNLOAD_H
