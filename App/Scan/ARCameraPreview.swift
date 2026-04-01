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
@preconcurrency import SwiftUI
@preconcurrency import ARKit
import SceneKit
#if canImport(simd)
import simd
#endif

struct LightEstimateSnapshot: Sendable {
    let ambientIntensity: Float
    let primaryLightDirection: SIMD3<Float>?
    let sphericalHarmonicsCoefficients: [SIMD3<Float>]?

    init(
        ambientIntensity: Float,
        primaryLightDirection: SIMD3<Float>? = nil,
        sphericalHarmonicsCoefficients: [SIMD3<Float>]? = nil
    ) {
        self.ambientIntensity = ambientIntensity
        self.primaryLightDirection = primaryLightDirection
        self.sphericalHarmonicsCoefficients = sphericalHarmonicsCoefficients
    }
}

/// UIViewRepresentable wrapping ARSCNView
///
/// Architecture:
///   - ARSCNView handles real-time camera + SceneKit rendering
///   - Coordinator acts as both ARSCNViewDelegate and ARSessionDelegate
///   - Per-frame ARSession delegate forwards to ScanViewModel.processARFrame()
/// Safety:
///   - Camera feed remains clean; scan guidance is shown via HUD toasts/haptics only
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
        configuration.environmentTexturing = .automatic
        configuration.isLightEstimationEnabled = true

        // Enable per-frame depth map for TSDF fusion (PR#6 dependency)
        // sceneDepth provides 256×192 depth CVPixelBuffer at 60fps on LiDAR devices
        if ARWorldTrackingConfiguration.supportsFrameSemantics(.sceneDepth) {
            configuration.frameSemantics.insert(.sceneDepth)
        }

        // Start session
        arView.session.run(configuration, options: [.resetTracking, .removeExistingAnchors])

        // Capture blackout layer (camera feed blocker). Core policy decides visibility.
        let captureBlackout = UIView(frame: .zero)
        captureBlackout.translatesAutoresizingMaskIntoConstraints = false
        captureBlackout.backgroundColor = .black
        captureBlackout.isUserInteractionEnabled = false
        captureBlackout.isHidden = !viewModel.scanState.renderPresentationPolicy.forceBlackBackground
        context.coordinator.configureCaptureBlackoutView(captureBlackout)
        arView.addSubview(captureBlackout)
        NSLayoutConstraint.activate([
            captureBlackout.leadingAnchor.constraint(equalTo: arView.leadingAnchor),
            captureBlackout.trailingAnchor.constraint(equalTo: arView.trailingAnchor),
            captureBlackout.topAnchor.constraint(equalTo: arView.topAnchor),
            captureBlackout.bottomAnchor.constraint(equalTo: arView.bottomAnchor)
        ])

        // Notify ViewModel that ARKit is ready
        Task { @MainActor in
            viewModel.transition(to: .ready)
        }

        return arView
    }

    func updateUIView(_ uiView: ARSCNView, context: Context) {
        context.coordinator.configureOverlayAppearance(policy: viewModel.scanState.renderPresentationPolicy)
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(viewModel: viewModel)
    }

    static func dismantleUIView(_ uiView: ARSCNView, coordinator: Coordinator) {
        coordinator.teardown()
        uiView.delegate = nil
        uiView.session.delegate = nil
        uiView.session.pause()
    }

    // MARK: - Coordinator

    /// Bridges ARKit delegate callbacks to ScanViewModel
    class Coordinator: NSObject, ARSCNViewDelegate, ARSessionDelegate, @unchecked Sendable {
        let viewModel: ScanViewModel
        private weak var captureBlackoutView: UIView?
        private var lastOverlayPolicySignature: String = ""
        private let frameLock = NSLock()
        private var isProcessingFrame = false
        private var tearingDown = false

        init(viewModel: ScanViewModel) {
            self.viewModel = viewModel
        }

        @MainActor
        func configureCaptureBlackoutView(_ view: UIView) {
            captureBlackoutView = view
        }

        func teardown() {
            frameLock.lock()
            tearingDown = true
            isProcessingFrame = false
            frameLock.unlock()
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.captureBlackoutView = nil
            }
        }

        private func releaseFrameProcessingLock() {
            frameLock.lock()
            isProcessingFrame = false
            frameLock.unlock()
        }

        private func shouldDropFrame() -> Bool {
            frameLock.lock()
            let shouldDrop = tearingDown || isProcessingFrame
            if !shouldDrop {
                isProcessingFrame = true
            }
            frameLock.unlock()
            return shouldDrop
        }

        @MainActor
        func configureOverlayAppearance(policy: ScanRenderPresentationPolicy) {
            captureBlackoutView?.isHidden = !policy.forceBlackBackground
            #if DEBUG
            let alphaText = String(format: "%.2f", policy.overlayClearAlpha)
            let signature =
                "\(policy.forceBlackBackground)|\(policy.overlayOpaque)|"
                + "\(alphaText)|\(policy.borderDepthMode.rawValue)"
            if signature != lastOverlayPolicySignature {
                lastOverlayPolicySignature = signature
                print(
                    "[Aether3D][Policy] overlay forceBlack=\(policy.forceBlackBackground) "
                    + "overlayOpaque=\(policy.overlayOpaque) "
                    + "clearAlpha=\(alphaText) "
                    + "depthMode=\(policy.borderDepthMode.rawValue)"
                )
            }
            #endif
        }

        // ARSessionDelegate — called per frame (~60 FPS)
        func session(_ session: ARSession, didUpdate frame: ARFrame) {
            if shouldDropFrame() {
                return
            }
            let timestamp = frame.timestamp
            let cameraTransform = frame.camera.transform
            let lightEstimateSnapshot = makeLightEstimateSnapshot(frame.lightEstimate)
            // Snapshot sparse feature points on delegate thread so we never
            // retain ARFrame/ARPointCloud objects across actor hops.
            let featurePointsSnapshot: [SIMD3<Float>] = {
                guard let cloud = frame.rawFeaturePoints else { return [] }
                let maxPoints = min(cloud.points.count, 512)
                return Array(cloud.points.prefix(maxPoints))
            }()
            #if os(iOS)
            let orientation = UIInterfaceOrientation.portrait
            let viewportSize = CGSize(width: 1080, height: 1920)
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

            // Extract frame data on ARKit background thread BEFORE Task dispatch.
            // CVPixelBuffers are retained by local variables until Task completes.
            let pixelBuffer = frame.capturedImage
            let cameraIntrinsics = frame.camera.intrinsics
            // LiDAR depth: sceneDepth on LiDAR devices, nil on non-LiDAR (pure DAv2 path)
            let lidarDepthBuffer: CVPixelBuffer? = frame.sceneDepth?.depthMap
                ?? frame.smoothedSceneDepth?.depthMap

            Task { @MainActor in
                self.configureOverlayAppearance(policy: self.viewModel.scanState.renderPresentationPolicy)
                viewModel.processARFrame(
                    timestamp: timestamp,
                    cameraTransform: cameraTransform,
                    lightEstimate: lightEstimateSnapshot,
                    meshAnchors: [],
                    viewMatrix: viewMatrix,
                    projectionMatrix: projectionMatrix,
                    pixelBuffer: pixelBuffer,
                    cameraIntrinsics: cameraIntrinsics,
                    lidarDepthBuffer: lidarDepthBuffer,
                    featurePoints: featurePointsSnapshot
                )
                self.releaseFrameProcessingLock()
            }
        }

        // ARSession error handling
        func session(_ session: ARSession, didFailWithError error: Error) {
            Task { @MainActor in
                viewModel.handleSessionFailure("相机会话中断了，请返回主页重新开始一次扫描。")
            }
        }

        // Session interrupted (phone call, notification, etc.)
        func sessionWasInterrupted(_ session: ARSession) {
            Task { @MainActor in
                viewModel.handleSessionInterrupted()
            }
        }

        // Session interruption ended
        func sessionInterruptionEnded(_ session: ARSession) {
            // Session automatically resumes — user can tap to continue
        }

        private func makeLightEstimateSnapshot(_ estimate: ARLightEstimate?) -> LightEstimateSnapshot? {
            guard let estimate else { return nil }

            var direction: SIMD3<Float>?
            var shCoeffs: [SIMD3<Float>]?

            if let directional = estimate as? ARDirectionalLightEstimate {
                let dir = directional.primaryLightDirection
                direction = SIMD3<Float>(Float(dir.x), Float(dir.y), Float(dir.z))
                let data = directional.sphericalHarmonicsCoefficients
                let floatCount = data.count / MemoryLayout<Float>.size
                if floatCount >= 27 {
                    var values: [SIMD3<Float>] = []
                    values.reserveCapacity(9)
                    data.withUnsafeBytes { ptr in
                        let floats = ptr.bindMemory(to: Float.self)
                        for i in 0..<9 {
                            values.append(
                                SIMD3<Float>(
                                    floats[i * 3],
                                    floats[i * 3 + 1],
                                    floats[i * 3 + 2]
                                )
                            )
                        }
                    }
                    shCoeffs = values
                }
            }

            return LightEstimateSnapshot(
                ambientIntensity: Float(estimate.ambientIntensity),
                primaryLightDirection: direction,
                sphericalHarmonicsCoefficients: shCoeffs
            )
        }
    }
}

#endif
