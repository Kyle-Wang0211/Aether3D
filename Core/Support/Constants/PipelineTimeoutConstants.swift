// SPDX-License-Identifier: LicenseRef-Aether3D-Proprietary
// Copyright (c) 2024-2026 Aether3D. All rights reserved.

import Foundation

/// Runtime poll and stall thresholds for the minimal whitebox remote-training loop.
public enum PipelineTimeoutConstants {
    public static let stallTimeoutSeconds: TimeInterval = 1800
    public static let stallMinProgressDelta: Double = 0.02
    public static let absoluteMaxTimeoutSeconds: TimeInterval = 7200

    public static let pollIntervalSeconds: TimeInterval = 1.0
    public static let pollIntervalQueuedSeconds: TimeInterval = 5.0

    public static let backgroundPollIntervalSeconds: TimeInterval = 30.0
    public static let backgroundGracePeriodSeconds: TimeInterval = 180.0

    public static let validStages: Set<String> = [
        "queued",
        "sfm",
        "sfm_extract",
        "sfm_match",
        "sfm_reconstruct",
        "train",
        "export",
        "packaging",
        "complete",
    ]

    public static let stageOrder: [String: Int] = [
        "queued": 0,
        "sfm": 1,
        "sfm_extract": 1,
        "sfm_match": 1,
        "sfm_reconstruct": 1,
        "train": 2,
        "export": 3,
        "packaging": 3,
        "complete": 4,
    ]
}
