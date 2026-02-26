//
// EnvironmentLightEstimator.swift
// Aether3D
//
// PR#7 Scan Guidance UI — Environment Light Estimator
// Apple-platform only (ARKit)
// Phase 3: Full implementation
//

import Foundation
#if canImport(simd)
import simd
#endif

#if canImport(ARKit)
import ARKit
#endif

#if canImport(Vision)
import Vision
#endif

/// Light estimation tier
public enum EstimationTier: Int, Sendable {
    case arkit = 0
    case vision = 1
    case fallback = 2
}

/// Light state for rendering
public struct LightState: Sendable {
    public let direction: SIMD3<Float>
    public let intensity: Float
    public let shCoeffs: [SIMD3<Float>]  // 9 coefficients for L2 SH
    public let tier: EstimationTier
    
    public init(
        direction: SIMD3<Float>,
        intensity: Float,
        shCoeffs: [SIMD3<Float>],
        tier: EstimationTier
    ) {
        self.direction = direction
        self.intensity = intensity
        self.shCoeffs = shCoeffs
        self.tier = tier
    }
}

public struct LightEstimateSnapshot: Sendable {
    public let ambientIntensity: Float
    public let primaryLightDirection: SIMD3<Float>?
    public let sphericalHarmonicsCoefficients: [SIMD3<Float>]?

    public init(
        ambientIntensity: Float,
        primaryLightDirection: SIMD3<Float>? = nil,
        sphericalHarmonicsCoefficients: [SIMD3<Float>]? = nil
    ) {
        self.ambientIntensity = ambientIntensity
        self.primaryLightDirection = primaryLightDirection
        self.sphericalHarmonicsCoefficients = sphericalHarmonicsCoefficients
    }
}

public final class EnvironmentLightEstimator {
    
    /// Fallback light direction (upward)
    public static let fallbackDirection = SIMD3<Float>(0.0, 1.0, 0.0)
    
    /// Fallback light intensity
    public static let fallbackIntensity: Float = 1.0
    
    public init() {}
    
    /// Update light estimation with 3-tier fallback
    ///
    /// Tier 1: ARKit light estimate (if available)
    /// Tier 2: Vision framework (if ARKit unavailable)
    /// Tier 3: Fallback (default upward light)
    ///
    /// - Parameters:
    ///   - lightEstimate: ARKit ARLightEstimate (optional)
    ///   - cameraImage: Camera image for Vision framework (optional)
    ///   - timestamp: Current timestamp
    /// - Returns: LightState with direction, intensity, SH coefficients, and tier
    public func update(
        lightEstimate: Any?,
        cameraImage: Any?,
        timestamp: TimeInterval
    ) -> LightState {
        if let snapshot = lightEstimate as? LightEstimateSnapshot {
            return extractSnapshotLight(snapshot: snapshot)
        }

        // Tier 1: Try ARKit light estimate
        #if canImport(ARKit)
        if let arkitEstimate = lightEstimate as? ARLightEstimate {
            return extractARKitLight(estimate: arkitEstimate)
        }
        #endif
        
        // Tier 2: Try Vision framework
        #if canImport(Vision)
        if let image = cameraImage {
            if let visionLight = extractVisionLight(image: image) {
                return visionLight
            }
        }
        #endif
        
        // Tier 3: Fallback
        return createFallbackLight()
    }
    
    #if canImport(ARKit)
    /// Extract light from ARKit ARLightEstimate
    private func extractARKitLight(estimate: ARLightEstimate) -> LightState {
        // ARKit provides ambient intensity and primary light direction
        let intensity = Float(estimate.ambientIntensity)

        // Primary light direction (available on ARDirectionalLightEstimate only)
        var direction = Self.fallbackDirection
        if let directional = estimate as? ARDirectionalLightEstimate {
            let dir = directional.primaryLightDirection
            direction = SIMD3<Float>(
                Float(dir.x),
                Float(dir.y),
                Float(dir.z)
            )
        }

        // Convert ARKit SH coefficients to our format (9 × RGB)
        var shCoeffs: [SIMD3<Float>] = Array(repeating: SIMD3<Float>(0.0, 0.0, 0.0), count: 9)

        // ARDirectionalLightEstimate provides spherical harmonics coefficients (Data, 27 floats = 9 × RGB)
        if let directional = estimate as? ARDirectionalLightEstimate {
            let data = directional.sphericalHarmonicsCoefficients
            let floatCount = data.count / MemoryLayout<Float>.size
            if floatCount >= 27 {
                data.withUnsafeBytes { ptr in
                    let floats = ptr.bindMemory(to: Float.self)
                    for i in 0..<9 {
                        shCoeffs[i] = SIMD3<Float>(floats[i * 3], floats[i * 3 + 1], floats[i * 3 + 2])
                    }
                }
            }
        } else {
            // Fallback: ambient-only SH
            shCoeffs[0] = SIMD3<Float>(intensity, intensity, intensity)
        }
        
        return LightState(
            direction: direction,
            intensity: intensity,
            shCoeffs: shCoeffs,
            tier: .arkit
        )
    }
    #endif

    private func extractSnapshotLight(snapshot: LightEstimateSnapshot) -> LightState {
        let intensity = max(snapshot.ambientIntensity, 0.0)
        let direction = snapshot.primaryLightDirection ?? Self.fallbackDirection

        var shCoeffs: [SIMD3<Float>] = Array(repeating: SIMD3<Float>(0.0, 0.0, 0.0), count: 9)
        if let provided = snapshot.sphericalHarmonicsCoefficients, !provided.isEmpty {
            let count = min(9, provided.count)
            for index in 0..<count {
                shCoeffs[index] = provided[index]
            }
        } else {
            shCoeffs[0] = SIMD3<Float>(intensity, intensity, intensity)
        }

        return LightState(
            direction: direction,
            intensity: intensity,
            shCoeffs: shCoeffs,
            tier: .arkit
        )
    }
    
    #if canImport(Vision)
    /// Extract light from Vision framework (simplified)
    private func extractVisionLight(image: Any) -> LightState? {
        // Vision framework light estimation would go here
        // For now, return nil to fall back to fallback tier
        // This is a placeholder for Phase 3 - full Vision implementation would analyze
        // the camera image to estimate lighting conditions
        return nil
    }
    #endif
    
    /// Create fallback light state
    private func createFallbackLight() -> LightState {
        var fallbackSH: [SIMD3<Float>] = Array(repeating: SIMD3<Float>(0.0, 0.0, 0.0), count: 9)
        // L0 (ambient) coefficient: uniform white light
        fallbackSH[0] = SIMD3<Float>(Self.fallbackIntensity, Self.fallbackIntensity, Self.fallbackIntensity)
        
        return LightState(
            direction: Self.fallbackDirection,
            intensity: Self.fallbackIntensity,
            shCoeffs: fallbackSH,
            tier: .fallback
        )
    }
}
