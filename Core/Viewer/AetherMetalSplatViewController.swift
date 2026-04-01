#if canImport(UIKit) && canImport(MetalKit) && canImport(MetalSplatter) && canImport(SplatIO)

import Foundation
import MetalKit
import MetalSplatter
import SplatIO
import UIKit
import simd

public struct AetherSplatViewerPose: Sendable, Equatable {
    public var artifactCacheKey: String
    public var orientationW: Float
    public var orientationX: Float
    public var orientationY: Float
    public var orientationZ: Float
    public var sceneUpX: Float
    public var sceneUpY: Float
    public var sceneUpZ: Float
    public var source: String
    public var confidence: Float?
    public var estimatedAt: Date

    public init(
        artifactCacheKey: String,
        orientationW: Float,
        orientationX: Float,
        orientationY: Float,
        orientationZ: Float,
        sceneUpX: Float,
        sceneUpY: Float,
        sceneUpZ: Float,
        source: String,
        confidence: Float? = nil,
        estimatedAt: Date = Date()
    ) {
        self.artifactCacheKey = artifactCacheKey
        self.orientationW = orientationW
        self.orientationX = orientationX
        self.orientationY = orientationY
        self.orientationZ = orientationZ
        self.sceneUpX = sceneUpX
        self.sceneUpY = sceneUpY
        self.sceneUpZ = sceneUpZ
        self.source = source
        self.confidence = confidence
        self.estimatedAt = estimatedAt
    }
}

@MainActor
public final class AetherMetalSplatViewController: UIViewController, UIGestureRecognizerDelegate, MTKViewDelegate {
    private struct LoadedScene {
        let points: [SplatPoint]
        let center: SIMD3<Float>
        let radius: Float
    }

    private struct PreparedScene {
        let points: [SplatPoint]
        let center: SIMD3<Float>
        let radius: Float
        let rawCount: Int
        let renderedCount: Int
        let scaleThreshold: Float
    }

    private enum OrbitInputSemantics {
        static let horizontalSign: Float = -1.0
        static let verticalSign: Float = -1.0
        static let sensitivity: Float = 0.006
    }

    private static let defaultFovY: Float = .pi / 3.0
    private static let defaultPitchDownRadians: Float = 0.25
    private static let maxLookPitchRadians: Float = (.pi / 2.0) - 0.18
    private static let softLookPitchZoneRadians: Float = 0.16
    private static let viewerInitialPoseCacheVersion = 8
    private static let canonicalWorldUp = SIMD3<Float>(0, 1, 0)

    public var fileURL: URL? {
        didSet {
            guard fileURL != oldValue, isViewLoaded else { return }
            loadFileIfNeeded()
        }
    }

    public var viewerInitialPose: AetherSplatViewerPose?
    public var onViewerInitialPoseResolved: ((AetherSplatViewerPose) -> Void)?
    public var onModelLoaded: (() -> Void)?

    private var metalView: MTKView!
    private var device: MTLDevice!
    private var commandQueue: MTLCommandQueue!
    private var splatRenderer: SplatRenderer?
    private var loadTask: Task<Void, Never>?
    private let inFlightSemaphore = DispatchSemaphore(value: 3)

    private var dataLoaded = false
    private var currentFileName = ""
    private var activeArtifactCacheKey: String?
    private var appliedUprightCorrectionToken = 0
    private var reportedLoadedArtifactCacheKey: String?

    private var sceneCenter = SIMD3<Float>(0, 0, 0)
    private var sceneRadius: Float = 1.0
    private var sceneUpAxis = SIMD3<Float>(0, -1, 0)
    private var initialPoseSource = "gravity_aligned_default_inverted"
    private var initialPoseConfidence: Float?

    private var cameraTarget = SIMD3<Float>(0, 0, 0)
    private var cameraDistance: Float = 3.0
    private var cameraAzimuth: Float = 0.0
    private var cameraPitch: Float = 0.0
    private var cameraPosition = SIMD3<Float>(0, 0, 3)
    private var cameraOrientation = AetherMetalSplatViewController.legacyDefaultCameraOrientation()

    private var defaultCameraTarget = SIMD3<Float>(0, 0, 0)
    private var defaultCameraDistance: Float = 3.0
    private var defaultCameraAzimuth: Float = 0.0
    private var defaultCameraPitch: Float = 0.0
    private var defaultCameraOrientation = AetherMetalSplatViewController.legacyDefaultCameraOrientation()

    private var observationWindowStart = ProcessInfo.processInfo.systemUptime
    private var observationWindowFrames: UInt64 = 0
    private var observationWindowSlowFrames: UInt64 = 0
    private var observationWindowMaxCPUFrameMs: Double = 0
    private var observationWindowCPUAccumulatedMs: Double = 0

