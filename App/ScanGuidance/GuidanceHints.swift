//
// GuidanceHints.swift
// Aether3D
//
// PR#7 Scan Guidance UI — Directional Guidance Hints
// Apple-platform only (SwiftUI)
// Phase 4: Full implementation
//

import Foundation

#if canImport(SwiftUI)
import SwiftUI
#endif

#if canImport(simd)
import simd
#endif

/// Directional affordance hints for scan guidance
public struct GuidanceHints {
    
    /// Direction vector (normalized)
    public let direction: SIMD3<Float>
    
    /// Hint intensity [0, 1]
    public let intensity: Float
    
    public init(direction: SIMD3<Float>, intensity: Float) {
        self.direction = direction
        self.intensity = intensity
    }
}

#if canImport(SwiftUI)
/// SwiftUI view for directional hints
public struct DirectionalAffordanceView: View {
    let hints: GuidanceHints
    
    public var body: some View {
        GeometryReader { geometry in
            arrowPath(in: geometry.size)
                .fill(Color.white.opacity(Double(hints.intensity)))
        }
    }

    private func arrowPath(in size: CGSize) -> Path {
        let centerX: CGFloat = size.width / 2
        let centerY: CGFloat = size.height / 2
        let screenDir = projectToScreen(direction: hints.direction)
        let angle: CGFloat = CGFloat(atan2(screenDir.y, screenDir.x))
        let arrowLength: CGFloat = 30 * CGFloat(hints.intensity)
        let arrowWidth: CGFloat = 15

        let tipX: CGFloat = centerX + cos(angle) * arrowLength
        let tipY: CGFloat = centerY + sin(angle) * arrowLength
        let baseX: CGFloat = centerX - cos(angle) * arrowLength * 0.5
        let baseY: CGFloat = centerY - sin(angle) * arrowLength * 0.5
        let leftWingX: CGFloat = baseX + cos(angle + .pi / 2) * arrowWidth
        let leftWingY: CGFloat = baseY + sin(angle + .pi / 2) * arrowWidth
        let rightWingX: CGFloat = baseX + cos(angle - .pi / 2) * arrowWidth
        let rightWingY: CGFloat = baseY + sin(angle - .pi / 2) * arrowWidth

        var path = Path()
        path.move(to: CGPoint(x: tipX, y: tipY))
        path.addLine(to: CGPoint(x: leftWingX, y: leftWingY))
        path.addLine(to: CGPoint(x: baseX, y: baseY))
        path.addLine(to: CGPoint(x: rightWingX, y: rightWingY))
        path.closeSubpath()
        return path
    }
    
    /// Project 3D direction to 2D screen space
    private func projectToScreen(direction: SIMD3<Float>) -> SIMD2<Float> {
        // Simple projection: ignore Z, use X and Y
        return SIMD2<Float>(direction.x, direction.y)
    }
}
#endif
