// SPDX-License-Identifier: LicenseRef-Aether3D-Proprietary
// Copyright (c) 2024-2026 Aether3D. All rights reserved.

//
// TSDFConstants.swift
// Aether3D
//
// TSDF pipeline constants — SSOT pattern following ScanGuidanceConstants

import Foundation

public enum TSDFConstants {

    // ════════════════════════════════════════════════════════════════
    // MARK: - Section 1: Adaptive Voxel Resolution (5 constants)
    // ════════════════════════════════════════════════════════════════

    public static let voxelSizeNear: Float = 0.005      // 0.5cm
    public static let voxelSizeMid: Float = 0.01         // 1.0cm
    public static let voxelSizeFar: Float = 0.02          // 2.0cm
    public static let depthNearThreshold: Float = 1.0     // meters
    public static let depthFarThreshold: Float = 3.0      // meters

    // ════════════════════════════════════════════════════════════════
    // MARK: - Section 2: Truncation Distance (2 constants)
    // ════════════════════════════════════════════════════════════════

    public static let truncationMultiplier: Float = 3.0
    public static let truncationMinimum: Float = 0.01     // 10mm

    // ════════════════════════════════════════════════════════════════
    // MARK: - Section 3: Fusion Weights (7 constants)
    // ════════════════════════════════════════════════════════════════

    public static let weightMax: UInt8 = 64
    public static let confidenceWeightLow: Float = 0.1
    public static let confidenceWeightMid: Float = 0.5
    public static let confidenceWeightHigh: Float = 1.0
    public static let distanceDecayAlpha: Float = 0.1
    public static let viewingAngleWeightFloor: Float = 0.1
    public static let carvingDecayRate: UInt8 = 2

    // ════════════════════════════════════════════════════════════════
    // MARK: - Section 4: Depth Filtering (4 constants)
    // ════════════════════════════════════════════════════════════════

    public static let depthMin: Float = 0.1
    public static let depthMax: Float = 5.0
    public static let minValidPixelRatio: Float = 0.3
    public static let skipLowConfidencePixels: Bool = true

    // ════════════════════════════════════════════════════════════════
    // MARK: - Section 5: Performance Budget (5 constants)
    // ════════════════════════════════════════════════════════════════

    public static let maxVoxelsPerFrame: Int = 500_000
    public static let maxTrianglesPerCycle: Int = 50_000
    public static let integrationTimeoutMs: Double = 10.0
    public static let metalThreadgroupSize: Int = 8
    public static let metalInflightBuffers: Int = MetalConstants.inflightBufferCount

    // ════════════════════════════════════════════════════════════════
    // MARK: - Section 6: Memory Management (7 constants)
    // ════════════════════════════════════════════════════════════════

    public static let maxTotalVoxelBlocks: Int = 100_000
    public static let hashTableInitialSize: Int = 65_536
    public static let hashTableMaxLoadFactor: Float = 0.7
    public static let hashMaxProbeLength: Int = 128
    public static let dirtyThresholdMultiplier: Float = 0.5
    public static let staleBlockEvictionAge: TimeInterval = 30.0
    public static let staleBlockForceEvictionAge: TimeInterval = 60.0

    // ════════════════════════════════════════════════════════════════
    // MARK: - Section 7: Block Geometry (1 constant)
    // ════════════════════════════════════════════════════════════════

    public static let blockSize: Int = 8

    // ════════════════════════════════════════════════════════════════
    // MARK: - Section 8: Camera Pose Safety (5 constants)
    // ════════════════════════════════════════════════════════════════

    public static let maxPoseDeltaPerFrame: Float = 0.1   // 10cm
    public static let maxAngularVelocity: Float = 2.0
    public static let poseRejectWarningCount: Int = 30     // 0.5s at 60fps
    public static let poseRejectFailCount: Int = 180       // 3.0s at 60fps
    public static let loopClosureDriftThreshold: Float = 0.02  // 2cm

    // ════════════════════════════════════════════════════════════════
    // MARK: - Section 9: Keyframe Selection (4 constants)
    // ════════════════════════════════════════════════════════════════

    public static let keyframeInterval: Int = 6
    public static let keyframeAngularTriggerDeg: Float = 15.0
    public static let keyframeTranslationTrigger: Float = 0.3
    public static let maxKeyframesPerSession: Int = 30

    // ════════════════════════════════════════════════════════════════
    // MARK: - Section 10: GPU Safety (4 constants)
    // ════════════════════════════════════════════════════════════════

    public static let semaphoreWaitTimeoutMs: Double = 100.0
    public static let gpuMemoryProactiveEvictBytes: Int = 500_000_000
    public static let gpuMemoryAggressiveEvictBytes: Int = 800_000_000
    public static let worldOriginRecenterDistance: Float = 100.0

    // ════════════════════════════════════════════════════════════════
    // MARK: - Section 11: AIMD Thermal Management (5 constants)
    // ════════════════════════════════════════════════════════════════

    public static let thermalDegradeHysteresisS: Double = 10.0
    public static let thermalRecoverHysteresisS: Double = 5.0
    public static let thermalRecoverGoodFrames: Int = 30
    public static let thermalGoodFrameRatio: Float = 0.8
    public static let thermalMaxIntegrationSkip: Int = 12

