//
// ThermalQualityAdapter.swift
// Aether3D
//
// PR#7 Scan Guidance UI — Thermal Quality Adapter
// Pure algorithm — Foundation only, NO QuartzCore/Metal
// v7.0.1: Renamed QualityTier→RenderTier to avoid clash with existing QualityTier
// v7.0.1: Uses ProcessInfo.processInfo.systemUptime instead of CACurrentMediaTime()
// v7.0.2: ProcessInfo.ThermalState wrapped in #if os(iOS) || os(macOS)
//

import Foundation

public final class ThermalQualityAdapter {

    /// Render quality tiers (v7.0.1: renamed from QualityTier to avoid clash)
    public enum RenderTier: Int, CaseIterable, Sendable {
        case nominal = 0
        case fair = 1
        case serious = 2
        case critical = 3

        public var lodLevel: WedgeGeometryGenerator.LODLevel {
            switch self {
            case .nominal:  return .full
            case .fair:     return .medium
            case .serious:  return .low
            case .critical: return .flat
            }
        }

        public var maxTriangles: Int {
            switch self {
            case .nominal:  return ScanGuidanceConstants.thermalNominalMaxTriangles
            case .fair:     return ScanGuidanceConstants.thermalFairMaxTriangles
            case .serious:  return ScanGuidanceConstants.thermalSeriousMaxTriangles
            case .critical: return ScanGuidanceConstants.thermalCriticalMaxTriangles
            }
        }

        public var targetFPS: Int {
            switch self {
            case .nominal:  return 60
            case .fair:     return 60
            case .serious:  return 30
            case .critical: return 24
            }
        }

        public var enableFlipAnimation: Bool { self.rawValue <= 1 }
        public var enableRipple: Bool { self.rawValue <= 1 }
        public var enableMetallicBRDF: Bool { self.rawValue <= 1 }
        public var enableHaptics: Bool { self.rawValue <= 2 }
    }

    public private(set) var currentTier: RenderTier = .nominal

    private var lastTierChangeTime: TimeInterval = 0
    private var frameTimeSamples: [Double] = []

    /// v7.0.1: Cross-platform time source
    private func currentTime() -> TimeInterval {
        ProcessInfo.processInfo.systemUptime
    }

    public func updateThermalState(_ state: ProcessInfo.ThermalState) {
        #if os(iOS) || os(macOS)
        let targetTier: RenderTier
        switch state {
        case .nominal:  targetTier = .nominal
        case .fair:     targetTier = .fair
        case .serious:  targetTier = .serious
        case .critical: targetTier = .critical
        @unknown default: targetTier = .fair
        }
        let now = currentTime()
        if targetTier != currentTier && (now - lastTierChangeTime) > ScanGuidanceConstants.thermalHysteresisS {
            currentTier = targetTier
            lastTierChangeTime = now
        }
        #endif
    }

    public func updateFrameTiming(gpuDurationMs: Double) {
        frameTimeSamples.append(gpuDurationMs)
        if frameTimeSamples.count > ScanGuidanceConstants.frameBudgetWindowFrames {
            frameTimeSamples.removeFirst()
        }
        let targetMs = 1000.0 / Double(currentTier.targetFPS)
        let threshold = targetMs * ScanGuidanceConstants.frameBudgetOvershootRatio
        let sorted = frameTimeSamples.sorted()
        let p95Index = Int(Double(sorted.count) * 0.95)
        let p95 = sorted[min(p95Index, sorted.count - 1)]
        if p95 > threshold {
            let nextTier = RenderTier(rawValue: min(currentTier.rawValue + 1, 3))!
            let now = currentTime()
            if (now - lastTierChangeTime) > ScanGuidanceConstants.thermalHysteresisS {
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
