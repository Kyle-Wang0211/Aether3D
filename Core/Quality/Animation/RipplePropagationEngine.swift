//
// RipplePropagationEngine.swift
// Aether3D
//
// PR#7 Scan Guidance UI — Ripple Propagation Engine
// Pure algorithm — Foundation only
// Phase 3: Full implementation
//

import Foundation

/// Ripple wave state
private struct RippleWave {
    /// Source triangle index
    let sourceIndex: Int
    
    /// Spawn timestamp
    let spawnTime: TimeInterval
    
    /// Current hop distances (triangle index → hop count)
    var hopDistances: [Int: Int]
    
    init(sourceIndex: Int, spawnTime: TimeInterval) {
        self.sourceIndex = sourceIndex
        self.spawnTime = spawnTime
        self.hopDistances = [sourceIndex: 0]
    }
}

public final class RipplePropagationEngine {
    
    /// Active ripple waves
    private var activeWaves: [RippleWave] = []
    
    /// Last spawn time per source (for debouncing)
    private var lastSpawnTimes: [Int: TimeInterval] = [:]
    
    /// Current time source (cross-platform)
    private func currentTime() -> TimeInterval {
        ProcessInfo.processInfo.systemUptime
    }
    
    public init() {}
    
    /// Spawn a ripple wave from a source triangle
    ///
    /// - Parameters:
    ///   - sourceTriangle: Source triangle index
    ///   - adjacencyGraph: Mesh adjacency graph for BFS
    ///   - timestamp: Current timestamp
    public func spawn(
        sourceTriangle: Int,
        adjacencyGraph: MeshAdjacencyGraph,
        timestamp: TimeInterval
    ) {
        // Check max concurrent waves
        if activeWaves.count >= ScanGuidanceConstants.rippleMaxConcurrentWaves {
            return
        }
        
        // Check min spawn interval (debounce)
        if let lastSpawn = lastSpawnTimes[sourceTriangle] {
            let elapsed = timestamp - lastSpawn
            if elapsed < ScanGuidanceConstants.rippleMinSpawnIntervalS {
                return
            }
        }
        
        // Create new wave
        var wave = RippleWave(sourceIndex: sourceTriangle, spawnTime: timestamp)
        
        // Initialize BFS distances from source
        let distances = adjacencyGraph.bfsDistances(
            from: sourceTriangle,
            maxHops: ScanGuidanceConstants.rippleMaxHops
        )
        wave.hopDistances = distances
        
        activeWaves.append(wave)
        lastSpawnTimes[sourceTriangle] = timestamp
    }
    
    /// Tick ripple propagation and return per-triangle amplitudes
    ///
    /// - Parameter currentTime: Current timestamp
    /// - Returns: Array of amplitudes [0, 1] for each triangle (indexed by triangle index)
    public func tick(currentTime: TimeInterval) -> [Float] {
        var amplitudes: [Int: Float] = [:]
        
        // Update active waves
        var completedWaves: [Int] = []
        for (waveIndex, wave) in activeWaves.enumerated() {
            let elapsed = currentTime - wave.spawnTime
            
            // Calculate amplitudes for this wave
            for (triIndex, hopCount) in wave.hopDistances {
                // Time delay per hop
                let hopDelay = Double(hopCount) * ScanGuidanceConstants.rippleDelayPerHopS
                
                if elapsed < hopDelay {
                    // Wave hasn't reached this triangle yet
                    continue
                }
                
                // Amplitude decay: damping^hopCount
                let damping = ScanGuidanceConstants.rippleDampingPerHop
                let baseAmplitude = pow(damping, Double(hopCount))
                
                // Wave envelope (sine wave with decay)
                let localTime = elapsed - hopDelay
                let wavePeriod = ScanGuidanceConstants.rippleDelayPerHopS * 2.0  // 2x hop delay
                let phase = (localTime / wavePeriod) * 2.0 * Double.pi
                let envelope = 0.5 * (1.0 + cos(phase))  // [0, 1] envelope
                
                // Combine amplitude and envelope
                let amplitude = Float(baseAmplitude * envelope)
                
                // Take maximum amplitude if multiple waves overlap
                if let existing = amplitudes[triIndex] {
                    amplitudes[triIndex] = max(existing, amplitude)
                } else {
                    amplitudes[triIndex] = amplitude
                }
            }
            
            // Check if wave is complete (all triangles have been reached and decayed)
            let maxHop = wave.hopDistances.values.max() ?? 0
            let wavePeriod = ScanGuidanceConstants.rippleDelayPerHopS * 2.0
            let maxWaveTime = Double(maxHop) * ScanGuidanceConstants.rippleDelayPerHopS + wavePeriod
            if elapsed > maxWaveTime {
                completedWaves.append(waveIndex)
            }
        }
        
        // Remove completed waves (reverse order to maintain indices)
        for waveIndex in completedWaves.reversed() {
            activeWaves.remove(at: waveIndex)
        }
        
        // Return amplitudes array (all triangles, 0.0 for non-rippling)
        // Note: Caller needs to know triangle count to create full array
        return Array(amplitudes.values)
    }
    
    /// Get ripple amplitudes for specific triangle indices
    ///
    /// - Parameters:
    ///   - triangleIndices: Array of triangle indices to query
    ///   - currentTime: Current timestamp
    /// - Returns: Array of amplitudes corresponding to triangleIndices
    public func getRippleAmplitudes(for triangleIndices: [Int], currentTime: TimeInterval) -> [Float] {
        var amplitudes: [Int: Float] = [:]
        
        for wave in activeWaves {
            let elapsed = currentTime - wave.spawnTime
            
            for (triIndex, hopCount) in wave.hopDistances {
                guard triangleIndices.contains(triIndex) else {
                    continue
                }
                
                let hopDelay = Double(hopCount) * ScanGuidanceConstants.rippleDelayPerHopS
                
                if elapsed < hopDelay {
                    continue
                }
                
                let damping = ScanGuidanceConstants.rippleDampingPerHop
                let baseAmplitude = pow(damping, Double(hopCount))
                
                let localTime = elapsed - hopDelay
                let wavePeriod = ScanGuidanceConstants.rippleDelayPerHopS * 2.0
                let phase = (localTime / wavePeriod) * 2.0 * Double.pi
                let envelope = 0.5 * (1.0 + cos(phase))
                
                let amplitude = Float(baseAmplitude * envelope)
                
                if let existing = amplitudes[triIndex] {
                    amplitudes[triIndex] = max(existing, amplitude)
                } else {
                    amplitudes[triIndex] = amplitude
                }
            }
        }
        
        return triangleIndices.map { amplitudes[$0] ?? 0.0 }
    }
    
    /// Clear all active waves
    public func reset() {
        activeWaves.removeAll()
        lastSpawnTimes.removeAll()
    }
}
