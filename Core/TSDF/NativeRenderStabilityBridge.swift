// SPDX-License-Identifier: LicenseRef-Aether3D-Proprietary
// Copyright (c) 2024-2026 Aether3D. All rights reserved.

import Foundation
import CAetherNativeBridge
#if canImport(simd)
import simd
#endif

public struct MeshStabilityQuery: Sendable, Equatable {
    public var blockX: Int32
    public var blockY: Int32
    public var blockZ: Int32
    public var lastMeshGeneration: UInt32

    public init(
        blockX: Int32,
        blockY: Int32,
        blockZ: Int32,
        lastMeshGeneration: UInt32
    ) {
        self.blockX = blockX
        self.blockY = blockY
        self.blockZ = blockZ
        self.lastMeshGeneration = lastMeshGeneration
    }
}

public struct MeshStabilityResult: Sendable, Equatable {
    public var needsReExtraction: Bool
    public var currentIntegrationGeneration: UInt32
    public var fadeInAlpha: Float
    public var evictionWeight: Float

    public init(
        needsReExtraction: Bool,
        currentIntegrationGeneration: UInt32,
        fadeInAlpha: Float,
        evictionWeight: Float
    ) {
        self.needsReExtraction = needsReExtraction
        self.currentIntegrationGeneration = currentIntegrationGeneration
        self.fadeInAlpha = fadeInAlpha
        self.evictionWeight = evictionWeight
    }
}

public struct ConfidenceDecaySample: Sendable, Equatable {
    public var id: UInt32
    public var opacity: Float
    public var uncertainty: Float
    public var observationCount: UInt16

    public init(
        id: UInt32,
        opacity: Float,
        uncertainty: Float,
        observationCount: UInt16 = 0
    ) {
        self.id = id
        self.opacity = opacity
        self.uncertainty = uncertainty
        self.observationCount = observationCount
    }
}

public struct ConfidenceDecayConfig: Sendable, Equatable {
    public var decayPerFrame: Float
    public var minConfidence: Float
    public var observationBoost: Float
    public var maxConfidence: Float
    public var graceFrames: UInt32

    public init(
        decayPerFrame: Float = 0.005,
        minConfidence: Float = 0.05,
        observationBoost: Float = 0.15,
        maxConfidence: Float = 1.0,
        graceFrames: UInt32 = 30
    ) {
        self.decayPerFrame = decayPerFrame
        self.minConfidence = minConfidence
        self.observationBoost = observationBoost
        self.maxConfidence = maxConfidence
        self.graceFrames = graceFrames
    }
}

public struct PatchIdentitySample: Sendable, Equatable {
    public var patchKey: UInt64
    public var centroid: SIMD3<Float>
    public var display: Float

    public init(
        patchKey: UInt64,
        centroid: SIMD3<Float>,
        display: Float
    ) {
        self.patchKey = patchKey
        self.centroid = centroid
        self.display = display
    }
}

public struct RenderTriangleCandidate: Sendable, Equatable {
    public var patchKey: UInt64
    public var centroid: SIMD3<Float>
    public var display: Float
    public var stabilityFadeAlpha: Float
    public var residencyUntilFrame: Int32

    public init(
        patchKey: UInt64,
        centroid: SIMD3<Float>,
        display: Float,
        stabilityFadeAlpha: Float,
        residencyUntilFrame: Int32
    ) {
        self.patchKey = patchKey
        self.centroid = centroid
        self.display = display
        self.stabilityFadeAlpha = stabilityFadeAlpha
        self.residencyUntilFrame = residencyUntilFrame
    }
}

public struct RenderSelectionConfig: Sendable, Equatable {
    public var currentFrame: Int32
    public var maxTriangles: Int32
    public var cameraPosition: SIMD3<Float>
    public var completionThreshold: Float
    public var distanceBias: Float
    public var displayWeight: Float
    public var residencyBoost: Float
    public var completionBoost: Float
    public var stabilityWeight: Float