    deinit {
        loadTask?.cancel()
    }

    public override func viewDidLoad() {
        super.viewDidLoad()

        guard let metalDevice = MTLCreateSystemDefaultDevice(),
              let queue = metalDevice.makeCommandQueue() else {
            return
        }

        device = metalDevice
        commandQueue = queue
        view.backgroundColor = .black

        setupMetalView()
        setupGestures()
        loadFileIfNeeded()
    }

    public func applyManualUprightCorrection(token: Int) {
        guard token != appliedUprightCorrectionToken else { return }
        appliedUprightCorrectionToken = token
        sceneUpAxis = Self.leveledVerticalAxis(matching: -sceneUpAxis)
        defaultCameraOrientation = sceneAwareDefaultCameraOrientation()
        defaultCameraTarget = sceneCenter
        defaultCameraDistance = suggestedCameraDistance()
        syncDefaultOrbitStateFromDefaultOrientation()
        initialPoseSource = "manual_upright_flip"
        resetCameraToDefault(persistPose: true)
    }

    private func setupMetalView() {
        metalView = MTKView(frame: view.bounds, device: device)
        metalView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        metalView.colorPixelFormat = .bgra8Unorm_srgb
        metalView.depthStencilPixelFormat = .depth32Float
        metalView.sampleCount = 1
        metalView.clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)
        metalView.preferredFramesPerSecond = 60
        metalView.enableSetNeedsDisplay = false
        metalView.isPaused = false
        metalView.delegate = self
        view.addSubview(metalView)
    }

    private func setupGestures() {
        let orbitPanGesture = UIPanGestureRecognizer(target: self, action: #selector(handleOrbitPan(_:)))
        orbitPanGesture.maximumNumberOfTouches = 1
        orbitPanGesture.delegate = self
        metalView.addGestureRecognizer(orbitPanGesture)

        let translationPanGesture = UIPanGestureRecognizer(target: self, action: #selector(handleTranslationPan(_:)))
        translationPanGesture.minimumNumberOfTouches = 2
        translationPanGesture.maximumNumberOfTouches = 2
        translationPanGesture.delegate = self
        metalView.addGestureRecognizer(translationPanGesture)

        let pinchGesture = UIPinchGestureRecognizer(target: self, action: #selector(handlePinch(_:)))
        pinchGesture.delegate = self
        metalView.addGestureRecognizer(pinchGesture)

        let resetTapGesture = UITapGestureRecognizer(target: self, action: #selector(handleResetTap(_:)))
        resetTapGesture.numberOfTapsRequired = 2
        metalView.addGestureRecognizer(resetTapGesture)
    }

    private func loadFileIfNeeded() {
        guard let url = fileURL else { return }
        loadTask?.cancel()
        dataLoaded = false
        splatRenderer = nil
        currentFileName = url.lastPathComponent
        activeArtifactCacheKey = Self.artifactCacheKey(for: url)
        reportedLoadedArtifactCacheKey = nil

        loadTask = Task { [weak self] in
            do {
                let scene = try await Self.readScene(from: url)
                try Task.checkCancellation()
                guard let self else { return }
                await self.finishLoading(scene: scene, from: url)
            } catch is CancellationError {
                return
            } catch {
                print("[Aether3D][MetalViewer] LOAD FAILED file=\(url.lastPathComponent) error=\(error.localizedDescription)")
            }
        }
    }

    private static func readScene(from url: URL) async throws -> LoadedScene {
        let reader = try AutodetectSceneReader(url)
        let points = try await reader.readAll()
        let (center, radius) = bounds(for: points)
        return LoadedScene(points: points, center: center, radius: radius)
    }

    private func finishLoading(scene: LoadedScene, from url: URL) async {
        do {
            let preparedScene = Self.prepareScene(points: scene.points)
            let renderer = try SplatRenderer(
                device: device,
                colorFormat: metalView.colorPixelFormat,
                depthFormat: metalView.depthStencilPixelFormat,
                sampleCount: metalView.sampleCount,
                maxViewCount: 1,
                maxSimultaneousRenders: 3
            )
            let chunk = try SplatChunk(device: device, from: preparedScene.points)
            await renderer.addChunk(chunk)

            splatRenderer = renderer
            sceneCenter = preparedScene.center
            sceneRadius = max(preparedScene.radius, 0.001)
            cameraTarget = preparedScene.center
            defaultCameraTarget = preparedScene.center

            if let artifactCacheKey = activeArtifactCacheKey,
               let cachedPose = cachedViewerInitialPose(for: artifactCacheKey) {
                sceneUpAxis = Self.leveledVerticalAxis(matching: Self.sceneUpVector(from: cachedPose))
                defaultCameraOrientation = Self.orientationQuaternion(from: cachedPose)
                initialPoseSource = cachedPose.source
                initialPoseConfidence = cachedPose.confidence
            } else {
                sceneUpAxis = SIMD3<Float>(0, -1, 0)
                defaultCameraOrientation = sceneAwareDefaultCameraOrientation()
                initialPoseSource = "gravity_aligned_default_inverted"
                initialPoseConfidence = nil
            }

            defaultCameraDistance = suggestedCameraDistance()
            syncDefaultOrbitStateFromDefaultOrientation()
            resetCameraToDefault(persistPose: activeArtifactCacheKey != nil)
            dataLoaded = true
            print(
                "[Aether3D][MetalViewer][Prep] file=\(url.lastPathComponent) " +
                "rawSplats=\(preparedScene.rawCount) renderedSplats=\(preparedScene.renderedCount) " +
                "radius=\(Self.format(preparedScene.radius)) scaleLimit=\(Self.format(preparedScene.scaleThreshold))"
            )
            logLoadObservation(fileURL: url)

            if reportedLoadedArtifactCacheKey != activeArtifactCacheKey {
                reportedLoadedArtifactCacheKey = activeArtifactCacheKey
                onModelLoaded?()
            }
        } catch {
            print("[Aether3D][MetalViewer] RENDERER SETUP FAILED file=\(url.lastPathComponent) error=\(error.localizedDescription)")
        }
    }

    @objc private func handleOrbitPan(_ gesture: UIPanGestureRecognizer) {
        guard gesture.numberOfTouches <= 1 else {
            gesture.setTranslation(.zero, in: metalView)
            return
        }
        let translation = gesture.translation(in: metalView)
        let deltaX = Float(translation.x) * OrbitInputSemantics.horizontalSign * OrbitInputSemantics.sensitivity
        let deltaY = Float(translation.y) * OrbitInputSemantics.verticalSign * OrbitInputSemantics.sensitivity
        applyOrbitRotation(deltaX: deltaX, deltaY: deltaY)
        gesture.setTranslation(.zero, in: metalView)
    }

    @objc private func handleTranslationPan(_ gesture: UIPanGestureRecognizer) {
        guard gesture.numberOfTouches >= 2 else {
            gesture.setTranslation(.zero, in: metalView)
            return
        }
        let translation = gesture.translation(in: metalView)
        let scale = worldUnitsPerScreenPoint()
        cameraTarget += (-Float(translation.x) * scale) * cameraRightVector()
        cameraTarget += (Float(translation.y) * scale) * cameraVerticalPanAxis()
        rebuildCameraPose()
        gesture.setTranslation(.zero, in: metalView)
    }

    @objc private func handlePinch(_ gesture: UIPinchGestureRecognizer) {
        guard gesture.numberOfTouches >= 2 else {
            gesture.scale = 1
            return
        }
        let unclampedDistance = cameraDistance / max(Float(gesture.scale), 0.01)
        let minDistance = max(sceneRadius * 0.55, 0.75)
        let maxDistance = max(sceneRadius * 8.0, 100.0)
        cameraDistance = max(minDistance, min(maxDistance, unclampedDistance))
        rebuildCameraPose()
        gesture.scale = 1
    }

    @objc private func handleResetTap(_ gesture: UITapGestureRecognizer) {
        resetCameraToDefault()
    }

    private func applyOrbitRotation(deltaX: Float, deltaY: Float) {
        cameraAzimuth += deltaX
        cameraPitch = Self.softClampedPitchRadians(cameraPitch + deltaY)
        rebuildCameraPose()
    }

    private func resetCameraToDefault(persistPose: Bool = false) {
        cameraTarget = defaultCameraTarget
        cameraDistance = defaultCameraDistance
        cameraAzimuth = defaultCameraAzimuth
        cameraPitch = defaultCameraPitch
        rebuildCameraPose()
        if persistPose {
            persistViewerInitialPoseIfNeeded()
        }
    }

    private func sceneAwareDefaultCameraOrientation() -> simd_quatf {
        let sceneUp = Self.normalizedOrFallback(sceneUpAxis, fallback: SIMD3<Float>(0, -1, 0))
        let horizontalForward = fallbackHorizontalForward(for: sceneUp)
        let forward = simd_normalize(
            horizontalForward * cos(Self.defaultPitchDownRadians) -
            sceneUp * sin(Self.defaultPitchDownRadians)
        )
        return Self.orientation(forward: forward, up: sceneUp)
    }

    private func defaultCameraForwardVector() -> SIMD3<Float> {
        Self.normalizedOrFallback(
            defaultCameraOrientation.act(SIMD3<Float>(0, 0, -1)),
            fallback: SIMD3<Float>(0, 0, -1)
        )
    }

    private func suggestedCameraDistance() -> Float {
        max(sceneRadius * 3.5, 2.5)
    }

    private func currentDistanceToSceneCenter() -> Float {
        max(cameraDistance, 0.001)
    }

    private func worldUnitsPerScreenPoint() -> Float {
        let viewHeight = max(Float(metalView.bounds.height), 1.0)
        let frustumHeight = 2.0 * currentDistanceToSceneCenter() * tan(Self.defaultFovY * 0.5)
        return frustumHeight / viewHeight
    }

    private func cameraForwardVector() -> SIMD3<Float> {
        Self.normalizedOrFallback(
            cameraOrientation.act(SIMD3<Float>(0, 0, -1)),
            fallback: SIMD3<Float>(0, 0, -1)
        )
    }

    private func cameraRightVector() -> SIMD3<Float> {
        Self.normalizedOrFallback(
            simd_cross(cameraForwardVector(), cameraUpVector()),
            fallback: SIMD3<Float>(1, 0, 0)
        )
    }

    private func cameraUpVector() -> SIMD3<Float> {
        Self.normalizedOrFallback(
            cameraOrientation.act(SIMD3<Float>(0, 1, 0)),
            fallback: sceneUpAxis
        )
    }

    private func cameraVerticalPanAxis() -> SIMD3<Float> {
        let sceneUp = Self.leveledVerticalAxis(matching: sceneUpAxis)
        let right = cameraRightVector()
        let axis = sceneUp - simd_dot(sceneUp, right) * right
        return Self.normalizedOrFallback(axis, fallback: sceneUp)
    }

    private func viewMatrix() -> simd_float4x4 {
        let eye = cameraPosition
        return lookAt(eye: eye, center: cameraTarget, up: cameraUpVector())
    }

    private func projectionMatrix(size: CGSize) -> simd_float4x4 {
        let aspect = max(Float(size.width / max(size.height, 1)), 0.01)
        let nearZ = max(0.01, min(0.10, currentDistanceToSceneCenter() * 0.02))
        let farZ = max(currentDistanceToSceneCenter() + sceneRadius * 8.0, 100.0)
        return perspectiveProjection(fovY: Self.defaultFovY, aspect: aspect, nearZ: nearZ, farZ: farZ)
    }

    private func lookAt(eye: SIMD3<Float>, center: SIMD3<Float>, up: SIMD3<Float>) -> simd_float4x4 {
        let forward = Self.normalizedOrFallback(center - eye, fallback: SIMD3<Float>(0, 0, -1))
        var stableUp = Self.normalizedOrFallback(up, fallback: SIMD3<Float>(0, 1, 0))
        if abs(simd_dot(forward, stableUp)) > 0.985 {
            stableUp = Self.orthogonalUnitVector(to: forward)
        }
        let right = Self.normalizedOrFallback(simd_cross(forward, stableUp), fallback: SIMD3<Float>(1, 0, 0))
        let correctedUp = Self.normalizedOrFallback(simd_cross(right, forward), fallback: stableUp)

        var result = matrix_identity_float4x4
        result[0][0] = right.x
        result[0][1] = right.y
        result[0][2] = right.z
        result[1][0] = correctedUp.x
        result[1][1] = correctedUp.y
        result[1][2] = correctedUp.z
        result[2][0] = -forward.x
        result[2][1] = -forward.y
        result[2][2] = -forward.z
        result[3][0] = -simd_dot(right, eye)
        result[3][1] = -simd_dot(correctedUp, eye)
        result[3][2] = simd_dot(forward, eye)
        return result
    }

    private func perspectiveProjection(fovY: Float, aspect: Float, nearZ: Float, farZ: Float) -> simd_float4x4 {
        let yScale = 1.0 / tan(fovY * 0.5)
        let xScale = yScale / aspect
        let zScale = farZ / (nearZ - farZ)
        return simd_float4x4(columns: (
            SIMD4<Float>(xScale, 0, 0, 0),
            SIMD4<Float>(0, yScale, 0, 0),
            SIMD4<Float>(0, 0, zScale, -1),
            SIMD4<Float>(0, 0, zScale * nearZ, 0)
        ))
    }

    private func syncDefaultOrbitStateFromDefaultOrientation() {
        let leveledSceneUp = Self.leveledVerticalAxis(matching: sceneUpAxis)
        let defaultForward = defaultCameraForwardVector()
        let horizontalReference = fallbackHorizontalForward(for: leveledSceneUp)
        let horizontalForward = Self.horizontalForwardComponent(from: defaultForward, sceneUp: leveledSceneUp)
        let crossValue = simd_dot(simd_cross(horizontalReference, horizontalForward), leveledSceneUp)
        let dotValue = simd_dot(horizontalReference, horizontalForward)
        defaultCameraAzimuth = atan2(crossValue, dotValue)
        defaultCameraPitch = Self.softClampedPitchRadians(
            Self.pitchRadians(forward: defaultForward, sceneUp: leveledSceneUp)
        )
    }

    private func rebuildCameraPose() {
        let leveledSceneUp = Self.leveledVerticalAxis(matching: sceneUpAxis)
        let horizontalReference = fallbackHorizontalForward(for: leveledSceneUp)
        let yawRotation = simd_quatf(angle: cameraAzimuth, axis: leveledSceneUp)
        let horizontalForward = Self.normalizedOrFallback(
            yawRotation.act(horizontalReference),
            fallback: horizontalReference
        )
        let forward = Self.normalizedOrFallback(
            horizontalForward * cos(cameraPitch) - leveledSceneUp * sin(cameraPitch),
            fallback: horizontalForward
        )
        cameraOrientation = Self.orientation(forward: forward, up: leveledSceneUp)
        cameraPosition = cameraTarget - forward * cameraDistance
    }

    private func logLoadObservation(fileURL: URL) {
        print(
            "[Aether3D][MetalViewer][Load] file=\(fileURL.lastPathComponent) " +
            "splats=\(splatRenderer?.splatCount ?? 0) radius=\(Self.format(sceneRadius)) " +
            "center=(\(Self.format(sceneCenter.x)), \(Self.format(sceneCenter.y)), \(Self.format(sceneCenter.z))) " +
            "source=\(initialPoseSource) up=(\(Self.format(sceneUpAxis.x)), \(Self.format(sceneUpAxis.y)), \(Self.format(sceneUpAxis.z)))"
        )
    }

    private func observeFrame(cpuFrameMs: Double) {
        let now = ProcessInfo.processInfo.systemUptime
        observationWindowFrames += 1
        observationWindowCPUAccumulatedMs += cpuFrameMs
        observationWindowMaxCPUFrameMs = max(observationWindowMaxCPUFrameMs, cpuFrameMs)
        if cpuFrameMs > 25 {
            observationWindowSlowFrames += 1
        }

        let windowDuration = now - observationWindowStart
        guard windowDuration >= 2.0 else { return }

        let fps = Double(observationWindowFrames) / max(windowDuration, 0.001)
        let cpuAvg = observationWindowCPUAccumulatedMs / Double(max(observationWindowFrames, 1))
        let pitch = Self.pitchRadians(forward: cameraForwardVector(), sceneUp: sceneUpAxis) * 180.0 / .pi
        print(
            "[Aether3D][MetalViewer][Observe] file=\(currentFileName) " +
            "fps=\(String(format: "%.1f", fps)) cpuAvg=\(String(format: "%.3f", cpuAvg))ms " +
            "cpuMax=\(String(format: "%.3f", observationWindowMaxCPUFrameMs))ms " +
            "slow=\(observationWindowSlowFrames)/\(observationWindowFrames) " +
            "splats=\(splatRenderer?.splatCount ?? 0) dist=\(Self.format(currentDistanceToSceneCenter())) " +
            "pitch=\(Self.format(pitch, digits: 1))deg up=(\(Self.format(sceneUpAxis.x, digits: 2)), \(Self.format(sceneUpAxis.y, digits: 2)), \(Self.format(sceneUpAxis.z, digits: 2)))"
        )

        observationWindowStart = now
        observationWindowFrames = 0
        observationWindowSlowFrames = 0
        observationWindowMaxCPUFrameMs = 0
        observationWindowCPUAccumulatedMs = 0
    }

    private func cachedViewerInitialPose(for artifactCacheKey: String) -> AetherSplatViewerPose? {
        guard let viewerInitialPose, viewerInitialPose.artifactCacheKey == artifactCacheKey else {
            return nil
        }
        return viewerInitialPose
    }

    private func persistViewerInitialPoseIfNeeded() {
        guard let artifactCacheKey = activeArtifactCacheKey else { return }
        let pose = AetherSplatViewerPose(
            artifactCacheKey: artifactCacheKey,
            orientationW: defaultCameraOrientation.real,
            orientationX: defaultCameraOrientation.imag.x,
            orientationY: defaultCameraOrientation.imag.y,
            orientationZ: defaultCameraOrientation.imag.z,
            sceneUpX: sceneUpAxis.x,
            sceneUpY: sceneUpAxis.y,
            sceneUpZ: sceneUpAxis.z,
            source: initialPoseSource,
            confidence: initialPoseConfidence
        )
        viewerInitialPose = pose
        onViewerInitialPoseResolved?(pose)
    }

    private static func artifactCacheKey(for url: URL) -> String {
        let values = try? url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
        let size = values?.fileSize ?? 0
        let modifiedMs = Int((values?.contentModificationDate?.timeIntervalSince1970 ?? 0) * 1000.0)
        return "viewerPoseV\(viewerInitialPoseCacheVersion)|\(url.lastPathComponent)|\(size)|\(modifiedMs)"
    }

    private static func orientationQuaternion(from pose: AetherSplatViewerPose) -> simd_quatf {
        let imaginary = SIMD3<Float>(pose.orientationX, pose.orientationY, pose.orientationZ)
        let quaternion = simd_quatf(ix: imaginary.x, iy: imaginary.y, iz: imaginary.z, r: pose.orientationW)
        return simd_normalize(quaternion)
    }

    private static func sceneUpVector(from pose: AetherSplatViewerPose) -> SIMD3<Float> {
        normalizedOrFallback(
            SIMD3<Float>(pose.sceneUpX, pose.sceneUpY, pose.sceneUpZ),
            fallback: SIMD3<Float>(0, -1, 0)
        )
    }

    private static func bounds(for points: [SplatPoint]) -> (center: SIMD3<Float>, radius: Float) {
        guard var minPoint = points.first?.position,
              var maxPoint = points.first?.position else {
            return (.zero, 1)
        }

        for point in points {
            minPoint = simd_min(minPoint, point.position)
            maxPoint = simd_max(maxPoint, point.position)
        }
        let center = (minPoint + maxPoint) * 0.5
        var radius: Float = 0.001
        for point in points {
            radius = max(radius, simd_distance(point.position, center))
        }
        return (center, radius)
    }

    private static func prepareScene(points: [SplatPoint]) -> PreparedScene {
        guard !points.isEmpty else {
            return PreparedScene(points: [], center: .zero, radius: 1, rawCount: 0, renderedCount: 0, scaleThreshold: 0)
        }

        let rawBounds = bounds(for: points)
        let rawRadius = max(rawBounds.radius, 0.001)

        let scaleSamples = points.compactMap { point -> Float? in
            let scale = point.scale.asLinearFloat
            guard scale.x.isFinite, scale.y.isFinite, scale.z.isFinite else { return nil }
            return max(scale.x, max(scale.y, scale.z))
        }.sorted()

        let p95Scale = percentile(scaleSamples, fraction: 0.95)
        let scaleThreshold = max(rawRadius * 0.45, p95Scale * 10.0, 0.25)

        let filteredPoints = points.filter { point in
            let position = point.position
            guard position.x.isFinite, position.y.isFinite, position.z.isFinite else { return false }

            let opacity = point.opacity.asLinearFloat
            guard opacity.isFinite, opacity > 0.003 else { return false }

            let scale = point.scale.asLinearFloat
            guard scale.x.isFinite, scale.y.isFinite, scale.z.isFinite else { return false }
            let maxScale = max(scale.x, max(scale.y, scale.z))
            return maxScale <= scaleThreshold
        }

        let retainedPoints: [SplatPoint]
        if filteredPoints.count >= max(512, points.count / 2) {
            retainedPoints = filteredPoints
        } else {
            retainedPoints = points
        }

        let preparedBounds = bounds(for: retainedPoints)
        return PreparedScene(
            points: retainedPoints,
            center: preparedBounds.center,
            radius: preparedBounds.radius,
            rawCount: points.count,
            renderedCount: retainedPoints.count,
            scaleThreshold: scaleThreshold
        )
    }

    private static func percentile(_ sortedValues: [Float], fraction: Float) -> Float {
        guard !sortedValues.isEmpty else { return 0 }
        let clampedFraction = max(0, min(1, fraction))
        let index = Int((Float(sortedValues.count - 1) * clampedFraction).rounded(.down))
        return sortedValues[index]
    }

    private static func normalizedOrFallback(_ vector: SIMD3<Float>, fallback: SIMD3<Float>) -> SIMD3<Float> {
        let lengthSquared = simd_length_squared(vector)
        if lengthSquared < 1e-8 {
            return simd_normalize(fallback)
        }
        return simd_normalize(vector)
    }

    private static func leveledVerticalAxis(matching vector: SIMD3<Float>) -> SIMD3<Float> {
        let normalized = normalizedOrFallback(vector, fallback: canonicalWorldUp)
        let dominant = abs(normalized.y) >= abs(normalized.x) && abs(normalized.y) >= abs(normalized.z)
        if dominant {
            return normalized.y >= 0 ? canonicalWorldUp : -canonicalWorldUp
        }
        return normalized.y >= 0 ? canonicalWorldUp : -canonicalWorldUp
    }

    private static func orthogonalUnitVector(to vector: SIMD3<Float>) -> SIMD3<Float> {
        let basis: [SIMD3<Float>] = [
            SIMD3<Float>(1, 0, 0),
            SIMD3<Float>(0, 1, 0),
            SIMD3<Float>(0, 0, 1)
        ]
        var candidate = basis.min { lhs, rhs in
            abs(simd_dot(lhs, vector)) < abs(simd_dot(rhs, vector))
        } ?? SIMD3<Float>(1, 0, 0)
        candidate -= simd_dot(candidate, vector) * vector
        return normalizedOrFallback(candidate, fallback: SIMD3<Float>(1, 0, 0))
    }

    private static func orientation(forward: SIMD3<Float>, up: SIMD3<Float>) -> simd_quatf {
        let f = normalizedOrFallback(forward, fallback: SIMD3<Float>(0, 0, -1))
        var u = up - simd_dot(up, f) * f
        u = normalizedOrFallback(u, fallback: SIMD3<Float>(0, 1, 0))
        let r = normalizedOrFallback(simd_cross(f, u), fallback: SIMD3<Float>(1, 0, 0))
        let correctedUp = normalizedOrFallback(simd_cross(r, f), fallback: SIMD3<Float>(0, 1, 0))
        let basis = simd_float3x3(columns: (r, correctedUp, -f))
        return simd_normalize(simd_quatf(basis))
    }

    private static func pitchRadians(forward: SIMD3<Float>, sceneUp: SIMD3<Float>) -> Float {
        asin(max(-1.0, min(1.0, -simd_dot(forward, sceneUp))))
    }

    private static func softClampedPitchRadians(_ requestedPitch: Float) -> Float {
        let hardLimit = maxLookPitchRadians
        let softStart = max(0, hardLimit - softLookPitchZoneRadians)
        let sign: Float = requestedPitch >= 0 ? 1 : -1
        let magnitude = abs(requestedPitch)
        if magnitude <= softStart {
            return requestedPitch
        }
        let overflow = magnitude - softStart
        let softRange = max(hardLimit - softStart, 1e-4)
        let compressedOverflow = softRange * tanh(overflow / softRange)
        return sign * min(hardLimit, softStart + compressedOverflow)
    }

    private static func horizontalForwardComponent(from forward: SIMD3<Float>, sceneUp: SIMD3<Float>) -> SIMD3<Float> {
        let horizontal = forward - simd_dot(forward, sceneUp) * sceneUp
        return normalizedOrFallback(horizontal, fallback: orthogonalUnitVector(to: sceneUp))
    }

    private static func baseUpVector(forward: SIMD3<Float>, sceneUp: SIMD3<Float>) -> SIMD3<Float> {
        let right = normalizedOrFallback(simd_cross(forward, sceneUp), fallback: orthogonalUnitVector(to: forward))
        return normalizedOrFallback(simd_cross(right, forward), fallback: sceneUp)
    }

    private static func upVector(forward: SIMD3<Float>, sceneUp: SIMD3<Float>, rollRadians: Float) -> SIMD3<Float> {
        let baseUp = baseUpVector(forward: forward, sceneUp: sceneUp)
        guard abs(rollRadians) > 1e-5 else { return baseUp }
        let rollRotation = simd_quatf(angle: rollRadians, axis: normalizedOrFallback(forward, fallback: SIMD3<Float>(0, 0, -1)))
        return normalizedOrFallback(rollRotation.act(baseUp), fallback: baseUp)
    }

    private static func currentRollRadians(forward: SIMD3<Float>, sceneUp: SIMD3<Float>, currentUp: SIMD3<Float>) -> Float {
        let baseUp = baseUpVector(forward: forward, sceneUp: sceneUp)
        let right = normalizedOrFallback(simd_cross(forward, baseUp), fallback: orthogonalUnitVector(to: forward))
        let projectedCurrentUp = normalizedOrFallback(
            currentUp - simd_dot(currentUp, forward) * forward,
            fallback: baseUp
        )
        let sinValue = simd_dot(projectedCurrentUp, right)
        let cosValue = simd_dot(projectedCurrentUp, baseUp)
        return atan2(sinValue, cosValue)
    }

    private static func legacyDefaultCameraOrientation() -> simd_quatf {
        simd_normalize(simd_quatf(angle: -defaultPitchDownRadians, axis: SIMD3<Float>(1, 0, 0)))
    }

    private static func legacyDefaultForwardDirection() -> SIMD3<Float> {
        legacyDefaultCameraOrientation().act(SIMD3<Float>(0, 0, -1))
    }

    private func fallbackHorizontalForward(for up: SIMD3<Float>) -> SIMD3<Float> {
        var candidate = Self.legacyDefaultForwardDirection() - simd_dot(Self.legacyDefaultForwardDirection(), up) * up
        if simd_length_squared(candidate) < 1e-6 {
            candidate = SIMD3<Float>(0, 0, -1) - simd_dot(SIMD3<Float>(0, 0, -1), up) * up
        }
        if simd_length_squared(candidate) < 1e-6 {
            candidate = SIMD3<Float>(1, 0, 0) - simd_dot(SIMD3<Float>(1, 0, 0), up) * up
        }
        return Self.normalizedOrFallback(candidate, fallback: SIMD3<Float>(0, 0, -1))
    }

    private static func format<T: BinaryFloatingPoint>(_ value: T, digits: Int = 3) -> String {
        String(format: "%.\(digits)f", Double(value))
    }

    public func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        if let pan = gestureRecognizer as? UIPanGestureRecognizer {
            if pan.maximumNumberOfTouches == 1 {
                return pan.numberOfTouches <= 1
            }
            return pan.numberOfTouches >= 2
        }
        return true
    }

    public func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer) -> Bool {
        let isSingleFingerOrbit =
            (gestureRecognizer is UIPanGestureRecognizer && (gestureRecognizer as? UIPanGestureRecognizer)?.maximumNumberOfTouches == 1) ||
            (otherGestureRecognizer is UIPanGestureRecognizer && (otherGestureRecognizer as? UIPanGestureRecognizer)?.maximumNumberOfTouches == 1)
        if isSingleFingerOrbit {
            return false
        }
        let gestures = [gestureRecognizer, otherGestureRecognizer]
        let hasPinch = gestures.contains { $0 is UIPinchGestureRecognizer }
        let hasTwoFingerPan = gestures.contains {
            guard let pan = $0 as? UIPanGestureRecognizer else { return false }
            return pan.minimumNumberOfTouches >= 2
        }
        return hasPinch && hasTwoFingerPan
    }

    public func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}

    public func draw(in view: MTKView) {
        guard let splatRenderer, dataLoaded else { return }
        guard let drawable = view.currentDrawable,
              let depthTexture = view.depthStencilTexture,
              let commandBuffer = commandQueue.makeCommandBuffer() else {
            return
        }

        let cpuFrameStart = ProcessInfo.processInfo.systemUptime
        _ = inFlightSemaphore.wait(timeout: .distantFuture)
        let semaphore = inFlightSemaphore
        commandBuffer.addCompletedHandler { _ in
            semaphore.signal()
        }

        let size = view.drawableSize
        let viewport = MTLViewport(originX: 0, originY: 0, width: size.width, height: size.height, znear: 0, zfar: 1)
        let descriptor = SplatRenderer.ViewportDescriptor(
            viewport: viewport,
            projectionMatrix: projectionMatrix(size: size),
            viewMatrix: viewMatrix(),
            screenSize: SIMD2<Int>(Int(size.width), Int(size.height))
        )

        do {
            let didRender = try splatRenderer.render(
                viewports: [descriptor],
                colorTexture: view.multisampleColorTexture ?? drawable.texture,
                colorStoreAction: view.multisampleColorTexture == nil ? .store : .multisampleResolve,
                depthTexture: depthTexture,
                rasterizationRateMap: nil,
                renderTargetArrayLength: 0,
                to: commandBuffer
            )
            if didRender {
                commandBuffer.present(drawable)
            } else {
                print("[Aether3D][MetalViewer] SKIPPED FRAME file=\(currentFileName) reason=didRenderFalse splats=\(splatRenderer.splatCount)")
            }
        } catch {
            print("[Aether3D][MetalViewer] RENDER FAILED file=\(currentFileName) error=\(error.localizedDescription)")
        }

        observeFrame(cpuFrameMs: (ProcessInfo.processInfo.systemUptime - cpuFrameStart) * 1000.0)
        commandBuffer.commit()
    }
}

#endif
