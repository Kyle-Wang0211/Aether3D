//
// RipplePropagationEngine.swift
// Aether3D
//
// PR#7 Scan Guidance UI — Ripple Propagation Engine
// Runtime ripple state machine is delegated to core C++ runtime.
//

import Foundation
import CAetherNativeBridge

public final class RipplePropagationEngine {
    private let nativeRuntime: OpaquePointer?

    private var nativeAdjacencyOffsets: [UInt32] = []
    private var nativeAdjacencyNeighbors: [UInt32] = []
    private var nativeTriangleCount: Int = 0

    private static func makeNativeRuntimeConfig() -> aether_ripple_runtime_config_t? {
        var config = aether_ripple_runtime_config_t()
        guard aether_ripple_runtime_default_config(&config) == 0 else {
            return nil
        }
        config.ripple.damping = Float(ScanGuidanceConstants.rippleDampingPerHop)
        config.ripple.max_hops = Int32(ScanGuidanceConstants.rippleMaxHops)
        config.ripple.delay_per_hop_s = Float(ScanGuidanceConstants.rippleDelayPerHopS)
        config.max_concurrent_waves = Int32(ScanGuidanceConstants.rippleMaxConcurrentWaves)
        config.min_spawn_interval_s = Double(ScanGuidanceConstants.rippleMinSpawnIntervalS)
        return config
    }

    public init() {
        guard var config = Self.makeNativeRuntimeConfig() else {
            self.nativeRuntime = nil
            return
        }
        var runtime: OpaquePointer?
        if aether_ripple_runtime_create(&config, &runtime) == 0 {
            self.nativeRuntime = runtime
        } else {
            self.nativeRuntime = nil
        }
    }

    deinit {
        if let nativeRuntime {
            _ = aether_ripple_runtime_destroy(nativeRuntime)
        }
    }

    private func refreshNativeAdjacency(from adjacencyGraph: any AdjacencyProvider) {
        let triangleCount = max(0, adjacencyGraph.triangleCount)
        nativeTriangleCount = triangleCount
        guard triangleCount > 0 else {
            nativeAdjacencyOffsets = []
            nativeAdjacencyNeighbors = []
            if let nativeRuntime {
                _ = aether_ripple_runtime_set_adjacency(
                    nativeRuntime,
                    nil,
                    nil,
                    0
                )
            }
            return
        }

        var offsets = [UInt32](repeating: 0, count: triangleCount + 1)
        var neighbors: [UInt32] = []
        neighbors.reserveCapacity(triangleCount * 3)

        for triIndex in 0..<triangleCount {
            offsets[triIndex] = UInt32(neighbors.count)
            let row = adjacencyGraph.neighbors(of: triIndex).sorted()
            var previousNeighbor: Int?
            for neighbor in row where neighbor >= 0 && neighbor < triangleCount {
                if previousNeighbor == neighbor {
                    continue
                }
                neighbors.append(UInt32(neighbor))
                previousNeighbor = neighbor
            }
        }
        offsets[triangleCount] = UInt32(neighbors.count)

        nativeAdjacencyOffsets = offsets
        nativeAdjacencyNeighbors = neighbors

        guard let nativeRuntime else {
            return
        }
        let rc = nativeAdjacencyOffsets.withUnsafeBufferPointer { offsetsBuffer in
            nativeAdjacencyNeighbors.withUnsafeBufferPointer { neighborsBuffer in
                aether_ripple_runtime_set_adjacency(
                    nativeRuntime,
                    offsetsBuffer.baseAddress,
                    neighborsBuffer.baseAddress,
                    CInt(triangleCount)
                )
            }
        }
        if rc != 0 {
            nativeTriangleCount = 0
            nativeAdjacencyOffsets = []
            nativeAdjacencyNeighbors = []
        }
    }

    public func spawn(
        sourceTriangle: Int,
        adjacencyGraph: any AdjacencyProvider,
        timestamp: TimeInterval
    ) {
        guard let nativeRuntime else {
            return
        }
        refreshNativeAdjacency(from: adjacencyGraph)
        _ = aether_ripple_runtime_spawn(
            nativeRuntime,
            Int32(sourceTriangle),
            timestamp,
            nil
        )
    }

    public func tick(currentTime: TimeInterval) -> [Float] {
        guard let nativeRuntime else {
            return [Float](repeating: 0.0, count: nativeTriangleCount)
        }
        var required: CInt = 0
        let queryRC = aether_ripple_runtime_tick(nativeRuntime, currentTime, nil, &required)
        guard queryRC == 0 || queryRC == -3 else {
            return [Float](repeating: 0.0, count: nativeTriangleCount)
        }
        guard required > 0 else {
            return []
        }
        var amplitudes = [Float](repeating: 0.0, count: Int(required))
        var capacity = required
        let rc = amplitudes.withUnsafeMutableBufferPointer { amplitudeBuffer in
            aether_ripple_runtime_tick(
                nativeRuntime,
                currentTime,
                amplitudeBuffer.baseAddress,
                &capacity
            )
        }
        guard rc == 0 else {
            return [Float](repeating: 0.0, count: Int(required))
        }
        return Array(amplitudes.prefix(Int(capacity)))
    }

    public func getRippleAmplitudes(for triangleIndices: [Int], currentTime: TimeInterval) -> [Float] {
        guard let nativeRuntime else {
            return Array(repeating: 0.0, count: triangleIndices.count)
        }
        guard !triangleIndices.isEmpty else {
            return []
        }
        var ids32 = triangleIndices.map(Int32.init)
        var amplitudes = Array(repeating: Float(0.0), count: triangleIndices.count)
        let rc = ids32.withUnsafeMutableBufferPointer { idBuffer in
            amplitudes.withUnsafeMutableBufferPointer { amplitudeBuffer in
                aether_ripple_runtime_sample(
                    nativeRuntime,
                    idBuffer.baseAddress,
                    CInt(triangleIndices.count),
                    currentTime,
                    amplitudeBuffer.baseAddress
                )
            }
        }
        guard rc == 0 else {
            return Array(repeating: 0.0, count: triangleIndices.count)
        }
        return amplitudes
    }

    public func reset() {
        nativeAdjacencyOffsets.removeAll()
        nativeAdjacencyNeighbors.removeAll()
        nativeTriangleCount = 0
        if let nativeRuntime {
            _ = aether_ripple_runtime_reset(nativeRuntime)
        }
    }
}
