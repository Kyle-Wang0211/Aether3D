// SPDX-License-Identifier: LicenseRef-Aether3D-Proprietary
// Copyright (c) 2024-2026 Aether3D. All rights reserved.

import Foundation
import CAetherNativeBridge

struct NativeColorCorrectionStats: Sendable {
    var gainR: Float
    var gainG: Float
    var gainB: Float
    var exposureRatio: Float
}

final class NativeColorCorrector {
    private var state = aether_color_correction_state_t(
        has_reference: 0,
        reference_luminance: 0
    )

    /// Correct RGB image data using native gray-world + exposure correction.
    /// Returns corrected image data and correction stats, or nil on failure.
    func correctRGB(
        image: Data,
        width: Int,
        height: Int,
        rowBytes: Int
    ) -> (Data, NativeColorCorrectionStats)? {
        guard width > 0, height > 0, rowBytes > 0, !image.isEmpty else {
            return nil
        }

        var config = aether_color_correction_config_t(
            mode: 1,  // gray-world + exposure
            min_gain: 0.5,
            max_gain: 2.0,
            min_exposure_ratio: 0.5,
            max_exposure_ratio: 2.0
        )
        var stats = aether_color_correction_stats_t(
            gain_r: 1,
            gain_g: 1,
            gain_b: 1,
            exposure_ratio: 1
        )

        var output = Data(count: image.count)

        let rc = image.withUnsafeBytes { inPtr in
            output.withUnsafeMutableBytes { outPtr in
                aether_color_correct(
                    inPtr.baseAddress?.assumingMemoryBound(to: UInt8.self),
                    Int32(width),
                    Int32(height),
                    Int32(rowBytes),
                    &config,
                    &state,
                    outPtr.baseAddress?.assumingMemoryBound(to: UInt8.self),
                    &stats
                )
            }
        }

        guard rc == 0 else {
            return nil
        }

        return (
            output,
            NativeColorCorrectionStats(
                gainR: stats.gain_r,
                gainG: stats.gain_g,
                gainB: stats.gain_b,
                exposureRatio: stats.exposure_ratio
            )
        )
    }
}