    public init(
        currentFrame: Int32,
        maxTriangles: Int32,
        cameraPosition: SIMD3<Float>,
        completionThreshold: Float = 0.75,
        distanceBias: Float = 0.05,
        displayWeight: Float = 2.0,
        residencyBoost: Float = 0.75,
        completionBoost: Float = BridgeInteropConstants.renderSelectionCompletionBoost,
        stabilityWeight: Float = 0.3
    ) {
        self.currentFrame = currentFrame
        self.maxTriangles = maxTriangles
        self.cameraPosition = cameraPosition
        self.completionThreshold = completionThreshold
        self.distanceBias = distanceBias
        self.displayWeight = displayWeight
        self.residencyBoost = residencyBoost
        self.completionBoost = completionBoost
        self.stabilityWeight = stabilityWeight
    }
}

public struct RenderSnapshotSample: Sendable, Equatable {
    public var baseDisplay: Float
    public var confidenceDisplay: Float
    public var hasStability: Bool
    public var fadeInAlpha: Float
    public var evictionWeight: Float

    public init(
        baseDisplay: Float,
        confidenceDisplay: Float,
        hasStability: Bool,
        fadeInAlpha: Float,
        evictionWeight: Float
    ) {
        self.baseDisplay = baseDisplay
        self.confidenceDisplay = confidenceDisplay
        self.hasStability = hasStability
        self.fadeInAlpha = fadeInAlpha
        self.evictionWeight = evictionWeight
    }
}

/// Bridge for render stability C APIs:
/// - aether_query_mesh_stability
/// - aether_decay_confidence
public final class NativeRenderStabilityBridge: @unchecked Sendable {
    private static let defaultRenderResidencyHoldFrames: Int32 = 90
    private var renderSelectionRuntime: OpaquePointer?

    public init() {
        var runtime: OpaquePointer?
        if aether_render_selection_runtime_create(
            nil,
            Self.defaultRenderResidencyHoldFrames,
            &runtime
        ) == 0 {
            self.renderSelectionRuntime = runtime
        } else {
            self.renderSelectionRuntime = nil
        }
    }

    deinit {
        if let runtime = renderSelectionRuntime {
            _ = aether_render_selection_runtime_destroy(runtime)
        }
    }

    public func resetRenderSelectionRuntime() {
        if let runtime = renderSelectionRuntime {
            _ = aether_render_selection_runtime_reset(runtime)
        }
    }

    public func queryMeshStability(
        _ queries: [MeshStabilityQuery],
        currentFrame: UInt64,
        graceFrames: UInt32,
        stalenessThresholdS: Double
    ) -> [MeshStabilityResult]? {
        guard stalenessThresholdS.isFinite, stalenessThresholdS >= 0 else {
            return nil
        }
        guard !queries.isEmpty else {
            return []
        }

        var nativeQueries = [aether_mesh_stability_query_t](
            repeating: aether_mesh_stability_query_t(),
            count: queries.count
        )
        var nativeResults = [aether_mesh_stability_result_t](
            repeating: aether_mesh_stability_result_t(),
            count: queries.count
        )

        for i in nativeQueries.indices {
            let q = queries[i]
            nativeQueries[i].block_x = q.blockX
            nativeQueries[i].block_y = q.blockY
            nativeQueries[i].block_z = q.blockZ
            nativeQueries[i].last_mesh_generation = q.lastMeshGeneration
        }

        let rc = nativeQueries.withUnsafeBufferPointer { queryPtr in
            nativeResults.withUnsafeMutableBufferPointer { resultPtr in
                aether_query_mesh_stability(
                    queryPtr.baseAddress,
                    Int32(nativeQueries.count),
                    currentFrame,
                    UInt64(graceFrames),
                    stalenessThresholdS,
                    resultPtr.baseAddress
                )
            }
        }
        guard rc == 0 else {
            return nil
        }

        return nativeResults.map { item in
            MeshStabilityResult(
                needsReExtraction: item.needs_re_extraction != 0,
                currentIntegrationGeneration: item.current_integration_generation,
                fadeInAlpha: item.fade_in_alpha,
                evictionWeight: item.eviction_weight
            )
        }
    }

