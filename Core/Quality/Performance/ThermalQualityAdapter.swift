//
// ThermalQualityAdapter.swift
// Aether3D
//
// Thermal Quality Adapter — maps ProcessInfo.ThermalState to render quality tier.
// Pure algorithm — Foundation only, NO QuartzCore/Metal.
// Unified pipeline: no longer drives wedge LOD (removed with wedge system).
//

import Foundation

public final class ThermalQualityAdapter {

    /// Render quality tiers (unified point cloud + OIR pipeline)
    public enum RenderTier: Int, CaseIterable, Sendable {
        case nominal = 0
        case fair = 1
        case serious = 2
        case critical = 3

        public var targetFPS: Int {
            switch self {
            case .nominal:  return 60
            case .fair:     return 60
            case .serious:  return 30
            case .critical: return 24
            }
        }

        /// Enable haptic feedback at this tier
        public var enableHaptics: Bool { self.rawValue <= 2 }

        /// Training rate multiplier for C++ MAESTRO thermal management
        public var trainingRate: Float {
            switch self {
            case .nominal:  return 1.0
            case .fair:     return 0.7
            case .serious:  return 0.3
            case .critical: return 0.0
            }
        }
    }

    // ─── Inlined constants (formerly in ScanGuidanceConstants) ───
    private static let thermalHysteresisS: Double = 10.0
    private static let frameBudgetWindowFrames: Int = 30
    private static let frameBudgetOvershootRatio: Double = 1.2

    public private(set) var currentTier: RenderTier = .nominal

    public init() {}

    private var lastTierChangeTime: TimeInterval = 0
    private var frameTimeSamples: [Double] = []

    private func currentTime() -> TimeInterval {
        ProcessInfo.processInfo.systemUptime
    }

    #if os(iOS) || os(macOS)
    public func updateThermalState(_ state: ProcessInfo.ThermalState) {
        let targetTier: RenderTier
        switch state {
        case .nominal:  targetTier = .nominal
        case .fair:     targetTier = .fair
        case .serious:  targetTier = .serious
        case .critical: targetTier = .critical
        @unknown default: targetTier = .fair
        }
        let now = currentTime()
        if targetTier != currentTier && (now - lastTierChangeTime) > Self.thermalHysteresisS {
            currentTier = targetTier
            lastTierChangeTime = now
        }
    }
    #endif

    public func updateFrameTiming(gpuDurationMs: Double) {
        frameTimeSamples.append(gpuDurationMs)
        if frameTimeSamples.count > Self.frameBudgetWindowFrames {
            frameTimeSamples.removeFirst()
        }
        let targetMs = 1000.0 / Double(currentTier.targetFPS) // LINT:ALLOW
        let threshold = targetMs * Self.frameBudgetOvershootRatio
        let sorted = frameTimeSamples.sorted()
        let p95Index = Int(Double(sorted.count) * 0.95)
        let p95 = sorted[min(p95Index, sorted.count - 1)]
        if p95 > threshold {
            let nextTier = RenderTier(rawValue: min(currentTier.rawValue + 1, 3))!
            let now = currentTime()
            if (now - lastTierChangeTime) > Self.thermalHysteresisS {
                currentTier = nextTier
                lastTierChangeTime = now
            }
        }
    }

    public func forceRenderTier(_ tier: RenderTier) {
        currentTier = tier
        lastTierChangeTime = currentTime()
    }
}
