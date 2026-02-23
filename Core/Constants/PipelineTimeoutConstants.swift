// SPDX-License-Identifier: LicenseRef-Aether3D-Proprietary
// Copyright (c) 2024-2026 Aether3D. All rights reserved.

// ============================================================================
// CONSTITUTIONAL CONTRACT - DO NOT EDIT WITHOUT RFC
// Contract Version: PR-PROGRESS-1.0
// Module: Pipeline Timeout Constants (SSOT)
// Cross-Platform: macOS + Linux (pure Foundation)
// ============================================================================

import Foundation

/// Pipeline timeout constants — replaces the old 180s hard timeout
/// with stall-based detection that allows long-running jobs to complete
/// as long as progress is being made.
///
/// ## Design Rationale
/// - A 15-minute video (900s) can take 15-45 minutes to process
/// - Hard timeouts cause false failures on legitimate long jobs
/// - Stall detection catches genuinely stuck jobs without penalizing slow ones
/// - Industry reference: Replicate.com uses stall-based timeouts for ML training
///
/// ## Safety Layers (Defense in Depth)
/// 1. Per-poll stall detection: no progress change for `stallTimeoutSeconds`
/// 2. Absolute maximum: `absoluteMaxTimeoutSeconds` prevents infinite hangs
/// 3. Server-side per-phase timeouts: SfM (30min), Training (60min), Export (5min)
/// 4. iOS background task watchdog: system-enforced limits
public enum PipelineTimeoutConstants {

    // =========================================================================
    // MARK: - Stall Detection
    // =========================================================================

    /// Stall detection timeout in seconds.
    /// If the server-reported progress percentage does not change for this
    /// duration, the job is considered stalled and will be failed.
    ///
    /// - 300 seconds (5 minutes) matches `RetryConstants.stallDetectionSeconds`
    /// - Research: Google Cloud ML Engine uses 5-minute stall detection
    /// - This is the PRIMARY safety mechanism replacing the 180s hard timeout
    public static let stallTimeoutSeconds: TimeInterval = 300

    /// Minimum progress delta (percentage points) to consider "making progress".
    /// Progress changes smaller than this are treated as stall.
    ///
    /// - 0.1% prevents floating-point noise from resetting the stall timer
    /// - Nerfstudio reports progress at ~0.003% per step (step 1/30000)
    ///   so any single step produces 0.003% which is below this threshold
    ///   but multiple steps within the poll interval will exceed it
    public static let stallMinProgressDelta: Double = 0.1

    // =========================================================================
    // MARK: - Absolute Safety Cap
    // =========================================================================

    /// Absolute maximum timeout in seconds.
    /// Even if progress is being reported, the job will fail after this duration.
    /// This is a safety net against infinite loops or runaway processes.
    ///
    /// - 7200 seconds (2 hours) covers worst-case: 15min video + slow GPU
    /// - Calculation: upload (15min) + SfM (30min) + training (45min) + export (5min) + buffer = ~2h
    /// - This is the SECONDARY safety mechanism
    public static let absoluteMaxTimeoutSeconds: TimeInterval = 7200

    // =========================================================================
    // MARK: - Polling Configuration
    // =========================================================================

    /// Poll interval during active processing (seconds).
    /// How often the client checks server for progress updates.
    ///
    /// - 3 seconds matches `ContractConstants.PROGRESS_REPORT_INTERVAL_SECONDS`
    /// - Research: Nielsen Norman Group — 1-10s intervals for progress feedback
    /// - Too fast (< 1s): unnecessary network load on mobile
    /// - Too slow (> 10s): stale progress display, poor UX
    public static let pollIntervalSeconds: TimeInterval = 3.0

    /// Poll interval during queued state (seconds).
    /// Longer interval when job is waiting — no active processing to monitor.
    ///
    /// - 5 seconds matches `APIContractConstants.POLLING_INTERVAL_QUEUED`
    public static let pollIntervalQueuedSeconds: TimeInterval = 5.0

    // =========================================================================
    // MARK: - iOS Background Handling
    // =========================================================================

    /// Background poll interval (seconds).
    /// When the app enters background, reduce polling frequency to conserve
    /// battery and comply with iOS background execution limits.
    ///
    /// - 30 seconds: matches heartbeat interval
    /// - iOS allows ~30s of background execution after entering background
    /// - Beyond that, use BGProcessingTask for extended background work
    public static let backgroundPollIntervalSeconds: TimeInterval = 30.0

    /// Background grace period (seconds).
    /// After entering background, continue polling for this duration before
    /// switching to push-notification-based updates (future).
    ///
    /// - 180 seconds (3 minutes): iOS typically allows ~180s with beginBackgroundTask
    /// - After this, the system may suspend the app
    public static let backgroundGracePeriodSeconds: TimeInterval = 180.0

    // =========================================================================
    // MARK: - Progress Stages (Closed Set)
    // =========================================================================

    /// Valid progress stage identifiers (must match server-side stages).
    /// Used for validation — reject unknown stages from the server.
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

    /// Stage order for monotonicity checking.
    /// Lower number = earlier stage. Used to detect stage regression.
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

    // =========================================================================
    // MARK: - Specifications (SSOT)
    // =========================================================================

    public static let stallTimeoutSpec = ThresholdSpec(
        ssotId: "PipelineTimeoutConstants.stallTimeoutSeconds",
        name: "Pipeline Stall Timeout",
        unit: .seconds,
        category: .safety,
        min: 60.0,
        max: 900.0,
        defaultValue: stallTimeoutSeconds,
        onExceed: .warn,
        onUnderflow: .reject,
        documentation: "5 minutes without progress change triggers stall failure"
    )

    public static let absoluteMaxTimeoutSpec = ThresholdSpec(
        ssotId: "PipelineTimeoutConstants.absoluteMaxTimeoutSeconds",
        name: "Pipeline Absolute Max Timeout",
        unit: .seconds,
        category: .safety,
        min: 600.0,
        max: 14400.0,
        defaultValue: absoluteMaxTimeoutSeconds,
        onExceed: .warn,
        onUnderflow: .reject,
        documentation: "2 hours absolute cap, covers worst-case 15min video on slow GPU"
    )

    public static let pollIntervalSpec = ThresholdSpec(
        ssotId: "PipelineTimeoutConstants.pollIntervalSeconds",
        name: "Pipeline Poll Interval",
        unit: .seconds,
        category: .performance,
        min: 1.0,
        max: 10.0,
        defaultValue: pollIntervalSeconds,
        onExceed: .warn,
        onUnderflow: .reject,
        documentation: "处理中轮询间隔，平衡网络负载与实时性"
    )

    public static let backgroundPollIntervalSpec = ThresholdSpec(
        ssotId: "PipelineTimeoutConstants.backgroundPollIntervalSeconds",
        name: "Pipeline Background Poll Interval",
        unit: .seconds,
        category: .performance,
        min: 10.0,
        max: 120.0,
        defaultValue: backgroundPollIntervalSeconds,
        onExceed: .warn,
        onUnderflow: .reject,
        documentation: "后台轮询间隔，节省电量"
    )

    public static let allSpecs: [AnyConstantSpec] = [
        .threshold(stallTimeoutSpec),
        .threshold(absoluteMaxTimeoutSpec),
        .threshold(pollIntervalSpec),
        .threshold(backgroundPollIntervalSpec),
    ]
}