    public func decayConfidence(
        _ samples: [ConfidenceDecaySample],
        inCurrentFrustum: [Bool],
        currentFrame: UInt64,
        config: ConfidenceDecayConfig
    ) -> [ConfidenceDecaySample]? {
        guard samples.count == inCurrentFrustum.count else {
            return nil
        }
        guard !samples.isEmpty else {
            return []
        }

        var nativeGaussians = [aether_gaussian_t](
            repeating: aether_gaussian_t(),
            count: samples.count
        )
        var frustumFlags = [Int32](repeating: 0, count: samples.count)
        var nativeConfig = aether_confidence_decay_config_t(
            decay_per_frame: config.decayPerFrame,
            min_confidence: config.minConfidence,
            observation_boost: config.observationBoost,
            max_confidence: config.maxConfidence,
            grace_frames: config.graceFrames,
            peak_retention_floor: BridgeInteropConstants.confidenceDecayPeakRetentionFloor,
            perceptual_exponent: BridgeInteropConstants.confidenceDecayPerceptualExponent
        )

        for i in nativeGaussians.indices {
            let sample = samples[i]
            nativeGaussians[i].id = sample.id
            nativeGaussians[i].opacity = sample.opacity
            nativeGaussians[i].uncertainty = sample.uncertainty
            nativeGaussians[i].observation_count = sample.observationCount
            frustumFlags[i] = inCurrentFrustum[i] ? 1 : 0
        }

        let gaussianCount = Int32(nativeGaussians.count)
        let rc = nativeGaussians.withUnsafeMutableBufferPointer { gaussianPtr in
            frustumFlags.withUnsafeBufferPointer { frustumPtr in
                aether_decay_confidence(
                    gaussianPtr.baseAddress,
                    gaussianCount,
                    frustumPtr.baseAddress,
                    currentFrame,
                    &nativeConfig
                )
            }
        }
        guard rc == 0 else {
            return nil
        }

        return nativeGaussians.map { gaussian in
            ConfidenceDecaySample(
                id: gaussian.id,
                opacity: gaussian.opacity,
                uncertainty: gaussian.uncertainty,
                observationCount: gaussian.observation_count
            )
        }
    }

    public func matchPatchIdentities(
        observations: [PatchIdentitySample],
        anchors: [PatchIdentitySample],
        lockDisplayThreshold: Float,
        snapDistanceM: Float,
        cellSizeM: Float = 0.02
    ) -> [UInt64]? {
        guard !observations.isEmpty else {
            return []
        }

        var nativeObservations = [aether_patch_identity_sample_t](
            repeating: aether_patch_identity_sample_t(),
            count: observations.count
        )
        var nativeAnchors = [aether_patch_identity_sample_t](
            repeating: aether_patch_identity_sample_t(),
            count: anchors.count
        )
        var resolved = [UInt64](repeating: 0, count: observations.count)

        for i in nativeObservations.indices {
            let sample = observations[i]
            nativeObservations[i].patch_key = sample.patchKey
            nativeObservations[i].centroid = aether_float3_t(
                x: sample.centroid.x,
                y: sample.centroid.y,
                z: sample.centroid.z
            )
            nativeObservations[i].display = sample.display
        }
        for i in nativeAnchors.indices {
            let sample = anchors[i]
            nativeAnchors[i].patch_key = sample.patchKey
            nativeAnchors[i].centroid = aether_float3_t(
                x: sample.centroid.x,
                y: sample.centroid.y,
                z: sample.centroid.z
            )
            nativeAnchors[i].display = sample.display
        }

        let rc = nativeObservations.withUnsafeBufferPointer { obsPtr in
            nativeAnchors.withUnsafeBufferPointer { anchorPtr in
                resolved.withUnsafeMutableBufferPointer { resolvedPtr in
                    aether_match_patch_identities(
                        obsPtr.baseAddress,
                        Int32(nativeObservations.count),
                        anchorPtr.baseAddress,
                        Int32(nativeAnchors.count),
                        lockDisplayThreshold,
                        snapDistanceM,
                        cellSizeM,
                        resolvedPtr.baseAddress
                    )
                }
            }
        }
        guard rc == 0 else {
            return nil
        }
        return resolved
    }

