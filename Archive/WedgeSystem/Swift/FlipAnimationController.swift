//
// FlipAnimationController.swift
// Aether3D
//
// PR#7 Scan Guidance UI — Flip Animation Controller
// Runtime flip state machine is delegated to core C++ runtime.
//

import Foundation
#if canImport(simd)
import simd
#endif
import CAetherNativeBridge

/// Flip animation state for a single triangle.
public struct FlipState {
    public let triangleIndex: Int
    public let startTime: TimeInterval
    public let axisOrigin: SIMD3<Float>
    public let axisDirection: SIMD3<Float>
    public let initialDisplay: Double
    public let targetDisplay: Double

    public init(
        triangleIndex: Int,
        startTime: TimeInterval,
        axisOrigin: SIMD3<Float>,
        axisDirection: SIMD3<Float>,
        initialDisplay: Double,
        targetDisplay: Double
    ) {
        self.triangleIndex = triangleIndex
        self.startTime = startTime
        self.axisOrigin = axisOrigin
        self.axisDirection = axisDirection
        self.initialDisplay = initialDisplay
        self.targetDisplay = targetDisplay
    }
}

public final class FlipAnimationController {
    private let nativeRuntime: OpaquePointer?
    private var previousDisplay: [String: Double] = [:]
    private var timelineNow: TimeInterval?

    private func currentTime() -> TimeInterval {
        if let timelineNow {
            return timelineNow
        }
        return ProcessInfo.processInfo.systemUptime
    }

    private static func makeNativeRuntimeConfig() -> aether_flip_runtime_config_t? {
        var config = aether_flip_runtime_config_t()
        guard aether_flip_runtime_default_config(&config) == 0 else {
            return nil
        }
        config.easing.duration_s = Float(ScanGuidanceConstants.flipDurationS)
        config.easing.cp1x = Float(ScanGuidanceConstants.flipEasingCP1X)
        config.easing.cp1y = Float(ScanGuidanceConstants.flipEasingCP1Y)
        config.easing.cp2x = Float(ScanGuidanceConstants.flipEasingCP2X)
        config.easing.cp2y = Float(ScanGuidanceConstants.flipEasingCP2Y)
        config.easing.stagger_delay_s = Float(ScanGuidanceConstants.flipStaggerDelayS)
        config.easing.max_concurrent = Int32(ScanGuidanceConstants.flipMaxConcurrent)
        config.min_display_delta = Float(ScanGuidanceConstants.flipMinDisplayDelta)
        config.threshold_s0_to_s1 = Float(ScanGuidanceConstants.s0ToS1Threshold)
        config.threshold_s1_to_s2 = Float(ScanGuidanceConstants.s1ToS2Threshold)
        config.threshold_s2_to_s3 = Float(ScanGuidanceConstants.s2ToS3Threshold)
        config.threshold_s3_to_s4 = Float(ScanGuidanceConstants.s3ToS4Threshold)
        config.threshold_s4_to_s5 = Float(ScanGuidanceConstants.s4ToS5Threshold)
        return config
    }

    public init() {
        guard var config = Self.makeNativeRuntimeConfig() else {
            self.nativeRuntime = nil
            return
        }
        var runtime: OpaquePointer?
        if aether_flip_runtime_create(&config, &runtime) == 0 {
            self.nativeRuntime = runtime
        } else {
            self.nativeRuntime = nil
        }
    }

    deinit {
        if let nativeRuntime {
            _ = aether_flip_runtime_destroy(nativeRuntime)
        }
    }

    public func checkThresholdCrossings(
        previousDisplay: [String: Double],
        currentDisplay: [String: Double],
        triangles: [ScanTriangle],
        adjacencyGraph: any AdjacencyProvider,
        triangleIDs: [Int]? = nil
    ) -> [Int] {
        defer {
            self.previousDisplay = currentDisplay
        }
        guard let nativeRuntime, !triangles.isEmpty else {
            return []
        }

        let resolvedIDs: [Int]
        if let triangleIDs, triangleIDs.count == triangles.count {
            resolvedIDs = triangleIDs
        } else {
            resolvedIDs = Array(0..<triangles.count)
        }

        var observations = [aether_flip_runtime_observation_t](
            repeating: aether_flip_runtime_observation_t(),
            count: triangles.count
        )
        for (index, triangle) in triangles.enumerated() {
            let stableTriangleIndex = resolvedIDs[index]
            let patchId = triangle.patchId
            let prevValue = Float(min(max(previousDisplay[patchId] ?? 0.0, 0.0), 1.0))
            let currValue = Float(min(max(currentDisplay[patchId] ?? 0.0, 0.0), 1.0))
            let (axisStart, axisEnd) = adjacencyGraph.longestEdge(of: triangle)
            observations[index].patch_key = stablePatchKey(patchId)
            observations[index].previous_display = prevValue
            observations[index].current_display = currValue
            observations[index].triangle_id = Int32(stableTriangleIndex)
            observations[index].axis_start = aether_float3_t(
                x: axisStart.x,
                y: axisStart.y,
                z: axisStart.z
            )
            observations[index].axis_end = aether_float3_t(
                x: axisEnd.x,
                y: axisEnd.y,
                z: axisEnd.z
            )
        }

        var crossed = [Int32](repeating: -1, count: triangles.count)
        var crossedCount: CInt = CInt(crossed.count)
        let now = currentTime()
        let rc = observations.withUnsafeBufferPointer { obsBuffer in
            crossed.withUnsafeMutableBufferPointer { crossedBuffer in
                aether_flip_runtime_ingest(
                    nativeRuntime,
                    obsBuffer.baseAddress,
                    CInt(observations.count),
                    now,
                    crossedBuffer.baseAddress,
                    &crossedCount
                )
            }
        }
        guard rc == 0, crossedCount > 0 else {
            return []
        }
        return Array(crossed.prefix(Int(crossedCount))).map(Int.init)
    }