    // ════════════════════════════════════════════════════════════════
    // MARK: - Section 12: Mesh Extraction Quality (3 constants)
    // ════════════════════════════════════════════════════════════════

    public static let minTriangleArea: Float = 1e-8
    public static let maxTriangleAspectRatio: Float = 100.0
    public static let integrationRecordCapacity: Int = 300

    // ════════════════════════════════════════════════════════════════
    // MARK: - Section 13: UX Stability (11 constants)
    // ════════════════════════════════════════════════════════════════

    public static let sdfDeadZoneBase: Float = 0.001
    public static let sdfDeadZoneWeightScale: Float = 0.004
    public static let vertexQuantizationStep: Float = 0.0005
    public static let meshExtractionTargetHz: Float = 10.0
    public static let meshExtractionBudgetMs: Double = 5.0
    public static let mcInterpolationMin: Float = 0.1
    public static let mcInterpolationMax: Float = 0.9
    public static let poseJitterGateTranslation: Float = 0.001
    public static let poseJitterGateRotation: Float = 0.002
    public static let minObservationsBeforeMesh: UInt32 = 3
    public static let meshFadeInFrames: Int = 7

    // ════════════════════════════════════════════════════════════════
    // MARK: - Section 14: Congestion Control (9 constants)
    // ════════════════════════════════════════════════════════════════

    public static let meshBudgetTargetMs: Double = 4.0
    public static let meshBudgetGoodMs: Double = 3.0
    public static let meshBudgetOverrunMs: Double = 5.0
    public static let minBlocksPerExtraction: Int = 50
    public static let maxBlocksPerExtraction: Int = 250
    public static let blockRampPerCycle: Int = 15
    public static let consecutiveGoodCyclesBeforeRamp: Int = 3
    public static let forgivenessWindowCycles: Int = 5
    public static let slowStartRatio: Float = 0.25

    // ════════════════════════════════════════════════════════════════
    // MARK: - Section 15: Motion Tiers (6 constants)
    // ════════════════════════════════════════════════════════════════

    public static let normalAveragingBoundaryDistance: Float = 0.001
    public static let motionDeferTranslationSpeed: Float = 0.5
    public static let motionDeferAngularSpeed: Float = 1.0
    public static let idleTranslationSpeed: Float = 0.01      // m/s
    public static let idleAngularSpeed: Float = 0.05           // rad/s (~3°/s)
    public static let anticipatoryPreallocationDistance: Float = 0.5