    public func selectStableRenderTriangles(
        candidates: [RenderTriangleCandidate],
        config: RenderSelectionConfig
    ) -> [Int]? {
        guard !candidates.isEmpty else {
            return []
        }

        var nativeCandidates = [aether_render_triangle_candidate_t](
            repeating: aether_render_triangle_candidate_t(),
            count: candidates.count
        )
        var nativeConfig = aether_render_selection_config_t(
            current_frame: config.currentFrame,
            max_triangles: config.maxTriangles,
            camera_position: aether_float3_t(
                x: config.cameraPosition.x,
                y: config.cameraPosition.y,
                z: config.cameraPosition.z
            ),
            completion_threshold: config.completionThreshold,
            distance_bias: config.distanceBias,
            display_weight: config.displayWeight,
            residency_boost: config.residencyBoost,
            completion_boost: config.completionBoost,
            stability_weight: config.stabilityWeight
        )

        for i in nativeCandidates.indices {
            let candidate = candidates[i]
            nativeCandidates[i].patch_key = candidate.patchKey
            nativeCandidates[i].centroid = aether_float3_t(
                x: candidate.centroid.x,
                y: candidate.centroid.y,
                z: candidate.centroid.z
            )
            nativeCandidates[i].display = candidate.display
            nativeCandidates[i].stability_fade_alpha = candidate.stabilityFadeAlpha
            nativeCandidates[i].residency_until_frame = candidate.residencyUntilFrame
        }

        var selectedIndices = [Int32](repeating: -1, count: candidates.count)
        var selectedCount: Int32 = 0
        let rc: Int32
        if let runtime = renderSelectionRuntime {
            rc = nativeCandidates.withUnsafeBufferPointer { candPtr in
                selectedIndices.withUnsafeMutableBufferPointer { selectedPtr in
                    aether_render_selection_runtime_select(
                        runtime,
                        candPtr.baseAddress,
                        Int32(nativeCandidates.count),
                        &nativeConfig,
                        selectedPtr.baseAddress,
                        &selectedCount
                    )
                }
            }
        } else {
            rc = nativeCandidates.withUnsafeBufferPointer { candPtr in
                selectedIndices.withUnsafeMutableBufferPointer { selectedPtr in
                    aether_select_stable_render_triangles(
                        candPtr.baseAddress,
                        Int32(nativeCandidates.count),
                        &nativeConfig,
                        selectedPtr.baseAddress,
                        &selectedCount
                    )
                }
            }
        }
        guard rc == 0 else {
            return nil
        }

        let safeCount = max(0, min(Int(selectedCount), selectedIndices.count))
        var output: [Int] = []
        output.reserveCapacity(safeCount)
        for i in 0..<safeCount {
            let value = Int(selectedIndices[i])
            if value >= 0, value < candidates.count {
                output.append(value)
            }
        }
        return output
    }

    public func computeRenderSnapshot(
        _ samples: [RenderSnapshotSample],
        s3ToS4Threshold: Float,
        s4ToS5Threshold: Float
    ) -> [Float]? {
        guard !samples.isEmpty else {
            return []
        }
        var nativeInputs = [aether_render_snapshot_input_t](
            repeating: aether_render_snapshot_input_t(),
            count: samples.count
        )
        var output = [Float](repeating: 0, count: samples.count)
        var config = aether_render_snapshot_config_t(
            s3_to_s4_threshold: s3ToS4Threshold,
            s4_to_s5_threshold: s4ToS5Threshold
        )

        for i in nativeInputs.indices {
            let sample = samples[i]
            nativeInputs[i].base_display = sample.baseDisplay
            nativeInputs[i].confidence_display = sample.confidenceDisplay
            nativeInputs[i].has_stability = sample.hasStability ? 1 : 0
            nativeInputs[i].fade_in_alpha = sample.fadeInAlpha
            nativeInputs[i].eviction_weight = sample.evictionWeight
        }

        let rc = nativeInputs.withUnsafeBufferPointer { inPtr in
            output.withUnsafeMutableBufferPointer { outPtr in
                aether_compute_render_snapshot(
                    inPtr.baseAddress,
                    Int32(nativeInputs.count),
                    &config,
                    outPtr.baseAddress
                )
            }
        }
        guard rc == 0 else {
            return nil
        }
        return output
    }
}
