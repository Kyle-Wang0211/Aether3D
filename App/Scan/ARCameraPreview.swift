//
// ARCameraPreview.swift
// Aether3D
//
// PR#7 Scan Guidance UI — AR Camera Preview
// UIViewRepresentable wrapping ARSCNView with delegate forwarding
// Apple-platform only (ARKit + SwiftUI)
//

import Foundation

#if canImport(ARKit) && canImport(SwiftUI)
import SwiftUI
import ARKit
import SceneKit

/// UIViewRepresentable wrapping ARSCNView
///
/// Architecture:
///   - ARSCNView handles real-time camera + SceneKit rendering
///   - Coordinator acts as both ARSCNViewDelegate and ARSessionDelegate
///   - Per-frame ARSession delegate forwards to ScanViewModel.processARFrame()
///   - Metal mesh overlay will be injected via ARSCNView delegate (future PR)
///
/// Safety:
///   - supportsSceneReconstruction(.mesh) check before enabling LiDAR mesh
///   - dismantleUIView pauses AR session (prevents resource leak)
///   - sessionWasInterrupted auto-pauses capture (phone call safety)
///   - session(didFailWithError:) transitions to .failed (prevents stuck state)
///   - Task { @MainActor } for ALL delegate→ViewModel calls (thread safety)
struct ARCameraPreview: UIViewRepresentable {
    @ObservedObject var viewModel: ScanViewModel

    func makeUIView(context: Context) -> ARSCNView {
        let arView = ARSCNView()
        arView.delegate = context.coordinator
        arView.session.delegate = context.coordinator
        arView.automaticallyUpdatesLighting = true
        arView.rendersCameraGrain = false
        arView.debugOptions = []  // No debug overlay in production

        // Configure AR session
        let configuration = ARWorldTrackingConfiguration()
        if ARWorldTrackingConfiguration.supportsSceneReconstruction(.mesh) {
            configuration.sceneReconstruction = .mesh
        }
        configuration.environmentTexturing = .automatic
        configuration.isLightEstimationEnabled = true

        // Enable per-frame depth map for TSDF fusion (PR#6 dependency)
        // sceneDepth provides 256×192 depth CVPixelBuffer at 60fps on LiDAR devices
        if ARWorldTrackingConfiguration.supportsFrameSemantics(.sceneDepth) {
            configuration.frameSemantics.insert(.sceneDepth)
        }

        // Start session
        arView.session.run(configuration, options: [.resetTracking, .removeExistingAnchors])

        // Notify ViewModel that ARKit is ready
        Task { @MainActor in
            viewModel.transition(to: .ready)
        }

        return arView
    }

    func updateUIView(_ uiView: ARSCNView, context: Context) {
        // No dynamic updates needed — delegate handles everything
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(viewModel: viewModel)
    }

    static func dismantleUIView(_ uiView: ARSCNView, coordinator: Coordinator) {
        uiView.session.pause()
    }

    // MARK: - Coordinator

    /// Bridges ARKit delegate callbacks to ScanViewModel
    class Coordinator: NSObject, ARSCNViewDelegate, ARSessionDelegate {
        let viewModel: ScanViewModel

        init(viewModel: ScanViewModel) {
            self.viewModel = viewModel
        }

        // ARSessionDelegate — called per frame (~60 FPS)
        func session(_ session: ARSession, didUpdate frame: ARFrame) {
            // Collect mesh anchors from current frame
            let meshAnchors = frame.anchors.compactMap { $0 as? ARMeshAnchor }

            Task { @MainActor in
                viewModel.processARFrame(
                    frame: frame,
                    meshAnchors: meshAnchors
                )
            }
        }

        // ARSession error handling
        func session(_ session: ARSession, didFailWithError error: Error) {
            Task { @MainActor in
                viewModel.transition(to: .failed)
            }
        }

        // Session interrupted (phone call, notification, etc.)
        func sessionWasInterrupted(_ session: ARSession) {
            Task { @MainActor in
                if viewModel.scanState.isActive {
                    viewModel.pauseCapture()
                }
            }
        }

        // Session interruption ended
        func sessionInterruptionEnded(_ session: ARSession) {
            // Session automatically resumes — user can tap to continue
        }
    }
}

#endif