    // ════════════════════════════════════════════════════════════════
    // MARK: - SSOT Registration
    // ════════════════════════════════════════════════════════════════
    /// All numeric constants registered as AnyConstantSpec
    /// Follows ScanGuidanceConstants.allSpecs pattern exactly
    /// Bool constants excluded (no BoolConstantSpec case in AnyConstantSpec)
    ///
    /// IMPORTANT: Register EVERY Float/Double/Int constant — no exceptions.
    /// ScanGuidanceConstants registers 65 specs. TSDFConstants registers 77 specs (Sections 1-15).
    /// Use `.threshold()` for Float/Double, `.systemConstant()` for Int, `.fixedConstant()` for physics constants.
    public static let allSpecs: [AnyConstantSpec] = [
        // Section 1: Adaptive Voxel Resolution (5 constants)
        .threshold(ThresholdSpec(
            ssotId: "TSDFConstants.voxelSizeNear",
            name: "Near Voxel Size",
            unit: .meters,
            category: .quality,
            min: 0.003, max: 0.008,
            defaultValue: Double(voxelSizeNear),
            onExceed: .warn, onUnderflow: .reject,
            documentation: "Near-range voxel size in meters (depth < 1.0m)"
        )),
        .threshold(ThresholdSpec(
            ssotId: "TSDFConstants.voxelSizeMid",
            name: "Mid Voxel Size",
            unit: .meters,
            category: .quality,
            min: 0.008, max: 0.015,
            defaultValue: Double(voxelSizeMid),
            onExceed: .warn, onUnderflow: .reject,
            documentation: "Mid-range voxel size in meters (depth 1.0–3.0m)"
        )),
        .threshold(ThresholdSpec(
            ssotId: "TSDFConstants.voxelSizeFar",
            name: "Far Voxel Size",
            unit: .meters,
            category: .quality,
            min: 0.015, max: 0.04,
            defaultValue: Double(voxelSizeFar),
            onExceed: .warn, onUnderflow: .reject,
            documentation: "Far-range voxel size in meters (depth > 3.0m)"
        )),
        .threshold(ThresholdSpec(
            ssotId: "TSDFConstants.depthNearThreshold",
            name: "Near/Mid Depth Threshold",
            unit: .meters,
            category: .quality,
            min: 0.5, max: 2.0,
            defaultValue: Double(depthNearThreshold),
            onExceed: .warn, onUnderflow: .warn,
            documentation: "Depth threshold for near→mid voxel size transition"
        )),
        .threshold(ThresholdSpec(
            ssotId: "TSDFConstants.depthFarThreshold",
            name: "Mid/Far Depth Threshold",
            unit: .meters,
            category: .quality,
            min: 2.0, max: 5.0,
            defaultValue: Double(depthFarThreshold),
            onExceed: .warn, onUnderflow: .warn,
            documentation: "Depth threshold for mid→far voxel size transition"
        )),
        
        // Section 2: Truncation Distance (2 constants)
        .threshold(ThresholdSpec(
            ssotId: "TSDFConstants.truncationMultiplier",
            name: "Truncation Multiplier",
            unit: .dimensionless,
            category: .quality,
            min: 2.0, max: 5.0,
            defaultValue: Double(truncationMultiplier),
            onExceed: .warn, onUnderflow: .reject,
            documentation: "Truncation band = multiplier × voxel_size"
        )),
        .threshold(ThresholdSpec(
            ssotId: "TSDFConstants.truncationMinimum",
            name: "Truncation Minimum",
            unit: .meters,
            category: .safety,
            min: 0.005, max: 0.02,
            defaultValue: Double(truncationMinimum),
            onExceed: .warn, onUnderflow: .reject,
            documentation: "Absolute minimum truncation distance (safety floor)"
        )),
        
        // Section 3: Fusion Weights (7 constants)
        .systemConstant(SystemConstantSpec(
            ssotId: "TSDFConstants.weightMax",
            name: "Maximum Voxel Weight",
            unit: .count,
            value: Int(weightMax),
            documentation: "Maximum accumulated weight per voxel (UInt8, clamped)"
        )),
        .threshold(ThresholdSpec(
            ssotId: "TSDFConstants.confidenceWeightLow",
            name: "Confidence Weight Low",
            unit: .dimensionless,
            category: .quality,
            min: 0.0, max: 0.3,
            defaultValue: Double(confidenceWeightLow),
            onExceed: .warn, onUnderflow: .warn,
            documentation: "Weight multiplier for ARKit confidence level 0 (low)"
        )),
        .threshold(ThresholdSpec(
            ssotId: "TSDFConstants.confidenceWeightMid",
            name: "Confidence Weight Mid",
            unit: .dimensionless,
            category: .quality,
            min: 0.3, max: 0.8,
            defaultValue: Double(confidenceWeightMid),
            onExceed: .warn, onUnderflow: .warn,
            documentation: "Weight multiplier for ARKit confidence level 1 (medium)"
        )),
        .threshold(ThresholdSpec(
            ssotId: "TSDFConstants.confidenceWeightHigh",
            name: "Confidence Weight High",
            unit: .dimensionless,
            category: .quality,
            min: 0.8, max: 1.0,
            defaultValue: Double(confidenceWeightHigh),
            onExceed: .warn, onUnderflow: .clamp,
            documentation: "Weight multiplier for ARKit confidence level 2 (high)"
        )),
        .threshold(ThresholdSpec(
            ssotId: "TSDFConstants.distanceDecayAlpha",
            name: "Distance Decay Alpha",
            unit: .dimensionless,
            category: .quality,
            min: 0.01, max: 0.5,
            defaultValue: Double(distanceDecayAlpha),
            onExceed: .warn, onUnderflow: .warn,
            documentation: "Quadratic depth weight decay: w = 1/(1 + α × d²)"
        )),
        .threshold(ThresholdSpec(
            ssotId: "TSDFConstants.viewingAngleWeightFloor",
            name: "Viewing Angle Weight Floor",
            unit: .dimensionless,
            category: .quality,
            min: 0.01, max: 0.3,
            defaultValue: Double(viewingAngleWeightFloor),
            onExceed: .warn, onUnderflow: .reject,
            documentation: "Minimum weight at grazing angles: max(floor, cos(θ))"
        )),
        .systemConstant(SystemConstantSpec(
            ssotId: "TSDFConstants.carvingDecayRate",
            name: "Space Carving Decay Rate",
            unit: .count,
            value: Int(carvingDecayRate),
            documentation: "Weight decay per frame for space carving (UInt8)"
        )),
        
        // Section 4: Depth Filtering (3 constants - skipLowConfidencePixels is Bool, excluded)
        .threshold(ThresholdSpec(
            ssotId: "TSDFConstants.depthMin",
            name: "Minimum Depth",
            unit: .meters,
            category: .safety,
            min: 0.05, max: 0.2,
            defaultValue: Double(depthMin),
            onExceed: .warn, onUnderflow: .reject,
            documentation: "Minimum reliable depth (hardware floor)"
        )),
        .threshold(ThresholdSpec(
            ssotId: "TSDFConstants.depthMax",
            name: "Maximum Depth",
            unit: .meters,
            category: .safety,
            min: 3.0, max: 8.0,
            defaultValue: Double(depthMax),
            onExceed: .clamp, onUnderflow: .warn,
            documentation: "Maximum reliable depth"
        )),
        .threshold(ThresholdSpec(
            ssotId: "TSDFConstants.minValidPixelRatio",
            name: "Min Valid Pixel Ratio",
            unit: .ratio,
            category: .quality,
            min: 0.1, max: 0.5,
            defaultValue: Double(minValidPixelRatio),
            onExceed: .warn, onUnderflow: .reject,
            documentation: "Minimum fraction of valid depth pixels to accept frame"
        )),
        
        // Section 5: Performance Budget (5 constants)
        .systemConstant(SystemConstantSpec(
            ssotId: "TSDFConstants.maxVoxelsPerFrame",
            name: "Max Voxels Per Frame",
            unit: .count,
            value: maxVoxelsPerFrame,
            documentation: "Maximum voxels updated per GPU frame"
        )),
        .systemConstant(SystemConstantSpec(
            ssotId: "TSDFConstants.maxTrianglesPerCycle",
            name: "Max Triangles Per Meshing Cycle",
            unit: .count,
            value: maxTrianglesPerCycle,
            documentation: "Hard safety cap on triangles per meshing cycle"
        )),
        .threshold(ThresholdSpec(
            ssotId: "TSDFConstants.integrationTimeoutMs",
            name: "Integration Timeout",
            unit: .milliseconds,
            category: .performance,
            min: 5.0, max: 14.0,
            defaultValue: integrationTimeoutMs,
            onExceed: .warn, onUnderflow: .warn,
            documentation: "Maximum CPU+GPU time for integration pass"
        )),
        .systemConstant(SystemConstantSpec(
            ssotId: "TSDFConstants.metalThreadgroupSize",
            name: "Metal Threadgroup Size",
            unit: .count,
            value: metalThreadgroupSize,
            documentation: "Threadgroup edge size (8×8=64 threads)"
        )),
        .systemConstant(SystemConstantSpec(
            ssotId: "TSDFConstants.metalInflightBuffers",
            name: "Metal Inflight Buffers",
            unit: .count,
            value: metalInflightBuffers,
            documentation: "Triple-buffer count for per-frame TSDF data. References MetalConstants.inflightBufferCount (single truth for all PRs)."
        )),
        
        // Section 6: Memory Management (7 constants)
        .systemConstant(SystemConstantSpec(
            ssotId: "TSDFConstants.maxTotalVoxelBlocks",
            name: "Max Total Voxel Blocks",
            unit: .count,
            value: maxTotalVoxelBlocks,
            documentation: "Maximum voxel blocks across all resolutions"
        )),
        .systemConstant(SystemConstantSpec(
            ssotId: "TSDFConstants.hashTableInitialSize",
            name: "Hash Table Initial Size",
            unit: .count,
            value: hashTableInitialSize,
            documentation: "Initial hash table capacity (power of 2)"
        )),
        .threshold(ThresholdSpec(
            ssotId: "TSDFConstants.hashTableMaxLoadFactor",
            name: "Hash Table Max Load Factor",
            unit: .ratio,
            category: .performance,
            min: 0.5, max: 0.85,
            defaultValue: Double(hashTableMaxLoadFactor),
            onExceed: .reject, onUnderflow: .warn,
            documentation: "Load factor threshold triggering rehash"
        )),
        .systemConstant(SystemConstantSpec(
            ssotId: "TSDFConstants.hashMaxProbeLength",
            name: "Hash Max Probe Length",
            unit: .count,
            value: hashMaxProbeLength,
            documentation: "Maximum linear probe before giving up"
        )),
        .threshold(ThresholdSpec(
            ssotId: "TSDFConstants.dirtyThresholdMultiplier",
            name: "Dirty Threshold Multiplier",
            unit: .dimensionless,
            category: .quality,
            min: 0.1, max: 1.0,
            defaultValue: Double(dirtyThresholdMultiplier),
            onExceed: .warn, onUnderflow: .warn,
            documentation: "Block dirty threshold = multiplier × voxelSize"
        )),
        .threshold(ThresholdSpec(
            ssotId: "TSDFConstants.staleBlockEvictionAge",
            name: "Stale Block Eviction Age",
            unit: .seconds,
            category: .resource,
            min: 10.0, max: 60.0,
            defaultValue: staleBlockEvictionAge,
            onExceed: .warn, onUnderflow: .warn,
            documentation: "Age threshold for low-priority block eviction"
        )),
        .threshold(ThresholdSpec(
            ssotId: "TSDFConstants.staleBlockForceEvictionAge",
            name: "Stale Block Force Eviction Age",
            unit: .seconds,
            category: .resource,
            min: 30.0, max: 120.0,
            defaultValue: staleBlockForceEvictionAge,
            onExceed: .warn, onUnderflow: .warn,
            documentation: "Age threshold for forced block eviction"
        )),
        
        // Section 7: Block Geometry (1 constant)
        .fixedConstant(FixedConstantSpec(
            ssotId: "TSDFConstants.blockSize",
            name: "Block Size",
            unit: .count,
            value: blockSize,
            documentation: "Voxels per block edge (8³=512). Industry standard: nvblox, KinectFusion, InfiniTAM."
        )),
        
        // Section 8: Camera Pose Safety (5 constants)
        .threshold(ThresholdSpec(
            ssotId: "TSDFConstants.maxPoseDeltaPerFrame",
            name: "Max Pose Delta Per Frame",
            unit: .meters,
            category: .safety,
            min: 0.05, max: 0.2,
            defaultValue: Double(maxPoseDeltaPerFrame),
            onExceed: .reject, onUnderflow: .warn,
            documentation: "Position delta threshold for teleport rejection"
        )),
        .threshold(ThresholdSpec(
            ssotId: "TSDFConstants.maxAngularVelocity",
            name: "Max Angular Velocity",
            unit: .degreesPerSecond,
            category: .motion,
            min: 1.0, max: 4.0,
            defaultValue: Double(maxAngularVelocity),
            onExceed: .reject, onUnderflow: .warn,
            documentation: "Angular velocity threshold for frame rejection (rad/s)"
        )),
        .systemConstant(SystemConstantSpec(
            ssotId: "TSDFConstants.poseRejectWarningCount",
            name: "Pose Reject Warning Count",
            unit: .frames,
            value: poseRejectWarningCount,
            documentation: "Consecutive rejected frames before warning toast"
        )),
        .systemConstant(SystemConstantSpec(
            ssotId: "TSDFConstants.poseRejectFailCount",
            name: "Pose Reject Fail Count",
            unit: .frames,
            value: poseRejectFailCount,
            documentation: "Consecutive rejected frames before fail state"
        )),
        .threshold(ThresholdSpec(
            ssotId: "TSDFConstants.loopClosureDriftThreshold",
            name: "Loop Closure Drift Threshold",
            unit: .meters,
            category: .quality,
            min: 0.01, max: 0.05,
            defaultValue: Double(loopClosureDriftThreshold),
            onExceed: .warn, onUnderflow: .warn,
            documentation: "Anchor shift threshold to mark blocks stale"
        )),
        
        // Section 9: Keyframe Selection (4 constants)
        .systemConstant(SystemConstantSpec(
            ssotId: "TSDFConstants.keyframeInterval",
            name: "Keyframe Interval",
            unit: .frames,
            value: keyframeInterval,
            documentation: "Every Nth integrated frame is a keyframe candidate"
        )),
        .threshold(ThresholdSpec(
            ssotId: "TSDFConstants.keyframeAngularTriggerDeg",
            name: "Keyframe Angular Trigger",
            unit: .degrees,
            category: .quality,
            min: 5.0, max: 30.0,
            defaultValue: Double(keyframeAngularTriggerDeg),
            onExceed: .warn, onUnderflow: .warn,
            documentation: "Viewpoint angular change threshold for keyframe"
        )),
        .threshold(ThresholdSpec(
            ssotId: "TSDFConstants.keyframeTranslationTrigger",
            name: "Keyframe Translation Trigger",
            unit: .meters,
            category: .quality,
            min: 0.1, max: 0.5,
            defaultValue: Double(keyframeTranslationTrigger),
            onExceed: .warn, onUnderflow: .warn,
            documentation: "Camera movement threshold for keyframe"
        )),
        .systemConstant(SystemConstantSpec(
            ssotId: "TSDFConstants.maxKeyframesPerSession",
            name: "Max Keyframes Per Session",
            unit: .count,
            value: maxKeyframesPerSession,
            documentation: "Memory budget cap for retained RGB keyframes"
        )),
        
        // Section 10: GPU Safety (4 constants)
        .threshold(ThresholdSpec(
            ssotId: "TSDFConstants.semaphoreWaitTimeoutMs",
            name: "Semaphore Wait Timeout",
            unit: .milliseconds,
            category: .safety,
            min: 50.0, max: 200.0,
            defaultValue: semaphoreWaitTimeoutMs,
            onExceed: .warn, onUnderflow: .warn,
            documentation: "GPU fence timeout before frame skip"
        )),
        .systemConstant(SystemConstantSpec(
            ssotId: "TSDFConstants.gpuMemoryProactiveEvictBytes",
            name: "GPU Memory Proactive Evict",
            unit: .count,
            value: gpuMemoryProactiveEvictBytes,
            documentation: "Allocated GPU memory threshold for proactive eviction (bytes)"
        )),
        .systemConstant(SystemConstantSpec(
            ssotId: "TSDFConstants.gpuMemoryAggressiveEvictBytes",
            name: "GPU Memory Aggressive Evict",
            unit: .count,
            value: gpuMemoryAggressiveEvictBytes,
            documentation: "Allocated GPU memory threshold for aggressive eviction (bytes)"
        )),
        .threshold(ThresholdSpec(
            ssotId: "TSDFConstants.worldOriginRecenterDistance",
            name: "World Origin Recenter Distance",
            unit: .meters,
            category: .safety,
            min: 50.0, max: 500.0,
            defaultValue: Double(worldOriginRecenterDistance),
            onExceed: .warn, onUnderflow: .warn,
            documentation: "Camera distance from origin before recentering"
        )),
        
        // Section 11: AIMD Thermal Management (5 constants)
        .threshold(ThresholdSpec(
            ssotId: "TSDFConstants.thermalDegradeHysteresisS",
            name: "Thermal Degrade Hysteresis",
            unit: .seconds,
            category: .performance,
            min: 5.0, max: 20.0,
            defaultValue: thermalDegradeHysteresisS,
            onExceed: .warn, onUnderflow: .warn,
            documentation: "Cooldown before accepting worse thermal ceiling"
        )),
        .threshold(ThresholdSpec(
            ssotId: "TSDFConstants.thermalRecoverHysteresisS",
            name: "Thermal Recover Hysteresis",
            unit: .seconds,
            category: .performance,
            min: 2.0, max: 10.0,
            defaultValue: thermalRecoverHysteresisS,
            onExceed: .warn, onUnderflow: .warn,
            documentation: "Cooldown before accepting better thermal ceiling (asymmetric)"
        )),
        .systemConstant(SystemConstantSpec(
            ssotId: "TSDFConstants.thermalRecoverGoodFrames",
            name: "Thermal Recover Good Frames",
            unit: .frames,
            value: thermalRecoverGoodFrames,
            documentation: "Consecutive good frames before AIMD additive-increase"
        )),
        .threshold(ThresholdSpec(
            ssotId: "TSDFConstants.thermalGoodFrameRatio",
            name: "Thermal Good Frame Ratio",
            unit: .ratio,
            category: .performance,
            min: 0.5, max: 0.95,
            defaultValue: Double(thermalGoodFrameRatio),
            onExceed: .warn, onUnderflow: .warn,
            documentation: "GPU time / timeout ratio threshold for 'good' frame"
        )),
        .systemConstant(SystemConstantSpec(
            ssotId: "TSDFConstants.thermalMaxIntegrationSkip",
            name: "Thermal Max Integration Skip",
            unit: .count,
            value: thermalMaxIntegrationSkip,
            documentation: "Maximum frame skip count (absolute floor = 5fps)"
        )),
        
        // Section 12: Mesh Extraction Quality (3 constants)
        .threshold(ThresholdSpec(
            ssotId: "TSDFConstants.minTriangleArea",
            name: "Min Triangle Area",
            unit: .meters,
            category: .quality,
            min: 1e-10, max: 1e-6,
            defaultValue: Double(minTriangleArea),
            onExceed: .warn, onUnderflow: .reject,
            documentation: "Degenerate triangle area rejection threshold (m²)"
        )),
        .threshold(ThresholdSpec(
            ssotId: "TSDFConstants.maxTriangleAspectRatio",
            name: "Max Triangle Aspect Ratio",
            unit: .dimensionless,
            category: .quality,
            min: 10.0, max: 500.0,
            defaultValue: Double(maxTriangleAspectRatio),
            onExceed: .clamp, onUnderflow: .warn,
            documentation: "Degenerate triangle needle rejection threshold"
        )),
        .systemConstant(SystemConstantSpec(
            ssotId: "TSDFConstants.integrationRecordCapacity",
            name: "Integration Record Capacity",
            unit: .frames,
            value: integrationRecordCapacity,
            documentation: "Ring buffer size for IntegrationRecord history"
        )),
        
        // Section 13: UX Stability Constants (11 constants)
        .threshold(ThresholdSpec(
            ssotId: "TSDFConstants.sdfDeadZoneBase",
            name: "SDF Dead Zone Base",
            unit: .meters,
            category: .quality,
            min: 0.0005, max: 0.003,
            defaultValue: Double(sdfDeadZoneBase),
            onExceed: .warn, onUnderflow: .warn,
            documentation: "SDF update dead zone for fresh voxels (UX-1)"
        )),
        .threshold(ThresholdSpec(
            ssotId: "TSDFConstants.sdfDeadZoneWeightScale",
            name: "SDF Dead Zone Weight Scale",
            unit: .meters,
            category: .quality,
            min: 0.001, max: 0.01,
            defaultValue: Double(sdfDeadZoneWeightScale),
            onExceed: .warn, onUnderflow: .warn,
            documentation: "Additional dead zone at max weight (UX-1)"
        )),
        .threshold(ThresholdSpec(
            ssotId: "TSDFConstants.vertexQuantizationStep",
            name: "Vertex Quantization Step",
            unit: .meters,
            category: .quality,
            min: 0.0002, max: 0.001,
            defaultValue: Double(vertexQuantizationStep),
            onExceed: .warn, onUnderflow: .warn,
            documentation: "Grid snap step for extracted vertices (UX-2)"
        )),
        .threshold(ThresholdSpec(
            ssotId: "TSDFConstants.meshExtractionTargetHz",
            name: "Mesh Extraction Target Hz",
            unit: .count,
            category: .performance,
            min: 5.0, max: 30.0,
            defaultValue: Double(meshExtractionTargetHz),
            onExceed: .warn, onUnderflow: .warn,
            documentation: "Target mesh extraction rate (UX-3)"
        )),
        .threshold(ThresholdSpec(
            ssotId: "TSDFConstants.meshExtractionBudgetMs",
            name: "Mesh Extraction Budget",
            unit: .milliseconds,
            category: .performance,
            min: 2.0, max: 8.0,
            defaultValue: meshExtractionBudgetMs,
            onExceed: .warn, onUnderflow: .warn,
            documentation: "Max wall-clock time per meshing cycle (UX-3)"
        )),
        .threshold(ThresholdSpec(
            ssotId: "TSDFConstants.mcInterpolationMin",
            name: "MC Interpolation Min",
            unit: .dimensionless,
            category: .quality,
            min: 0.01, max: 0.2,
            defaultValue: Double(mcInterpolationMin),
            onExceed: .warn, onUnderflow: .warn,
            documentation: "Lower clamp for MC zero-crossing t parameter (UX-6)"
        )),
        .threshold(ThresholdSpec(
            ssotId: "TSDFConstants.mcInterpolationMax",
            name: "MC Interpolation Max",
            unit: .dimensionless,
            category: .quality,
            min: 0.8, max: 0.99,
            defaultValue: Double(mcInterpolationMax),
            onExceed: .warn, onUnderflow: .warn,
            documentation: "Upper clamp for MC zero-crossing t parameter (UX-6)"
        )),
        .threshold(ThresholdSpec(
            ssotId: "TSDFConstants.poseJitterGateTranslation",
            name: "Pose Jitter Gate Translation",
            unit: .meters,
            category: .motion,
            min: 0.0005, max: 0.005,
            defaultValue: Double(poseJitterGateTranslation),
            onExceed: .warn, onUnderflow: .warn,
            documentation: "Min camera movement to trigger integration (UX-7)"
        )),
        .threshold(ThresholdSpec(
            ssotId: "TSDFConstants.poseJitterGateRotation",
            name: "Pose Jitter Gate Rotation",
            unit: .dimensionless,
            category: .motion,
            min: 0.001, max: 0.01,
            defaultValue: Double(poseJitterGateRotation),
            onExceed: .warn, onUnderflow: .warn,
            documentation: "Min camera rotation to trigger integration (rad, UX-7)"
        )),
        .fixedConstant(FixedConstantSpec(
            ssotId: "TSDFConstants.minObservationsBeforeMesh",
            name: "Min Observations Before Mesh",
            unit: .count,
            value: Int(minObservationsBeforeMesh),
            documentation: "Minimum integration touches before mesh extraction (UX-8)"
        )),
        .systemConstant(SystemConstantSpec(
            ssotId: "TSDFConstants.meshFadeInFrames",
            name: "Mesh Fade-In Frames",
            unit: .frames,
            value: meshFadeInFrames,
            documentation: "Fade-in duration after min observations met (UX-8)"
        )),
        
        // Section 14: Congestion Control Constants (UX-9) - 9 constants
        .threshold(ThresholdSpec(
            ssotId: "TSDFConstants.meshBudgetTargetMs",
            name: "Mesh Budget Target",
            unit: .milliseconds,
            category: .performance,
            min: 2.0, max: 6.0,
            defaultValue: meshBudgetTargetMs,
            onExceed: .warn, onUnderflow: .warn,
            documentation: "Target meshing cycle time for congestion control"
        )),
        .threshold(ThresholdSpec(
            ssotId: "TSDFConstants.meshBudgetGoodMs",
            name: "Mesh Budget Good",
            unit: .milliseconds,
            category: .performance,
            min: 1.0, max: 4.0,
            defaultValue: meshBudgetGoodMs,
            onExceed: .warn, onUnderflow: .warn,
            documentation: "Good cycle threshold for additive increase"
        )),
        .threshold(ThresholdSpec(
            ssotId: "TSDFConstants.meshBudgetOverrunMs",
            name: "Mesh Budget Overrun",
            unit: .milliseconds,
            category: .performance,
            min: 4.0, max: 10.0,
            defaultValue: meshBudgetOverrunMs,
            onExceed: .warn, onUnderflow: .warn,
            documentation: "Overrun threshold for multiplicative decrease"
        )),
        .systemConstant(SystemConstantSpec(
            ssotId: "TSDFConstants.minBlocksPerExtraction",
            name: "Min Blocks Per Extraction",
            unit: .count,
            value: minBlocksPerExtraction,
            documentation: "Floor: always make meshing progress"
        )),
        .systemConstant(SystemConstantSpec(
            ssotId: "TSDFConstants.maxBlocksPerExtraction",
            name: "Max Blocks Per Extraction",
            unit: .count,
            value: maxBlocksPerExtraction,
            documentation: "Ceiling: per-device max blocks per cycle"
        )),
        .systemConstant(SystemConstantSpec(
            ssotId: "TSDFConstants.blockRampPerCycle",
            name: "Block Ramp Per Cycle",
            unit: .count,
            value: blockRampPerCycle,
            documentation: "Additive increase per good meshing cycle"
        )),
        .systemConstant(SystemConstantSpec(
            ssotId: "TSDFConstants.consecutiveGoodCyclesBeforeRamp",
            name: "Consecutive Good Cycles Before Ramp",
            unit: .count,
            value: consecutiveGoodCyclesBeforeRamp,
            documentation: "Good cycles required before block count increase"
        )),
        .systemConstant(SystemConstantSpec(
            ssotId: "TSDFConstants.forgivenessWindowCycles",
            name: "Forgiveness Window Cycles",
            unit: .count,
            value: forgivenessWindowCycles,
            documentation: "Cooldown cycles after overrun"
        )),
        .threshold(ThresholdSpec(
            ssotId: "TSDFConstants.slowStartRatio",
            name: "Slow Start Ratio",
            unit: .ratio,
            category: .performance,
            min: 0.1, max: 0.5,
            defaultValue: Double(slowStartRatio),
            onExceed: .warn, onUnderflow: .warn,
            documentation: "Recovery start ratio after overrun"
        )),
        
        // Section 15: Motion Tier Constants (UX-10, UX-11, UX-12) - 6 constants
        .threshold(ThresholdSpec(
            ssotId: "TSDFConstants.normalAveragingBoundaryDistance",
            name: "Normal Averaging Boundary Distance",
            unit: .meters,
            category: .quality,
            min: 0.0005, max: 0.003,
            defaultValue: Double(normalAveragingBoundaryDistance),
            onExceed: .warn, onUnderflow: .warn,
            documentation: "Distance from block edge for normal averaging (UX-10)"
        )),
        .threshold(ThresholdSpec(
            ssotId: "TSDFConstants.motionDeferTranslationSpeed",
            name: "Motion Defer Translation Speed",
            unit: .meters,
            category: .motion,
            min: 0.2, max: 1.0,
            defaultValue: Double(motionDeferTranslationSpeed),
            onExceed: .warn, onUnderflow: .warn,
            documentation: "Translation speed above which meshing defers (UX-11)"
        )),
        .threshold(ThresholdSpec(
            ssotId: "TSDFConstants.motionDeferAngularSpeed",
            name: "Motion Defer Angular Speed",
            unit: .dimensionless,
            category: .motion,
            min: 0.5, max: 1.5,
            defaultValue: Double(motionDeferAngularSpeed),
            onExceed: .warn, onUnderflow: .warn,
            documentation: "Angular speed above which meshing defers (rad/s, UX-11)"
        )),
        .threshold(ThresholdSpec(
            ssotId: "TSDFConstants.idleTranslationSpeed",
            name: "Idle Translation Speed",
            unit: .meters,
            category: .motion,
            min: 0.005, max: 0.05,
            defaultValue: Double(idleTranslationSpeed),
            onExceed: .warn, onUnderflow: .warn,
            documentation: "Speed below which camera is considered idle (UX-12)"
        )),
        .threshold(ThresholdSpec(
            ssotId: "TSDFConstants.idleAngularSpeed",
            name: "Idle Angular Speed",
            unit: .dimensionless,
            category: .motion,
            min: 0.02, max: 0.1,
            defaultValue: Double(idleAngularSpeed),
            onExceed: .warn, onUnderflow: .warn,
            documentation: "Angular speed below which camera is idle (rad/s, UX-12)"
        )),
        .threshold(ThresholdSpec(
            ssotId: "TSDFConstants.anticipatoryPreallocationDistance",
            name: "Anticipatory Preallocation Distance",
            unit: .meters,
            category: .performance,
            min: 0.2, max: 1.0,
            defaultValue: Double(anticipatoryPreallocationDistance),
            onExceed: .warn, onUnderflow: .warn,
            documentation: "Look-ahead distance for idle block preallocation (UX-12)"
        ))
        
        // TOTAL: 77 specs registered (Sections 1-15). Remaining EP/FP constants are optional/future
        // and NOT registered (their enable flags are Bool → excluded by SSOTTypes).
    ]
    