    public func tick(deltaTime: TimeInterval) -> [Float] {
        guard let nativeRuntime else {
            return []
        }
        if timelineNow == nil {
            timelineNow = ProcessInfo.processInfo.systemUptime
        }
        let step = max(0.0, deltaTime)
        if step > 0.0 {
            timelineNow = currentTime() + step
        }
        let now = currentTime()

        var required: CInt = 0
        let queryRC = aether_flip_runtime_tick(nativeRuntime, now, nil, &required)
        guard queryRC == 0 || queryRC == -3 else {
            return []
        }
        guard required > 0 else {
            return []
        }

        var angles = [Float](repeating: 0.0, count: Int(required))
        var capacity = required
        let rc = angles.withUnsafeMutableBufferPointer { angleBuffer in
            aether_flip_runtime_tick(
                nativeRuntime,
                now,
                angleBuffer.baseAddress,
                &capacity
            )
        }
        guard rc == 0 else {
            return []
        }
        return Array(angles.prefix(Int(capacity)))
    }

    public func getFlipAngles(for triangleIndices: [Int]) -> [Float] {
        guard let nativeRuntime, !triangleIndices.isEmpty else {
            return Array(repeating: 0.0, count: triangleIndices.count)
        }
        var ids32 = triangleIndices.map(Int32.init)
        var angles = Array(repeating: Float(0.0), count: triangleIndices.count)
        let now = currentTime()
        let rc = ids32.withUnsafeMutableBufferPointer { idBuffer in
            angles.withUnsafeMutableBufferPointer { angleBuffer in
                aether_flip_runtime_sample(
                    nativeRuntime,
                    idBuffer.baseAddress,
                    CInt(triangleIndices.count),
                    now,
                    angleBuffer.baseAddress,
                    nil,
                    nil
                )
            }
        }
        guard rc == 0 else {
            return Array(repeating: 0.0, count: triangleIndices.count)
        }
        return angles
    }

    public func getFlipAxis(for triangleIndex: Int) -> (origin: SIMD3<Float>, direction: SIMD3<Float>)? {
        guard let nativeRuntime else {
            return nil
        }
        var triangleId: Int32 = Int32(triangleIndex)
        var angle: Float = 0
        var origin = aether_float3_t()
        var direction = aether_float3_t()
        let rc = withUnsafeMutablePointer(to: &triangleId) { idPtr in
            withUnsafeMutablePointer(to: &angle) { anglePtr in
                withUnsafeMutablePointer(to: &origin) { originPtr in
                    withUnsafeMutablePointer(to: &direction) { directionPtr in
                        aether_flip_runtime_sample(
                            nativeRuntime,
                            idPtr,
                            1,
                            currentTime(),
                            anglePtr,
                            originPtr,
                            directionPtr
                        )
                    }
                }
            }
        }
        guard rc == 0 else {
            return nil
        }
        let dir = SIMD3<Float>(direction.x, direction.y, direction.z)
        if simd_length_squared(dir) <= 1e-12 {
            return nil
        }
        return (SIMD3<Float>(origin.x, origin.y, origin.z), dir)
    }

    public static func easingWithOvershoot(t: Float) -> Float {
        guard var cfg = makeNativeRuntimeConfig()?.easing else {
            return max(0.0, min(1.0, t))
        }
        let clamped = max(0.0, min(1.0, t))
        let native = aether_flip_easing(clamped, &cfg)
        if native.isFinite {
            return native
        }
        return clamped
    }

    public func reset() {
        previousDisplay.removeAll()
        timelineNow = nil
        if let nativeRuntime {
            _ = aether_flip_runtime_reset(nativeRuntime)
        }
    }

    private func stablePatchKey(_ patchId: String) -> UInt64 {
        let bytes = Array(patchId.utf8)
        let count = Int32(min(bytes.count, Int(Int32.max)))
        var hash: UInt64 = 0
        let rc = bytes.withUnsafeBufferPointer { buffer in
            aether_hash_fnv1a64(
                buffer.baseAddress,
                count,
                &hash
            )
        }
        if rc == 0 {
            return hash
        }
        var fallback: UInt64 = BridgeInteropConstants.fnv1a64OffsetBasis
        for byte in bytes {
            fallback ^= UInt64(byte)
            fallback &*= BridgeInteropConstants.fnv1a64Prime
        }
        return fallback
    }
}
