// SPDX-License-Identifier: LicenseRef-Aether3D-Proprietary
// Copyright (c) 2024-2026 Aether3D. All rights reserved.

import Foundation

public enum PipelineBackend: Sendable {
    case localEmbedded
    case danishGoldenSSH
    case brokeredBackgroundUpload

    public static func productDefault() -> PipelineBackend {
        // Startup only needs to know whether broker settings exist; it should
        // not eagerly spin up the background upload engine while deciding.
        if BackgroundUploadBrokerConfiguration.current() != nil {
            return .brokeredBackgroundUpload
        }
        return .danishGoldenSSH
    }
}
