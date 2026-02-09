//
// EvidenceRenderer.swift
// Aether3D
//
// PR#7 Scan Guidance UI — Evidence Renderer
// SwiftUI view replacing HeatCoolCoverageView
//
// NOTE: This file is in App/ directory and will not compile with SwiftPM.
// It will be compiled only via Xcode project on iOS/macOS.
//

#if canImport(SwiftUI)
import SwiftUI
import Foundation

#if canImport(MetalKit)
import MetalKit
#endif

/// SwiftUI view for rendering scan guidance evidence
/// Replaces HeatCoolCoverageView in GuidanceRenderer
/// Phase 6: Connected to Metal rendering pipeline
public struct EvidenceRenderer: View {
    
    #if canImport(MetalKit)
    @StateObject private var metalView = MetalRenderView()
    #endif
    
    public init() {}
    
    public var body: some View {
        #if canImport(MetalKit)
        MetalRenderView()
            .drawingGroup()  // Metal acceleration
        #else
        // Fallback: Empty view if Metal unavailable
        EmptyView()
        #endif
    }
}

#if canImport(MetalKit)
/// Metal render view for scan guidance
private class MetalRenderView: NSObject, ObservableObject {
    // Metal rendering will be handled by ScanGuidanceRenderPipeline
    // This is a placeholder for Phase 6 integration
}
#endif

#endif
