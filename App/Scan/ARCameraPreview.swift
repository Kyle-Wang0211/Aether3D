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
#if canImport(MetalKit)
import MetalKit
#endif

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

        #if canImport(MetalKit)
        // Transparent Metal overlay for ScanGuidanceRenderPipeline output.
        if let device = MTLCreateSystemDefaultDevice() {
            let overlay = MTKView(frame: .zero, device: device)
            overlay.translatesAutoresizingMaskIntoConstraints = false
            overlay.clearColor = MTLClearColorMake(0, 0, 0, 0)
            overlay.colorPixelFormat = .bgra8Unorm
            overlay.depthStencilPixelFormat = .depth32Float
            overlay.isOpaque = false
            overlay.backgroundColor = .clear
            overlay.framebufferOnly = false
            overlay.enableSetNeedsDisplay = false
            overlay.isPaused = false
            overlay.preferredFramesPerSecond = 60
            overlay.isUserInteractionEnabled = false

            context.coordinator.configureOverlay(mtkView: overlay, device: device)
            arView.addSubview(overlay)
            NSLayoutConstraint.activate([
                overlay.leadingAnchor.constraint(equalTo: arView.leadingAnchor),
                overlay.trailingAnchor.constraint(equalTo: arView.trailingAnchor),
                overlay.topAnchor.constraint(equalTo: arView.topAnchor),
                overlay.bottomAnchor.constraint(equalTo: arView.bottomAnchor)
            ])
        }
        #endif

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
        #if canImport(MetalKit)
        private weak var overlayView: MTKView?
        private var overlayCommandQueue: MTLCommandQueue?
        private var overlayPipeline: ScanGuidanceRenderPipeline?
        #endif

        init(viewModel: ScanViewModel) {
            self.viewModel = viewModel
        }

        #if canImport(MetalKit)
        func configureOverlay(mtkView: MTKView, device: MTLDevice) {
            overlayView = mtkView
            overlayCommandQueue = device.makeCommandQueue()
            mtkView.delegate = self
        }
        #endif

        // ARSessionDelegate — called per frame (~60 FPS)
        func session(_ session: ARSession, didUpdate frame: ARFrame) {
            // Collect mesh anchors from current frame
            let meshAnchors = frame.anchors.compactMap { $0 as? ARMeshAnchor }
            #if os(iOS)
            let orientation = overlayView?.window?.windowScene?.interfaceOrientation ?? .portrait
            let viewportSize = overlayView?.drawableSize ?? CGSize(width: 1080, height: 1920)
            let viewMatrix = frame.camera.viewMatrix(for: orientation)
            let projectionMatrix = frame.camera.projectionMatrix(
                for: orientation,
                viewportSize: viewportSize,
                zNear: 0.001,
                zFar: 1000.0
            )
            #else
            let viewMatrix = simd_inverse(frame.camera.transform)
            let projectionMatrix = matrix_identity_float4x4
            #endif

            Task { @MainActor in
                viewModel.processARFrame(
                    frame: frame,
                    meshAnchors: meshAnchors,
                    viewMatrix: viewMatrix,
                    projectionMatrix: projectionMatrix
                )
                #if canImport(MetalKit)
                overlayPipeline = viewModel.currentRenderPipelineForOverlay()
                #endif
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

#if canImport(MetalKit)
extension ARCameraPreview.Coordinator: MTKViewDelegate {
    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}

    func draw(in view: MTKView) {
        guard let pipeline = overlayPipeline,
              let renderPass = view.currentRenderPassDescriptor,
              let drawable = view.currentDrawable else {
            return
        }
        if overlayCommandQueue == nil {
            overlayCommandQueue = view.device?.makeCommandQueue()
        }
        guard let queue = overlayCommandQueue,
              let commandBuffer = queue.makeCommandBuffer() else {
            return
        }
        pipeline.encode(into: commandBuffer, renderPassDescriptor: renderPass)
        commandBuffer.present(drawable)
        commandBuffer.commit()
    }
}
#endif

#endif
