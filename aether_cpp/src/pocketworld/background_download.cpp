// SPDX-License-Identifier: LicenseRef-Aether3D-Proprietary
// Copyright (c) 2024-2026 Aether3D. All rights reserved.

#include "aether/pocketworld/background_download.h"

#include <cstdio>

namespace aether::pocketworld {

BackgroundDownloadHandle start_background_download(
    const std::string& url,
    const std::string& destination_path) {
    std::fprintf(stderr,
                 "[background_download] STUB - Phase 6.7 will implement BGURLSession "
                 "(url=%s, destination=%s)\n",
                 url.c_str(),
                 destination_path.c_str());
    return BackgroundDownloadHandle{0};
}

DownloadStatus query_download_status(BackgroundDownloadHandle handle) {
    std::fprintf(stderr,
                 "[background_download] STUB - query handle=%llu\n",
                 static_cast<unsigned long long>(handle.id));
    return DownloadStatus::kFailed;
}

void cancel_download(BackgroundDownloadHandle handle) {
    std::fprintf(stderr,
                 "[background_download] STUB - cancel handle=%llu\n",
                 static_cast<unsigned long long>(handle.id));
}

}  // namespace aether::pocketworld