    // ════════════════════════════════════════════════════════════════
    // MARK: - Cross-Validation
    // ════════════════════════════════════════════════════════════════
    
    public static func validateRelationships() -> [String] {
        var errors: [String] = []
        
        // Voxel sizes must be strictly increasing
        if voxelSizeNear >= voxelSizeMid { errors.append("voxelSizeNear must be < voxelSizeMid") }
        if voxelSizeMid >= voxelSizeFar { errors.append("voxelSizeMid must be < voxelSizeFar") }
        
        // Depth thresholds must be ordered
        if depthNearThreshold >= depthFarThreshold { errors.append("depthNearThreshold must be < depthFarThreshold") }
        if depthMin >= depthNearThreshold { errors.append("depthMin must be < depthNearThreshold") }
        
        // Truncation must be >= 2× voxel size
        let minTruncation = truncationMultiplier * voxelSizeNear
        if minTruncation < 2.0 * voxelSizeNear { errors.append("truncationMultiplier too small for near voxels") }
        
        // Memory budget sanity
        let totalMemoryBytes = maxTotalVoxelBlocks * blockSize * blockSize * blockSize * 8
        if totalMemoryBytes > 800_000_000 { errors.append("Total voxel memory exceeds 800 MB safety limit") }
        
        // Weight hierarchy
        if confidenceWeightLow >= confidenceWeightMid { errors.append("confidenceWeightLow must be < confidenceWeightMid") }
        if confidenceWeightMid >= confidenceWeightHigh { errors.append("confidenceWeightMid must be < confidenceWeightHigh") }
        
        // Performance budget
        if integrationTimeoutMs > 14.0 { errors.append("integrationTimeoutMs too large for 60fps frame budget") }
        
        // Congestion control consistency
        if meshBudgetGoodMs >= meshBudgetOverrunMs { errors.append("meshBudgetGoodMs must be < meshBudgetOverrunMs") }
        if meshBudgetTargetMs >= meshBudgetOverrunMs { errors.append("meshBudgetTargetMs must be < meshBudgetOverrunMs") }
        if minBlocksPerExtraction >= maxBlocksPerExtraction { errors.append("minBlocksPerExtraction must be < maxBlocksPerExtraction") }
        
        // Motion tiers ordering
        if idleTranslationSpeed >= motionDeferTranslationSpeed {
            errors.append("idleTranslationSpeed must be < motionDeferTranslationSpeed")
        }
        if idleAngularSpeed >= motionDeferAngularSpeed {
            errors.append("idleAngularSpeed must be < motionDeferAngularSpeed")
        }
        
        // Stale block ages must be ordered
        if staleBlockEvictionAge >= staleBlockForceEvictionAge {
            errors.append("staleBlockEvictionAge must be < staleBlockForceEvictionAge")
        }
        
        // GPU memory thresholds must be ordered
        if gpuMemoryProactiveEvictBytes >= gpuMemoryAggressiveEvictBytes {
            errors.append("gpuMemoryProactiveEvictBytes must be < gpuMemoryAggressiveEvictBytes")
        }
        
        // Thermal hysteresis
        if thermalRecoverHysteresisS > thermalDegradeHysteresisS {
            errors.append("thermalRecoverHysteresisS must be <= thermalDegradeHysteresisS")
        }
        
        // MC interpolation
        if mcInterpolationMin >= mcInterpolationMax {
            errors.append("mcInterpolationMin must be < mcInterpolationMax")
        }
        
        return errors
    }
}
