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
/// Primary rendering path: ARSCNView delegate (ScanView → ARCameraPreview)
/// This view: fallback for non-AR contexts or preview mode
public struct EvidenceRenderer: View {
    
    public init() {}
    
    public var body: some View {
        #if canImport(MetalKit)
        GeometryReader { geometry in
            // Metal rendering is handled by ScanGuidanceRenderPipeline
            // injected via ARSCNView delegate in the primary AR path.
            // This view provides a placeholder for non-AR preview contexts.
            ZStack {
                Color.black
                Text("Metal Renderer Active")
                    .font(.system(size: 12))
                    .foregroundColor(.gray.opacity(0.3))
            }
        }
        #else
        EmptyView()
        #endif
    }
}

#endif
