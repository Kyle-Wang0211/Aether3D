//
// GuidanceRenderer.swift
// Aether3D
//
// PR#1 C-Class SOFT/HARD LIMIT - Guidance Renderer
//
// No-text UX guidance signal rendering
//

import Foundation

#if canImport(SwiftUI)
import SwiftUI

/// Guidance renderer for no-text UX
/// 
/// **v2.3b Sealed:**
/// - MUST NOT use text as primary UX path
/// - All guidance must be conveyed via visual signals
public struct GuidanceRenderer {
    /// Render guidance signal
    /// 
    /// **MUST NOT use text:**
    /// - No toast/tooltips/status text about limits
    /// - No "please move slower/change angle" strings
    public static func render(_ signal: GuidanceSignal) -> some View {
        switch signal {
        case .HEAT_COOL_COVERAGE:
            return AnyView(HeatCoolCoverageView())
        case .DIRECTIONAL_AFFORDANCE:
            return AnyView(DirectionalAffordanceView())
        case .STATIC_OVERLAY:
            return AnyView(StaticOverlayView())
        case .NONE:
            return AnyView(EmptyView())
        }
    }
}

/// Heat/cool coverage visualization
/// Missing regions: hot colors (red/orange)
/// Redundant regions: cool colors (blue/gray)
/// Trend: redundant regions trend toward stillness
private struct HeatCoolCoverageView: View {
    var body: some View {
        // Placeholder: actual implementation would render heat/cool map
        // based on coverage state
        EmptyView()
    }
}

/// Directional affordance visualization
/// Arrow indicators, edge flow, boundary highlight
private struct DirectionalAffordanceView: View {
    var body: some View {
        // Placeholder: actual implementation would render arrows
        // and directional guidance
        EmptyView()
    }
}

/// Static overlay (SATURATED mode)
/// Camera remains operable
/// All evidence-related overlays freeze or cease updating
/// User perceives convergence from lack of new spatial feedback
private struct StaticOverlayView: View {
    var body: some View {
        // Placeholder: actual implementation would freeze overlays
        EmptyView()
    }
}

#else
/// Guidance renderer for no-text UX
/// 
/// **v2.3b Sealed:**
/// - MUST NOT use text as primary UX path
/// - All guidance must be conveyed via visual signals
public struct GuidanceRenderer {
    @available(*, unavailable, message: "GuidanceRenderer is only available on Apple platforms with SwiftUI.")
    public static func render(_ signal: GuidanceSignal) -> Never {
        fatalError("GuidanceRenderer requires SwiftUI")
    }
}
#endif
