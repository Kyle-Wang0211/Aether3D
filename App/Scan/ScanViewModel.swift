//
// ScanViewModel.swift
// Aether3D
//
// Scan ViewModel — THE ORCHESTRATOR
// Unified point cloud → 3DGS progressive pipeline.
// ARFrame → PipelineCoordinatorBridge (C++ 3-thread coordinator) → PointCloudOIRPipeline (Metal)
// Apple-platform only (ARKit + SwiftUI)
//

import Foundation
import Aether3DCore
import Darwin

#if canImport(SwiftUI) && canImport(ARKit)
import SwiftUI
import ARKit
import simd
#if canImport(AVFoundation)
import AVFoundation
#endif
#if canImport(UIKit)
import UIKit
#endif
#if canImport(Metal)
import Metal
#endif
#if canImport(CoreVideo)
import CoreVideo
#endif
#if canImport(CoreImage)
import CoreImage
#endif
#if canImport(CAetherNativeBridge)
import CAetherNativeBridge
#endif

/// THE ORCHESTRATOR — @MainActor ViewModel
///
/// Architecture (unified point cloud → 3DGS):
///   ARFrame (60fps) → PipelineCoordinatorBridge.onFrame()
///     → C++ Thread A: depth→point cloud, frame selection
///     → C++ Thread B: evidence + quality (async)
///     → C++ Thread C: 3DGS training
///     → EvidenceSnapshot → Swift UI update
///     → PointCloudOIRPipeline (Metal overlay)
///
/// Compared to previous wedge-based orchestrator:
///   - Removed: MeshExtractor, WedgeGeometryGenerator, FlipAnimationController,
///              RipplePropagationEngine, SpatialHashAdjacency, PatchDisplayMap,
///              patch identity system, GrayscaleMapper, AdaptiveBorderCalculator
///   - Added:   PipelineCoordinatorBridge, PointCloudOIRPipeline
///   - Memory:  ~39MB (wedge) → ~10MB (point cloud + OIR)
@MainActor
final class ScanViewModel: ObservableObject {

    // MARK: - Published State (drives SwiftUI)
    @Published var scanState: ScanState = .initializing
    @Published var isCapturing: Bool = false
    @Published var elapsedTime: TimeInterval = 0
    @Published var trainingActive: Bool = false
    @Published var trainingProgress: Float = 0.0
    @Published var coveragePercent: Float = 0.0
    @Published var isExporting: Bool = false
    @Published var backgroundExportStatusMessage: String? = nil
    @Published var coordinatorNotReady: Bool = false  // Set when stop attempted before coordinator loaded
    @Published var liveGuidanceTitle: String = "正在准备扫描环境"
    @Published var liveGuidanceDetail: String = "请先把目标物体完整放进画面中央。"
    @Published var scanFailureMessage: String? = nil
    @Published var sessionPauseMessage: String? = nil
    @Published var motionWarningActive: Bool = false
    @Published var exposureWarningActive: Bool = false
    @Published var stabilityWarningActive: Bool = false
    @Published var latestMotionSpeedMps: Double = 0.0
    @Published var latestAmbientIntensity: Float = 0.0
    @Published var captureWeakGeometryCount: Int = 0
    @Published var captureRecoverableGeometryCount: Int = 0
    @Published var captureStableGeometryCount: Int = 0

    // MARK: - Existing Components (REUSE, DO NOT RECREATE)
    let toastPresenter: GuidanceToastPresenter
    let hapticEngine: GuidanceHapticEngine
    private let completionBridge: ScanCompletionBridge

    // MARK: - Thermal
    private let thermalAdapter = ThermalQualityAdapter()

    // MARK: - Pipeline (C++ coordinator + Metal renderer)
    private var coordinatorBridge: PipelineCoordinatorBridge?
    #if canImport(CAetherNativeBridge) && canImport(Metal)
    private var gpuDeviceHandle: OpaquePointer?      // aether_gpu_device_t* — must outlive coordinator
    private var splatEngineHandle: OpaquePointer?     // aether_splat_engine_t* — must outlive coordinator
    #endif
    #if canImport(Metal)
    private var renderPipeline: PointCloudOIRPipeline?
    #endif

    // DAv2 depth estimation now runs in C++ core layer (depth_inference_coreml.mm).
    // Swift no longer manages the DepthAnythingV2Bridge — C++ PipelineCoordinator
    // owns the DepthInferenceEngine and runs async inference on Neural Engine directly.

    // MARK: - Pixel Format Conversion (YCbCr → BGRA)
    // These are accessed exclusively from frameForwardQueue (serial), not MainActor.
    #if canImport(CoreImage) && canImport(CoreVideo)
    nonisolated(unsafe) private var pixelConvertContext: CIContext = CIContext(options: [.useSoftwareRenderer: false])
    nonisolated(unsafe) private var bgraBuffer: CVPixelBuffer?
    #endif

    // MARK: - Pose Stabilizer
    private var poseStabilizer: OpaquePointer?
    private var lastPoseQuality: Float = 0.0
    private static let posePredictionLeadNs: UInt64 = 12_000_000
    private static let poseMinimumAcceptedQuality: Float = 0.35

    // MARK: - Motion Tracking
    private var lastMotionSample: (position: SIMD3<Float>, timestamp: TimeInterval)?
    private var frameCounter: Int = 0
    private var isInitializingCoordinator: Bool = false
    private var selectedProcessingBackend: ProcessingBackendChoice
    private var activeCoordinatorBackend: ProcessingBackendChoice?
    private var pendingCaptureStartAfterCoordinatorReady: Bool = false
    private var lastCaptureHUDPublishTime: CFAbsoluteTime = 0
    private var lastGuidancePublishTime: CFAbsoluteTime = 0

    private var isSubjectFirstLocalMode: Bool {
        selectedProcessingBackend == .localSubjectFirst
    }

    private var pipelineFrameInterval: Int {
        isSubjectFirstLocalMode
            ? Self.subjectFirstPipelineFrameInterval
            : Self.defaultPipelineFrameInterval
    }

    private var shouldRecordRemoteVideoForSelectedBackend: Bool {
        selectedProcessingBackend == .cloud || selectedProcessingBackend == .localSubjectFirst
    }

    private var shouldStreamOverlayPipelineDuringCapture: Bool {
        scanState == .capturing
    }

    var prefersMinimalARCaptureRuntime: Bool {
        isSubjectFirstLocalMode
    }

    var shouldAcquireHeavyARFrameInputs: Bool {
        scanState == .capturing && coordinatorBridge != nil
    }

    var shouldRequestSceneDepthDuringCapture: Bool {
        !prefersMinimalARCaptureRuntime
    }

    var shouldProcessLiveARFrames: Bool {
        if isSubjectFirstLocalMode {
            return scanState == .capturing || scanState == .paused || scanState == .finishing
        }
        return scanState.isActive
    }

    private static let captureHUDPublishInterval: CFAbsoluteTime = 0.18
    private static let guidancePublishInterval: CFAbsoluteTime = 0.28

    // MARK: - Debug Overlay Stats (drives scan screen HUD)
    @Published var debugBridgeReady: Bool = false
    @Published var debugFrameCount: Int = 0
    @Published var debugPipelineFrameCount: Int = 0    // Frames forwarded to C++
    @Published var debugPointCloudCount: Int = 0
    @Published var debugOverlayCount: Int = 0
    @Published var debugSplatCount: Int = 0
    @Published var debugTrainingStep: Int = 0
    @Published var debugTotalSteps: Int = 0
    @Published var debugLoss: Float = 0.0
    @Published var debugCoordinatorInitTime: TimeInterval = 0  // Time since init started
    @Published var debugPointCloudAlpha: Float = -1.0  // Global PC alpha from C++ blend
    @Published var debugEncodeDrawCount: Int = 0       // encode() calls that drew something
    @Published var debugEncodeSkipCount: Int = 0       // encode() calls that had no data
    @Published var debugSelectedFrames: Int = 0        // Frames passing selection for training
    @Published var debugMinFramesNeeded: Int = 4       // min_frames_to_start_training from C++
    @Published var debugKeyframeGateAccepts: Int = 0   // Live keyframes admitted by native gate
    @Published var debugKeyframeGateRejects: Int = 0   // Live frames rejected as near-duplicate / weak motion
    @Published var debugIsGPUTraining: Bool = false    // GPU vs CPU training path
    @Published var debugHasS6Quality: Bool = false     // S6+ quality reached (display only, 0.85)

    // ── 全局训练状态 ──
    @Published var debugNumGaussians: Int = 0          // Current Gaussian count in global engine
    @Published var debugAssignedBlocks: Int = 0        // Surface blocks → Gaussians (geometry gate)
    @Published var debugPendingGaussians: Int = 0      // Gaussians waiting in queue
    @Published var debugPreviewSeedAccepted: Int = 0   // Live preview seeds accepted by native runtime
    @Published var debugPreviewSeedCandidates: Int = 0 // Raw live preview seed candidates before gating

    private var coordinatorInitStartTime: CFAbsoluteTime = 0

    // Quality milestone tracking removed — TSDF overlay heatmap replaces text toasts.

    // MARK: - Frame Forwarding Queue
    /// Serial queue for CIContext BGRA conversion + C++ frame submission.
    /// Moves GPU-wait + memcpy off main thread (~5-10ms saved per frame).
    private let frameForwardQueue = DispatchQueue(
        label: "com.aether3d.frame-forward", qos: .userInitiated)
    /// Guard to prevent frame forwarding queue buildup (at most 1 in-flight).
    nonisolated(unsafe) private var isForwardingFrame: Bool = false

    // MARK: - Frame Throttling
    /// Forward every Nth frame to the live geometry pipeline. ARKit runs at ~60fps.
    /// Keep full-quality recording intact, but aggressively downsample live processing
    /// for subject-first local capture so long sessions leave thermal/memory headroom.
    private static let defaultPipelineFrameInterval: Int = 6   // ~10fps
    private static let subjectFirstPipelineFrameInterval: Int = 30  // ~2fps

    // MARK: - Timer
    private var captureStartTime: Date?
    nonisolated(unsafe) private var elapsedTimer: Timer?
    #if canImport(AVFoundation)
    private var remoteVideoRecorder: ARFrameVideoRecorder?
    private var remoteVideoRecorderMinFrameStep: TimeInterval = 0
    private var lastRemoteVideoFrameEnqueueTimestamp: TimeInterval?
    #endif

    // MARK: - Thermal Monitoring
    nonisolated(unsafe) private var thermalObserver: NSObjectProtocol?

    // MARK: - Product World-State Export
    private let worldStateRecorder = WorldStateRecorder()
    nonisolated private static let worldStateSchemaVersion = "aether_world_state_v1"
    nonisolated private static let worldStateGridCell: Float = 0.05
    nonisolated private static let worldStateConfirmedSamples = 2
    nonisolated private static let worldStateLockedSamples = 5
    nonisolated private static let worldStateSurfaceCell: Float = 0.05
    nonisolated private static let worldStateSurfaceMaxPoints = 200_000
    nonisolated private static let worldStateSurfaceSupportThresholdMM: Float = 20.0
    nonisolated private static let worldStateSurfaceNormalRadius: Float = 0.08
    nonisolated private static let worldStateSurfaceSearchRings = 2

    struct RawWorldStateTile: Sendable {
        let center: SIMD3<Float>
        let normal: SIMD3<Float>
        let size: Float
        let quality: Float
    }

    private struct SurfaceIndex: Sendable {
        let points: [SIMD3<Float>]
        let buckets: [Int64: [Int]]
    }

    struct RawWorldStateFrame: Sendable {
        let frameIndex: Int
        let timestampS: Double
        let coverage: Double
        let cameraIntrinsics: simd_float3x3?
        let tiles: [RawWorldStateTile]
    }

    private struct CaptureGeometrySummary: Sendable {
        let weakCount: Int
        let recoverableCount: Int
        let stableCount: Int

        var totalCount: Int {
            weakCount + recoverableCount + stableCount
        }
    }

    private struct CaptureKeyframeBudget: Sendable {
        let engineStart: Int
        let recommendedMin: Int
        let recommendedTarget: Int
        let recommendedMax: Int
    }

    private struct WorldStateNeighbor: Codable, Sendable {
        let tile_id: String
        let gap_mm: Double
    }

    private struct WorldStateTile: Codable, Sendable {
        let tile_id: String
        let cell_id: String
        let state: String
        let visible: Bool
        let center: [Double]
        let normal: [Double]
        let corners: [[Double]]
        let u: Int?
        let v: Int?
        let neighbors: [WorldStateNeighbor]
        let surface_center_distance_mm: Double?
        let surface_normal_dot: Double?
        let surface_corner_support: [Bool]?
    }

    private struct WorldStateFrame: Codable, Sendable {
        let frame_index: Int
        let timestamp_s: Double
        let coverage: Double
        let tiles: [WorldStateTile]
    }

    private struct WorldStateMeta: Codable, Sendable {
        let scene_id: String
        let cell_level: Int
        let notes: String
    }

    private struct WorldStateExport: Codable, Sendable {
        let version: String
        let meta: WorldStateMeta
        let frames: [WorldStateFrame]
    }

    private struct DerivedTileDraft {
        var tile: WorldStateTile
        let center: SIMD3<Float>
        let normal: SIMD3<Float>
        let size: Float
    }

    private final class WorldStateRecorder {
        private var frames: [RawWorldStateFrame] = []
        private var firstTimestamp: TimeInterval?

        func reset() {
            frames.removeAll(keepingCapacity: false)
            firstTimestamp = nil
        }

        func snapshot() -> [RawWorldStateFrame] {
            frames
        }

        func recordFrame(
            frameIndex: Int,
            timestamp: TimeInterval,
            coverage: Float,
            cameraIntrinsics: simd_float3x3?,
            renderData: PipelineCoordinatorBridge.RenderData?
        ) {
            if firstTimestamp == nil {
                firstTimestamp = timestamp
            }
            let baseTimestamp = firstTimestamp ?? timestamp
            let timestampS = max(0.0, timestamp - baseTimestamp)
            frames.append(
                RawWorldStateFrame(
                    frameIndex: frameIndex,
                    timestampS: timestampS,
                    coverage: Double(max(0.0, min(1.0, coverage))),
                    cameraIntrinsics: cameraIntrinsics,
                    tiles: ScanViewModel.extractRawWorldStateTiles(from: renderData)
                )
            )
        }
    }

    // ═══════════════════════════════════════════════════════════════════════
    // MARK: - Initialization
    // ═══════════════════════════════════════════════════════════════════════

    init(initialProcessingBackend: ProcessingBackendChoice = ProcessingBackendChoice.currentSelection()) {
        let normalizedBackend = initialProcessingBackend == .localPreview
            ? ProcessingBackendChoice.localSubjectFirst
            : initialProcessingBackend
        self.selectedProcessingBackend = normalizedBackend
        self.toastPresenter = GuidanceToastPresenter()
        self.hapticEngine = GuidanceHapticEngine()
        self.completionBridge = ScanCompletionBridge(hapticEngine: hapticEngine)
        self.renderPipeline = nil

        setupThermalMonitoring()
        poseStabilizer = nil
        refreshCaptureGuidance(force: true)
    }

    deinit {
        elapsedTimer?.invalidate()
        if let observer = thermalObserver {
            NotificationCenter.default.removeObserver(observer)
        }
    }

    // MARK: - World-State Export Helpers

    nonisolated private static func extractRawWorldStateTiles(
        from renderData: PipelineCoordinatorBridge.RenderData?
    ) -> [RawWorldStateTile] {
        #if canImport(CAetherNativeBridge)
        guard let renderData,
              renderData.pointCloudCount > 0,
              let pointCloudVertices = renderData.pointCloudVertices else {
            return []
        }
        let floatsPerPoint = 8
        let totalFloats = renderData.pointCloudCount * floatsPerPoint
        let pointPointer = pointCloudVertices.bindMemory(
            to: Float.self,
            capacity: totalFloats
        )
        let values = UnsafeBufferPointer(start: pointPointer, count: totalFloats)

        struct BucketAccum {
            var positionSum = SIMD3<Float>(repeating: 0)
            var colorSum = SIMD3<Float>(repeating: 0)
            var count = 0
        }

        var points: [SIMD3<Float>] = []
        points.reserveCapacity(renderData.pointCloudCount)
        var buckets: [Int64: BucketAccum] = [:]
        buckets.reserveCapacity(max(32, renderData.pointCloudCount / 2))

        for index in 0..<renderData.pointCloudCount {
            let base = index * floatsPerPoint
            let alpha = values[base + 7]
            guard alpha > 0.0001 else { continue }

            let point = SIMD3<Float>(values[base + 0], values[base + 1], values[base + 2])
            guard point.x.isFinite, point.y.isFinite, point.z.isFinite else { continue }

            let color = SIMD3<Float>(
                max(0.0, min(1.0, values[base + 3])),
                max(0.0, min(1.0, values[base + 4])),
                max(0.0, min(1.0, values[base + 5]))
            )

            points.append(point)

            let cell = overlayCellIndices(for: point)
            let key = packOverlayCellKey(gx: cell.gx, gy: cell.gy, gz: cell.gz)
            var bucket = buckets[key] ?? BucketAccum()
            bucket.positionSum += point
            bucket.colorSum += color
            bucket.count += 1
            buckets[key] = bucket
        }
        guard !points.isEmpty, !buckets.isEmpty else { return [] }

        let surfaceIndex = buildSurfaceIndex(from: points)
        let defaultNormal = SIMD3<Float>(0.0, 1.0, 0.0)
        let halfSize = worldStateGridCell * 0.45

        return buckets.keys.sorted().compactMap { key in
            guard let bucket = buckets[key], bucket.count > 0 else { return nil }
            let invCount = 1.0 / Float(bucket.count)
            let center = bucket.positionSum * invCount
            let avgColor = bucket.colorSum * invCount

            let normal: SIMD3<Float> = {
                guard let surfaceIndex else { return defaultNormal }
                let candidateIndices = candidateSurfaceIndices(around: center, surfaceIndex: surfaceIndex, maxRings: 2)
                guard !candidateIndices.isEmpty else { return defaultNormal }
                let radius = worldStateSurfaceNormalRadius
                var neighbors: [SIMD3<Float>] = []
                neighbors.reserveCapacity(16)
                for idx in candidateIndices {
                    let point = surfaceIndex.points[idx]
                    if simd_length(point - center) <= radius {
                        neighbors.append(point)
                    }
                }
                if neighbors.count < 3 {
                    let sorted = candidateIndices
                        .map { surfaceIndex.points[$0] }
                        .sorted { simd_length($0 - center) < simd_length($1 - center) }
                    neighbors = Array(sorted.prefix(8))
                }
                guard neighbors.count >= 3 else { return defaultNormal }
                return estimatePlaneNormal(from: neighbors, preferredNormal: defaultNormal)
            }()

            return RawWorldStateTile(
                center: center,
                normal: normal,
                size: halfSize,
                quality: pointmapDisplayQuality(from: avgColor)
            )
        }
        #else
        _ = renderData
        return []
        #endif
    }

    nonisolated private static func sampleSurfacePoints(
        from renderData: PipelineCoordinatorBridge.RenderData?
    ) -> [SIMD3<Float>] {
        #if canImport(CAetherNativeBridge)
        guard let renderData,
              renderData.pointCloudCount > 0,
              let pointCloudVertices = renderData.pointCloudVertices else {
            return []
        }
        let floatsPerPoint = 8
        let totalFloats = renderData.pointCloudCount * floatsPerPoint
        let pointPointer = pointCloudVertices.bindMemory(
            to: Float.self,
            capacity: totalFloats
        )
        let values = UnsafeBufferPointer(start: pointPointer, count: totalFloats)
        let step = max(1, renderData.pointCloudCount / worldStateSurfaceMaxPoints)
        var points: [SIMD3<Float>] = []
        points.reserveCapacity(max(1, renderData.pointCloudCount / step))
        var index = 0
        while index < renderData.pointCloudCount {
            let base = index * floatsPerPoint
            let alpha = values[base + 7]
            let point = SIMD3<Float>(values[base + 0], values[base + 1], values[base + 2])
            if alpha > 0.0001,
               point.x.isFinite,
               point.y.isFinite,
               point.z.isFinite {
                points.append(point)
            }
            index += step
        }
        return points
        #else
        _ = renderData
        return []
        #endif
    }

    nonisolated private static func makeWorldStateExport(
        sceneID: String,
        frames: [RawWorldStateFrame],
        surfacePoints: [SIMD3<Float>]
    ) -> WorldStateExport {
        let surfaceIndex = buildSurfaceIndex(from: surfacePoints)
        var seenCounts: [String: Int] = [:]
        let exportedFrames = frames.map { frame in
            WorldStateFrame(
                frame_index: frame.frameIndex,
                timestamp_s: frame.timestampS,
                coverage: frame.coverage,
                tiles: deriveWorldStateTiles(
                    from: frame.tiles,
                    seenCounts: &seenCounts,
                    surfaceIndex: surfaceIndex
                )
            )
        }
        return WorldStateExport(
            version: worldStateSchemaVersion,
            meta: WorldStateMeta(
                scene_id: sceneID,
                cell_level: 0,
                notes: "Derived from Aether pointmap vertices. Tile state is a monotonic visibility-persistence proxy. Surface fields are approximated from the exported point cloud at capture stop."
            ),
            frames: exportedFrames
        )
    }

    nonisolated private static func deriveWorldStateTiles(
        from rawTiles: [RawWorldStateTile],
        seenCounts: inout [String: Int],
        surfaceIndex: SurfaceIndex?
    ) -> [WorldStateTile] {
        guard !rawTiles.isEmpty else { return [] }

        var drafts: [DerivedTileDraft] = []
        drafts.reserveCapacity(rawTiles.count)

        for rawTile in rawTiles {
            let normalizedNormal = normalize(rawTile.normal)
            let cell = overlayCellIndices(for: rawTile.center)
            let cellKey = packOverlayCellKey(gx: cell.gx, gy: cell.gy, gz: cell.gz)
            let cellID = "spatial:\(cellKey)|grid:\(cell.gx):\(cell.gy):\(cell.gz)"
            let tileID = "tile:\(cellKey)"
            let seenCount = (seenCounts[tileID] ?? 0) + 1
            seenCounts[tileID] = seenCount

            let corners = tileCorners(
                center: rawTile.center,
                normal: normalizedNormal,
                halfSize: rawTile.size
            )
            let uv = planeGridCoordinates(for: rawTile.center, normal: normalizedNormal)
            let surfaceMetrics = deriveSurfaceMetrics(
                center: rawTile.center,
                corners: corners,
                normal: normalizedNormal,
                surfaceIndex: surfaceIndex
            )
            drafts.append(
                DerivedTileDraft(
                    tile: WorldStateTile(
                        tile_id: tileID,
                        cell_id: cellID,
                        state: worldState(forVisibilitySamples: seenCount),
                        visible: true,
                        center: vectorArray(rawTile.center),
                        normal: vectorArray(normalizedNormal),
                        corners: corners.map(vectorArray),
                        u: uv.u,
                        v: uv.v,
                        neighbors: [],
                        surface_center_distance_mm: surfaceMetrics.centerDistanceMM,
                        surface_normal_dot: surfaceMetrics.normalDot,
                        surface_corner_support: surfaceMetrics.cornerSupport
                    ),
                    center: rawTile.center,
                    normal: normalizedNormal,
                    size: rawTile.size
                )
            )
        }

        var neighborsByIndex = Array(repeating: [WorldStateNeighbor](), count: drafts.count)
        for i in 0..<drafts.count {
            for j in (i + 1)..<drafts.count {
                guard let gapMm = sideGapIfAdjacent(lhs: drafts[i], rhs: drafts[j]) else {
                    continue
                }
                neighborsByIndex[i].append(
                    WorldStateNeighbor(tile_id: drafts[j].tile.tile_id, gap_mm: gapMm)
                )
                neighborsByIndex[j].append(
                    WorldStateNeighbor(tile_id: drafts[i].tile.tile_id, gap_mm: gapMm)
                )
            }
        }

        for index in drafts.indices {
            drafts[index].tile = WorldStateTile(
                tile_id: drafts[index].tile.tile_id,
                cell_id: drafts[index].tile.cell_id,
                state: drafts[index].tile.state,
                visible: drafts[index].tile.visible,
                center: drafts[index].tile.center,
                normal: drafts[index].tile.normal,
                corners: drafts[index].tile.corners,
                u: drafts[index].tile.u,
                v: drafts[index].tile.v,
                neighbors: neighborsByIndex[index].sorted { lhs, rhs in
                    if lhs.gap_mm == rhs.gap_mm {
                        return lhs.tile_id < rhs.tile_id
                    }
                    return lhs.gap_mm < rhs.gap_mm
                },
                surface_center_distance_mm: drafts[index].tile.surface_center_distance_mm,
                surface_normal_dot: drafts[index].tile.surface_normal_dot,
                surface_corner_support: drafts[index].tile.surface_corner_support
            )
        }

        return drafts.map(\.tile)
    }

    nonisolated private static func worldState(forVisibilitySamples seenCount: Int) -> String {
        if seenCount >= worldStateLockedSamples {
            return "locked"
        }
        if seenCount >= worldStateConfirmedSamples {
            return "confirmed"
        }
        return "provisional"
    }

    nonisolated private static func overlayCellIndices(for position: SIMD3<Float>) -> (gx: Int, gy: Int, gz: Int) {
        (
            gx: Int(floor(position.x / worldStateGridCell)),
            gy: Int(floor(position.y / worldStateGridCell)),
            gz: Int(floor(position.z / worldStateGridCell))
        )
    }

    nonisolated private static func surfaceCellIndices(for position: SIMD3<Float>) -> (gx: Int, gy: Int, gz: Int) {
        (
            gx: Int(floor(position.x / worldStateSurfaceCell)),
            gy: Int(floor(position.y / worldStateSurfaceCell)),
            gz: Int(floor(position.z / worldStateSurfaceCell))
        )
    }

    nonisolated private static func packOverlayCellKey(gx: Int, gy: Int, gz: Int) -> Int64 {
        let ox = Int64(gx + 2048)
        let oy = Int64(gy + 2048)
        let oz = Int64(gz + 2048)
        return (ox << 24) ^ (oy << 12) ^ oz
    }

    nonisolated private static func buildSurfaceIndex(from points: [SIMD3<Float>]) -> SurfaceIndex? {
        guard !points.isEmpty else { return nil }
        var buckets: [Int64: [Int]] = [:]
        buckets.reserveCapacity(max(64, points.count / 6))
        for (index, point) in points.enumerated() {
            let cell = surfaceCellIndices(for: point)
            let key = packOverlayCellKey(gx: cell.gx, gy: cell.gy, gz: cell.gz)
            buckets[key, default: []].append(index)
        }
        return SurfaceIndex(points: points, buckets: buckets)
    }

    nonisolated private static func candidateSurfaceIndices(
        around query: SIMD3<Float>,
        surfaceIndex: SurfaceIndex,
        maxRings: Int = worldStateSurfaceSearchRings
    ) -> [Int] {
        let cell = surfaceCellIndices(for: query)
        for ring in 0...maxRings {
            var indices: [Int] = []
            for gx in (cell.gx - ring)...(cell.gx + ring) {
                for gy in (cell.gy - ring)...(cell.gy + ring) {
                    for gz in (cell.gz - ring)...(cell.gz + ring) {
                        let key = packOverlayCellKey(gx: gx, gy: gy, gz: gz)
                        if let bucket = surfaceIndex.buckets[key] {
                            indices.append(contentsOf: bucket)
                        }
                    }
                }
            }
            if !indices.isEmpty {
                return indices
            }
        }
        return []
    }

    nonisolated private static func nearestSurfaceDistance(
        to query: SIMD3<Float>,
        surfaceIndex: SurfaceIndex
    ) -> Float? {
        let indices = candidateSurfaceIndices(around: query, surfaceIndex: surfaceIndex)
        guard !indices.isEmpty else { return nil }
        var best = Float.greatestFiniteMagnitude
        for idx in indices {
            let distance = simd_length(surfaceIndex.points[idx] - query)
            if distance < best {
                best = distance
            }
        }
        return best.isFinite ? best : nil
    }

    nonisolated private static func localSurfaceNormalDot(
        center: SIMD3<Float>,
        tileNormal: SIMD3<Float>,
        surfaceIndex: SurfaceIndex
    ) -> Double? {
        let indices = candidateSurfaceIndices(around: center, surfaceIndex: surfaceIndex, maxRings: 3)
        guard !indices.isEmpty else { return nil }
        let radius = worldStateSurfaceNormalRadius
        var neighbors: [SIMD3<Float>] = []
        neighbors.reserveCapacity(32)
        for idx in indices {
            let point = surfaceIndex.points[idx]
            if simd_length(point - center) <= radius {
                neighbors.append(point)
            }
        }
        if neighbors.count < 3 {
            let sorted = indices
                .map { surfaceIndex.points[$0] }
                .sorted { simd_length($0 - center) < simd_length($1 - center) }
            neighbors = Array(sorted.prefix(8))
        }
        guard neighbors.count >= 3 else { return nil }
        let estimated = estimatePlaneNormal(from: neighbors, preferredNormal: tileNormal)
        let dot = simd_dot(normalize(estimated), normalize(tileNormal))
        return Double(max(-1.0, min(1.0, dot)))
    }

    nonisolated private static func estimatePlaneNormal(
        from points: [SIMD3<Float>],
        preferredNormal: SIMD3<Float>
    ) -> SIMD3<Float> {
        let count = Float(points.count)
        let centroid = points.reduce(SIMD3<Float>(repeating: 0), +) / count
        var cxx: Float = 0
        var cxy: Float = 0
        var cxz: Float = 0
        var cyy: Float = 0
        var cyz: Float = 0
        var czz: Float = 0
        for point in points {
            let d = point - centroid
            cxx += d.x * d.x
            cxy += d.x * d.y
            cxz += d.x * d.z
            cyy += d.y * d.y
            cyz += d.y * d.z
            czz += d.z * d.z
        }
        let scale = 1.0 / max(1.0, count - 1.0)
        var matrix = [
            [cxx * scale, cxy * scale, cxz * scale],
            [cxy * scale, cyy * scale, cyz * scale],
            [cxz * scale, cyz * scale, czz * scale]
        ]
        var eigenvectors = [
            [Float(1), Float(0), Float(0)],
            [Float(0), Float(1), Float(0)],
            [Float(0), Float(0), Float(1)]
        ]
        for _ in 0..<12 {
            var p = 0
            var q = 1
            var maxValue = abs(matrix[0][1])
            for i in 0..<3 {
                for j in (i + 1)..<3 {
                    let value = abs(matrix[i][j])
                    if value > maxValue {
                        maxValue = value
                        p = i
                        q = j
                    }
                }
            }
            if maxValue < 1e-6 {
                break
            }
            let phi = 0.5 * atan2(2.0 * matrix[p][q], matrix[q][q] - matrix[p][p])
            let c = cos(phi)
            let s = sin(phi)
            for i in 0..<3 {
                let mip = matrix[i][p]
                let miq = matrix[i][q]
                matrix[i][p] = c * mip - s * miq
                matrix[i][q] = s * mip + c * miq
            }
            for j in 0..<3 {
                let mpj = matrix[p][j]
                let mqj = matrix[q][j]
                matrix[p][j] = c * mpj - s * mqj
                matrix[q][j] = s * mpj + c * mqj
            }
            matrix[p][q] = 0
            matrix[q][p] = 0
            for i in 0..<3 {
                let vip = eigenvectors[i][p]
                let viq = eigenvectors[i][q]
                eigenvectors[i][p] = c * vip - s * viq
                eigenvectors[i][q] = s * vip + c * viq
            }
        }
        let eigenvalues = [matrix[0][0], matrix[1][1], matrix[2][2]]
        let minIndex = eigenvalues.enumerated().min { lhs, rhs in lhs.element < rhs.element }?.offset ?? 0
        var normal = SIMD3<Float>(
            eigenvectors[0][minIndex],
            eigenvectors[1][minIndex],
            eigenvectors[2][minIndex]
        )
        normal = normalize(normal)
        if simd_dot(normal, preferredNormal) < 0 {
            normal = -normal
        }
        return normal
    }

    nonisolated private static func deriveSurfaceMetrics(
        center: SIMD3<Float>,
        corners: [SIMD3<Float>],
        normal: SIMD3<Float>,
        surfaceIndex: SurfaceIndex?
    ) -> (centerDistanceMM: Double?, normalDot: Double?, cornerSupport: [Bool]?) {
        guard let surfaceIndex else {
            return (nil, nil, nil)
        }
        let centerDistance = nearestSurfaceDistance(to: center, surfaceIndex: surfaceIndex)
        let centerDistanceMM = centerDistance.map { Double($0 * 1000.0) }
        let supportThreshold = worldStateSurfaceSupportThresholdMM / 1000.0
        let cornerSupport = corners.map { corner in
            guard let distance = nearestSurfaceDistance(to: corner, surfaceIndex: surfaceIndex) else {
                return false
            }
            return distance <= supportThreshold
        }
        let normalDot = localSurfaceNormalDot(center: center, tileNormal: normal, surfaceIndex: surfaceIndex)
        return (centerDistanceMM, normalDot, cornerSupport)
    }

    nonisolated private static func normalize(_ vector: SIMD3<Float>) -> SIMD3<Float> {
        let length = simd_length(vector)
        if length > 1e-6 {
            return vector / length
        }
        return SIMD3<Float>(0.0, 1.0, 0.0)
    }

    nonisolated private static func pointmapDisplayQuality(from color: SIMD3<Float>) -> Float {
        let anchors: [(SIMD3<Float>, Float)] = [
            (SIMD3<Float>(1.0, 0.25, 0.15), 0.17),
            (SIMD3<Float>(1.0, 0.78, 0.18), 0.51),
            (SIMD3<Float>(0.18, 0.95, 0.32), 0.84)
        ]
        var weightedQuality: Float = 0
        var totalWeight: Float = 0
        for (anchor, quality) in anchors {
            let distance = max(0.001, simd_length(color - anchor))
            let weight = 1.0 / (distance * distance)
            weightedQuality += weight * quality
            totalWeight += weight
        }
        guard totalWeight > 0 else { return 0.51 }
        return max(0.0, min(1.0, weightedQuality / totalWeight))
    }

    nonisolated private static func buildTileBasis(normal: SIMD3<Float>) -> (tangent: SIMD3<Float>, bitangent: SIMD3<Float>) {
        let up = abs(normal.y) < 0.9
            ? SIMD3<Float>(0.0, 1.0, 0.0)
            : SIMD3<Float>(1.0, 0.0, 0.0)
        let tangent = normalize(simd_cross(up, normal))
        let bitangent = normalize(simd_cross(normal, tangent))
        return (tangent, bitangent)
    }

    nonisolated private static func tileCorners(
        center: SIMD3<Float>,
        normal: SIMD3<Float>,
        halfSize: Float
    ) -> [SIMD3<Float>] {
        let basis = buildTileBasis(normal: normal)
        let tangent = basis.tangent
        let bitangent = basis.bitangent
        let signs: [(Float, Float)] = [(-1, -1), (1, -1), (1, 1), (-1, 1)]
        return signs.map { sign in
            center + sign.0 * halfSize * tangent + sign.1 * halfSize * bitangent
        }
    }

    nonisolated private static func planeGridCoordinates(
        for center: SIMD3<Float>,
        normal: SIMD3<Float>
    ) -> (u: Int, v: Int) {
        let absNormal = SIMD3<Float>(abs(normal.x), abs(normal.y), abs(normal.z))
        if absNormal.y >= absNormal.x && absNormal.y >= absNormal.z {
            return (Int(floor(center.x / worldStateGridCell)), Int(floor(center.z / worldStateGridCell)))
        }
        if absNormal.x >= absNormal.y && absNormal.x >= absNormal.z {
            return (Int(floor(center.z / worldStateGridCell)), Int(floor(center.y / worldStateGridCell)))
        }
        return (Int(floor(center.x / worldStateGridCell)), Int(floor(center.y / worldStateGridCell)))
    }

    nonisolated private static func sideGapIfAdjacent(lhs: DerivedTileDraft, rhs: DerivedTileDraft) -> Double? {
        let normalDot = simd_dot(lhs.normal, rhs.normal)
        if normalDot < 0.85 {
            return nil
        }
        let centerDistance = simd_length(lhs.center - rhs.center)
        if centerDistance > 0.11 {
            return nil
        }

        let avgNormal = normalize(lhs.normal + rhs.normal)
        let basis = buildTileBasis(normal: avgNormal)
        let delta = rhs.center - lhs.center
        let du = abs(simd_dot(delta, basis.tangent))
        let dv = abs(simd_dot(delta, basis.bitangent))
        let halfSum = lhs.size + rhs.size

        let nu = du / worldStateGridCell
        let nv = dv / worldStateGridCell
        let err10 = hypotf(nu - 1.0, nv)
        let err01 = hypotf(nu, nv - 1.0)
        if min(err10, err01) >= 0.30 {
            return nil
        }
        let axisSeparation = err10 <= err01 ? du : dv
        let gapMm = Double(max(0.0, axisSeparation - halfSum) * 1000.0)
        return gapMm
    }

    nonisolated private static func vectorArray(_ vector: SIMD3<Float>) -> [Double] {
        [Double(vector.x), Double(vector.y), Double(vector.z)]
    }

    // ═══════════════════════════════════════════════════════════════════════
    // MARK: - State Machine Transitions
    // ═══════════════════════════════════════════════════════════════════════

    func transition(to newState: ScanState) {
        if scanState == newState { return }
        guard scanState.allowedTransitions.contains(newState) else {
            #if DEBUG
            print("[Aether3D] Rejected state transition: \(scanState) → \(newState)")
            #endif
            return
        }

        let oldState = scanState
        scanState = newState

        switch (oldState, newState) {
        case (_, .ready):
            liveGuidanceTitle = "可以开始拍摄了"
            liveGuidanceDetail = "围绕物体缓慢移动，先拍正面，再补侧面和顶部。"
            scanFailureMessage = nil
            sessionPauseMessage = nil
            if !isSubjectFirstLocalMode {
                initializeCoordinatorIfNeeded(processingBackend: selectedProcessingBackend)
            }

        case (_, .capturing):
            isCapturing = true
            captureStartTime = captureStartTime ?? Date()
            sessionPauseMessage = nil
            scanFailureMessage = nil
            startElapsedTimer()

        case (.capturing, .paused):
            isCapturing = false
            sessionPauseMessage = sessionPauseMessage ?? "扫描已暂停。你可以继续拍摄，也可以直接结束生成。"
            stopElapsedTimer()

        case (_, .finishing):
            isCapturing = false
            liveGuidanceTitle = "正在整理扫描结果"
            liveGuidanceDetail = isSubjectFirstLocalMode
                ? "这次会先保存拍摄视频，再在手机上继续跑本地处理链路。"
                : "稍后会直接进入远端训练与 3DGS 回传。"
            stopElapsedTimer()
            NotificationCenter.default.post(name: .scanDidComplete, object: nil)

        case (_, .completed):
            isCapturing = false
            resetSubsystems()

        case (_, .failed):
            isCapturing = false
            if scanFailureMessage == nil {
                scanFailureMessage = "扫描流程中断了，请回到主页重新开始。"
            }
            stopElapsedTimer()
            resetSubsystems()

        default:
            break
        }

        refreshCaptureGuidance()
    }

    func executeScanActionPlan(_ plan: ScanActionPlan) {
        guard plan.actionMask.contains(.applyTransition),
              let targetState = plan.transitionTargetState else {
            return
        }
        transition(to: targetState)
    }

    // ═══════════════════════════════════════════════════════════════════════
    // MARK: - User Actions
    // ═══════════════════════════════════════════════════════════════════════

    func prepareCapture(processingBackend: ProcessingBackendChoice) {
        selectedProcessingBackend = processingBackend

        // If the user switched backend before starting capture, discard the old
        // coordinator so the next preload/recording path uses the correct profile.
        if let currentBackend = self.activeCoordinatorBackend,
           currentBackend != processingBackend,
           coordinatorBridge != nil,
           !isInitializingCoordinator {
            teardownCoordinatorAsync()
            debugBridgeReady = false
            self.activeCoordinatorBackend = nil
        }

        if scanState == .ready && processingBackend != .localSubjectFirst {
            initializeCoordinatorIfNeeded(processingBackend: processingBackend)
        }
    }

    func startCapture(processingBackend: ProcessingBackendChoice) {
        prepareCapture(processingBackend: processingBackend)
        worldStateRecorder.reset()
        if processingBackend == .cloud {
            prepareRemoteVideoRecorderIfNeeded(targetFPS: 18.0)
        } else if processingBackend == .localSubjectFirst {
            prepareRemoteVideoRecorderIfNeeded(targetFPS: 2.0)
        } else {
            #if canImport(AVFoundation)
            remoteVideoRecorder?.cancel()
            remoteVideoRecorder = nil
            remoteVideoRecorderMinFrameStep = 0
            lastRemoteVideoFrameEnqueueTimestamp = nil
            #endif
        }
        backgroundExportStatusMessage = nil
        coordinatorNotReady = false
        scanFailureMessage = nil
        let waitForCoordinatorBeforeCapture =
            processingBackend != .localSubjectFirst &&
            processingBackend.usesLocalPreviewPipeline &&
            (coordinatorBridge == nil || isInitializingCoordinator)
        pendingCaptureStartAfterCoordinatorReady = waitForCoordinatorBeforeCapture
        transition(to: .capturing)
        refreshCaptureGuidance(force: true)
        if processingBackend == .localSubjectFirst {
            DispatchQueue.main.async { [weak self] in
                self?.initializeCoordinatorIfNeeded(processingBackend: processingBackend)
            }
        } else {
            initializeCoordinatorIfNeeded(processingBackend: processingBackend)
        }
    }

    func pauseCapture() {
        sessionPauseMessage = "扫描已暂停。你可以继续拍摄，也可以直接结束生成。"
        transition(to: .paused)
    }

    func resumeCapture() {
        sessionPauseMessage = nil
        transition(to: .capturing)
    }

    func handleSessionInterrupted() {
        pauseCapture()
        sessionPauseMessage = "系统中断了当前拍摄，已自动暂停。"
        refreshCaptureGuidance()
    }

    func handleSessionFailure(_ message: String) {
        scanFailureMessage = message
        if scanState.allowedTransitions.contains(.failed) {
            transition(to: .failed)
        }
    }

    /// Signal pipeline to finish scanning (non-blocking, no export).
    /// Called from ScanView.handleStop() for immediate navigation.
    func finishScanningOnly() {
        _ = coordinatorBridge?.finishScanning()
    }

    /// Signal that user has entered the 3D viewer space.
    /// Triggers sequential fly-in animation for completed regions.
    func signalViewerEntered() {
        coordinatorBridge?.signalViewerEntered()
    }

    /// Stop capture and export. Heavy work runs on background thread via Task.detached.
    /// Caller awaits the result; UI stays responsive because MainActor is not blocked.
    func stopCapture() async -> ScanRecord? {
        NSLog("[Aether3D] stopCapture: state=%@ canFinish=%@",
              scanState.rawValue, scanState.canFinish ? "YES" : "NO")
        guard scanState.canFinish else {
            NSLog("[Aether3D] stopCapture: canFinish=false, returning nil")
            return nil
        }

        _ = coordinatorBridge?.finishScanning()
        transition(to: .finishing)

        let bridge = coordinatorBridge
        let coverage = coveragePercent
        let duration = elapsedTime
        let recordId = UUID()
        let worldStateFrames = worldStateRecorder.snapshot()

        // If coordinator never loaded (still initializing), skip export entirely.
        // No frames were processed → nothing to export → no 3D viewer possible.
        guard bridge != nil else {
            NSLog("[Aether3D] stopCapture: coordinator not ready — no data to export (is still initializing: %@)",
                  isInitializingCoordinator ? "YES" : "NO")
            coordinatorNotReady = true
            return ScanRecord(
                id: UUID(), name: nil, createdAt: Date(),
                thumbnailPath: nil, artifactPath: nil,
                captureIntent: nil,
                coveragePercentage: 0, triangleCount: 0,
                durationSeconds: duration)
        }

        isExporting = true

        // Heavy work on background thread; await resumes on MainActor.
        let record: ScanRecord? = await Task.detached(priority: .userInitiated) {
            NSLog("[Aether3D] stopCapture: bridge=%@, starting waitForTraining",
                  bridge != nil ? "valid" : "nil")

            // Wait for training to converge (up to 4s).
            let stepsReached = bridge?.waitForTraining(
                minSteps: 300, timeoutSeconds: 4.0) ?? 0
            NSLog("[Aether3D] Training reached %d steps before export (isTraining=%@, isGPU=%@)",
                  stepsReached,
                  bridge?.isTraining == true ? "YES" : "NO",
                  bridge?.isGPUTraining == true ? "YES" : "NO")

            // Export PLY
            var artifactPath: String?

            let documents = FileManager.default.urls(
                for: .documentDirectory, in: .userDomainMask)[0]
            let exportDir = documents
                .appendingPathComponent("Aether3D")
                .appendingPathComponent("exports")
            try? FileManager.default.createDirectory(
                at: exportDir, withIntermediateDirectories: true)

            let plyURL = exportDir.appendingPathComponent("\(recordId.uuidString).ply")
            let surfaceSamples = {
                let copied = bridge?.copySurfacePoints(
                    maxPoints: Int(ScanViewModel.worldStateSurfaceMaxPoints)
                ) ?? []
                if !copied.isEmpty {
                    return copied
                }
                return ScanViewModel.sampleSurfacePoints(from: bridge?.getRenderData())
            }()
            NSLog("[Aether3D] Attempting exportPLY to: %@", plyURL.path)
            if bridge?.exportPLY(path: plyURL.path) == true {
                artifactPath = "exports/\(recordId.uuidString).ply"
                NSLog("[Aether3D] ✅ Exported trained PLY: %@", plyURL.path)
            } else {
                NSLog("[Aether3D] exportPLY failed, trying point cloud fallback")
                if bridge?.exportPointCloudPLY(path: plyURL.path) == true {
                    artifactPath = "exports/\(recordId.uuidString).ply"
                    NSLog("[Aether3D] ✅ Fallback: exported point cloud PLY: %@", plyURL.path)
                } else {
                    NSLog("[Aether3D] ❌ ERROR: Both trained and point cloud exports failed!")
                }
            }

            if !worldStateFrames.isEmpty {
                let worldStateURL = exportDir.appendingPathComponent("\(recordId.uuidString).world_state.json")
                do {
                    let exportPayload = ScanViewModel.makeWorldStateExport(
                        sceneID: recordId.uuidString,
                        frames: worldStateFrames,
                        surfacePoints: surfaceSamples
                    )
                    let encoder = JSONEncoder()
                    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
                    let data = try encoder.encode(exportPayload)
                    try data.write(to: worldStateURL, options: .atomic)
                    NSLog("[Aether3D] ✅ Exported world-state JSON: %@", worldStateURL.path)
                } catch {
                    NSLog("[Aether3D] ❌ Failed to export world-state JSON: %@", String(describing: error))
                }
            } else {
                NSLog("[Aether3D] World-state recorder empty; skipping JSON export")
            }

            return ScanRecord(
                id: recordId, name: nil, createdAt: Date(),
                thumbnailPath: nil, artifactPath: artifactPath,
                captureIntent: nil,
                coveragePercentage: Double(coverage), triangleCount: 0,
                durationSeconds: duration)
        }.value

        isExporting = false
        return record
    }

    /// Expose render pipeline for overlay draw delegation.
    #if canImport(Metal)
    func currentRenderPipelineForOverlay() -> PointCloudOIRPipeline? {
        ensureRenderPipelineIfNeeded()
        return renderPipeline
    }
    #endif

    #if canImport(Metal)
    private func ensureRenderPipelineIfNeeded() {
        guard renderPipeline == nil else { return }
        guard let device = MTLCreateSystemDefaultDevice() else { return }
        renderPipeline = try? PointCloudOIRPipeline(device: device)
    }
    #endif

    // ═══════════════════════════════════════════════════════════════════════
    // MARK: - ARKit Frame Processing
    // ═══════════════════════════════════════════════════════════════════════

    /// Called from ARSCNView delegate on EVERY frame (~60 FPS).
    /// Heavy work (CIContext conversion + C++ forwarding) is throttled to ~15fps.
    /// Light work (snapshot reads + Metal overlay update) runs every frame for smooth UI.
    func processARFrame(
        timestamp: TimeInterval,
        cameraTransform: simd_float4x4,
        lightEstimate: LightEstimateSnapshot?,
        meshAnchors: [ARMeshAnchor],
        viewMatrix: simd_float4x4? = nil,
        projectionMatrix: simd_float4x4? = nil,
        pixelBuffer: CVPixelBuffer? = nil,
        cameraIntrinsics: simd_float3x3? = nil,
        lidarDepthBuffer: CVPixelBuffer? = nil,
        featurePoints: [SIMD3<Float>]? = nil
    ) {
        guard scanState.isActive else { return }
        frameCounter += 1
        debugFrameCount = frameCounter
        debugBridgeReady = (coordinatorBridge != nil)
        if shouldRecordRemoteVideoForSelectedBackend {
            appendRemoteVideoFrame(pixelBuffer: pixelBuffer, timestamp: timestamp)
        }

        // Update coordinator init elapsed time while waiting
        if isInitializingCoordinator && coordinatorInitStartTime > 0 {
            debugCoordinatorInitTime = CFAbsoluteTimeGetCurrent() - coordinatorInitStartTime
        }

        let stabilizedTransform = stabilizedCameraTransform(
            rawCameraTransform: cameraTransform,
            timestamp: timestamp
        )

        // ─── Throttled: Only forward every Nth frame to C++ (expensive) ───
        let shouldForwardToPipeline =
            (frameCounter % max(1, pipelineFrameInterval) == 0)

        if shouldForwardToPipeline {
            // DAv2 depth inference now handled by C++ PipelineCoordinator internally.
            // Swift passes ne_depth=nil; C++ runs async Neural Engine inference itself.
            // When DAv2 is not yet ready, C++ VIO fallback uses ARKit feature points
            // (metric scale from IMU — VINGS-Mono approach) for immediate TSDF coverage.

            // Only count frames ACTUALLY forwarded to a live coordinator.
            // Previous bug: counter incremented even when coordinatorBridge==nil
            // (coordinator still loading CoreML models), making "管线" count misleading.
            if coordinatorBridge != nil {
                debugPipelineFrameCount += 1
            }

            // Forward frame to C++ coordinator (includes CIContext conversion).
            // LiDAR provides metric depth (meters) when available (LiDAR devices).
            // Non-LiDAR: C++ uses DAv2 + ARKit VIO feature-point affine calibration.
            forwardFrameToCoordinator(
                cameraTransform: stabilizedTransform,
                timestamp: timestamp,
                pixelBuffer: pixelBuffer,
                cameraIntrinsics: cameraIntrinsics,
                lidarDepthBuffer: lidarDepthBuffer,
                featurePoints: featurePoints
            )
        }

        // ─── Every frame: Read snapshot from C++ (lock-free, <1μs) ───
        #if canImport(CAetherNativeBridge)
        let now = CFAbsoluteTimeGetCurrent()
        let shouldPublishHUD = shouldPublishCaptureHUD(now: now)
        let shouldRecordWorldStateFrame = isSubjectFirstLocalMode ? shouldForwardToPipeline : true
        if let snapshot = coordinatorBridge?.getSnapshot(), shouldPublishHUD {
            coveragePercent = snapshot.coverage
            trainingProgress = snapshot.training_progress
            trainingActive = snapshot.training_active != 0
            debugSelectedFrames = Int(snapshot.selected_frames)
            debugMinFramesNeeded = Int(snapshot.min_frames_needed)
            debugKeyframeGateAccepts = Int(snapshot.preview_keyframe_gate_accepts)
            debugKeyframeGateRejects = Int(snapshot.preview_keyframe_gate_rejects)
            debugIsGPUTraining = coordinatorBridge?.isGPUTraining ?? false
            debugHasS6Quality = snapshot.has_s6_quality != 0

            // 全局训练状态
            debugNumGaussians = Int(snapshot.num_gaussians)
            debugAssignedBlocks = Int(snapshot.assigned_blocks)
            debugPendingGaussians = Int(snapshot.pending_gaussian_count)
            debugPreviewSeedAccepted = Int(snapshot.preview_seed_accepted)
            debugPreviewSeedCandidates = Int(snapshot.preview_seed_candidates)
        }

        if let progress = coordinatorBridge?.trainingProgress(), shouldPublishHUD {
            if progress.total_steps > 0 {
                trainingProgress = Float(progress.step) / Float(progress.total_steps)
            }
            debugTrainingStep = Int(progress.step)
            debugTotalSteps = Int(progress.total_steps)
            debugLoss = progress.loss
        }
        #endif

        // Quality milestone toasts removed — TSDF overlay heatmap provides visual feedback.

        // ─── Every frame: Motion / exposure feedback ───
        let velocity = extractMotionMagnitude(from: stabilizedTransform, timestamp: timestamp)
        let feedbackTimestamp = ProcessInfo.processInfo.systemUptime
        let tier = thermalAdapter.currentTier
        let motionWarning = velocity > 0.7
        let stabilityWarning = lastPoseQuality < Self.poseMinimumAcceptedQuality

        // 0.7 m/s — inlined from former ScanGuidanceConstants.hapticMotionThreshold
        if tier.enableHaptics && motionWarning {
            _ = hapticEngine.fire(
                pattern: .motionTooFast,
                timestamp: feedbackTimestamp,
                toastPresenter: toastPresenter
            )
        }

        let ambientIntensity = lightEstimate?.ambientIntensity ?? 0.0
        let exposureWarning = lightEstimate.map { $0.ambientIntensity < 250.0 || $0.ambientIntensity > 5000.0 } ?? false
        let warningStateChanged =
            motionWarning != motionWarningActive ||
            stabilityWarning != stabilityWarningActive ||
            exposureWarning != exposureWarningActive

        if let lightEstimate {
            if tier.enableHaptics && exposureWarning {
                _ = hapticEngine.fire(
                    pattern: .exposureAbnormal,
                    timestamp: feedbackTimestamp,
                    toastPresenter: toastPresenter
                )
            }
        }

        var renderDataForFrame: PipelineCoordinatorBridge.RenderData?
        #if canImport(CAetherNativeBridge)
        let shouldReadRenderData = shouldRecordWorldStateFrame || shouldStreamOverlayPipelineDuringCapture
        if shouldReadRenderData {
            renderDataForFrame = coordinatorBridge?.getRenderData()
        }
        #endif

        if shouldPublishHUD || warningStateChanged {
            latestMotionSpeedMps = velocity
            motionWarningActive = motionWarning
            stabilityWarningActive = stabilityWarning
            if lightEstimate != nil {
                latestAmbientIntensity = ambientIntensity
            } else {
                latestAmbientIntensity = 0.0
            }
            exposureWarningActive = exposureWarning
            if renderDataForFrame != nil || coordinatorBridge == nil {
                updateCaptureGeometrySummary(from: renderDataForFrame)
            }
        } else if lightEstimate == nil {
            latestAmbientIntensity = 0.0
        }

        refreshCaptureGuidance(force: shouldPublishHUD || warningStateChanged, now: now)

        // ─── Every frame: Update Metal render pipeline (smooth 60fps overlay) ───

        #if canImport(Metal) && canImport(CAetherNativeBridge)
        if shouldStreamOverlayPipelineDuringCapture {
            ensureRenderPipelineIfNeeded()
        }
        if shouldStreamOverlayPipelineDuringCapture,
           let pipeline = renderPipeline,
           let vm = viewMatrix,
           let pm = projectionMatrix {
            let intrinsics = cameraIntrinsics ?? simd_float3x3(1)
            let fx = intrinsics[0][0]
            let fy = intrinsics[1][1]
            let vpW: Float = pixelBuffer.map { Float(CVPixelBufferGetWidth($0)) } ?? 1920
            let vpH: Float = pixelBuffer.map { Float(CVPixelBufferGetHeight($0)) } ?? 1080

            if let renderData = renderDataForFrame {
                let usePointmapPrimary = isSubjectFirstLocalMode && scanState == .capturing
                let liveOverlayVertices = usePointmapPrimary ? nil : renderData.overlayVertices
                let liveOverlayCount = usePointmapPrimary ? 0 : Int(renderData.overlayCount)
                let liveSplatData = usePointmapPrimary ? nil : renderData.packedSplats
                let liveSplatCount = usePointmapPrimary ? 0 : renderData.splatCount
                // ── Full pipeline: C++ → triple buffer → Metal ──
                pipeline.update(
                    pointCloudVertices: renderData.pointCloudVertices,
                    pointCloudCount: renderData.pointCloudCount,
                    splatData: liveSplatData,
                    splatCount: liveSplatCount,
                    overlayVertices: liveOverlayVertices,
                    overlayCount: liveOverlayCount,
                    viewMatrix: vm,
                    projectionMatrix: pm,
                    cameraTransform: stabilizedTransform,
                    globalPointCloudAlpha: renderData.pointCloudAlpha,
                    focal: SIMD2<Float>(fx, fy),
                    viewport: SIMD2<Float>(vpW, vpH)
                )
                // Debug stats from render data
                debugPointCloudCount = Int(renderData.pointCloudCount)
                debugOverlayCount = liveOverlayCount
                debugSplatCount = liveSplatCount
                debugPointCloudAlpha = renderData.pointCloudAlpha
            }
            // Read encode counters from Metal pipeline
            debugEncodeDrawCount = pipeline.debugEncodeDrawCount
            debugEncodeSkipCount = pipeline.debugEncodeSkipCount
            // Note: No fallback rendering while coordinator loads.
            // Camera feed is shown cleanly; C++ pipeline overlay appears once ready.
        }
        #endif

        if shouldRecordWorldStateFrame {
            worldStateRecorder.recordFrame(
                frameIndex: max(0, frameCounter - 1),
                timestamp: timestamp,
                coverage: coveragePercent,
                cameraIntrinsics: cameraIntrinsics,
                renderData: renderDataForFrame
            )
        }
    }

    // ═══════════════════════════════════════════════════════════════════════
    // MARK: - GPU Frame Timing
    // ═══════════════════════════════════════════════════════════════════════

    /// Report GPU frame duration (called from ARCameraPreview's commandBuffer completion handler).
    func reportGPUFrameTiming(durationMs: Double) {
        thermalAdapter.updateFrameTiming(gpuDurationMs: durationMs)
    }

    // ═══════════════════════════════════════════════════════════════════════
    // MARK: - C++ Pipeline Coordinator
    // ═══════════════════════════════════════════════════════════════════════

    /// Result of background coordinator creation (Sendable for cross-isolation transfer).
    struct CoordinatorHandles: @unchecked Sendable {
        let gpuDevice: OpaquePointer
        let splatEngine: OpaquePointer
        let bridge: PipelineCoordinatorBridge?
    }

    private final class CoordinatorTeardownBox: @unchecked Sendable {
        var bridge: PipelineCoordinatorBridge?

        init(_ bridge: PipelineCoordinatorBridge?) {
            self.bridge = bridge
        }
    }

    /// Create coordinator handles on any thread (no MainActor requirement).
    /// CoreML model loading (~10-30s) happens here — MUST be off-main.
    nonisolated static func createCoordinatorHandles(
        processingBackend: ProcessingBackendChoice
    ) -> CoordinatorHandles? {
        #if canImport(CAetherNativeBridge) && canImport(Metal)
        let t0 = CFAbsoluteTimeGetCurrent()
        NSLog("[Aether3D] Coordinator: starting creation for backend=%@", processingBackend.rawValue)

        // Step 1: Metal device
        guard let mtlDevice = MTLCreateSystemDefaultDevice() else {
            NSLog("[Aether3D] Coordinator FAILED at Step 1/4: MTLCreateSystemDefaultDevice returned nil")
            return nil
        }
        NSLog("[Aether3D] Coordinator Step 1/4: MTLDevice OK (%.1fs)", CFAbsoluteTimeGetCurrent() - t0)

        // Step 2: GPU device wrapper
        let mtlDevicePtr = Unmanaged.passUnretained(mtlDevice).toOpaque()
        guard let gpuDevice = aether_gpu_device_create_metal(mtlDevicePtr) else {
            NSLog("[Aether3D] Coordinator FAILED at Step 2/4: aether_gpu_device_create_metal (%.1fs)", CFAbsoluteTimeGetCurrent() - t0)
            return nil
        }
        NSLog("[Aether3D] Coordinator Step 2/4: GPU device OK (%.1fs)", CFAbsoluteTimeGetCurrent() - t0)

        // Step 3: Splat engine (Metal PSO compilation)
        var splatConfig = aether_splat_config_t()
        _ = aether_splat_default_config(&splatConfig)

        var splatEnginePtr: OpaquePointer?
        let rc = aether_splat_engine_create(
            UnsafeMutableRawPointer(gpuDevice), &splatConfig, &splatEnginePtr)
        guard rc == 0, let engine = splatEnginePtr else {
            NSLog("[Aether3D] Coordinator FAILED at Step 3/4: aether_splat_engine_create rc=%d (%.1fs)", rc, CFAbsoluteTimeGetCurrent() - t0)
            aether_gpu_device_destroy(gpuDevice)
            return nil
        }
        NSLog("[Aether3D] Coordinator Step 3/4: Splat engine OK (%.1fs)", CFAbsoluteTimeGetCurrent() - t0)

        // Step 4: Pipeline coordinator bridge (CoreML model loading — slowest step)
        let profile: PipelineCoordinatorProfile = processingBackend.usesLocalPreviewPipeline
            ? .localSubjectFirstMonocular
            : .cloudDefault
        let bridge = PipelineCoordinatorBridge(
            gpuDevicePtr: UnsafeMutableRawPointer(gpuDevice),
            splatEnginePtr: UnsafeMutableRawPointer(engine),
            profile: profile
        )
        NSLog("[Aether3D] Coordinator Step 4/4: Bridge=%@ (%.1fs total)", bridge != nil ? "OK" : "FAILED", CFAbsoluteTimeGetCurrent() - t0)

        return CoordinatorHandles(gpuDevice: gpuDevice, splatEngine: engine, bridge: bridge)
        #else
        return nil
        #endif
    }

    nonisolated static func makeLocalPreviewCoordinatorHandles(
        processingBackend: ProcessingBackendChoice
    ) -> CoordinatorHandles? {
        createCoordinatorHandles(processingBackend: processingBackend)
    }

    nonisolated static func destroyCoordinatorHandles(_ handles: CoordinatorHandles) {
        #if canImport(CAetherNativeBridge) && canImport(Metal)
        let teardown = CoordinatorTeardownBox(handles.bridge)
        let engine = handles.splatEngine
        let device = handles.gpuDevice
        DispatchQueue.global(qos: .utility).async {
            // Tear down the coordinator first so its training thread can stop
            // and join while the Metal engine/device are still alive.
            teardown.bridge = nil
            aether_splat_engine_destroy(engine)
            aether_gpu_device_destroy(device)
        }
        #else
        _ = handles
        #endif
    }

    /// Lazily initialize the C++ PipelineCoordinator on first capture start.
    /// Heavy work (CoreML model loading: 10-30s) runs on background thread
    /// to avoid blocking the main thread (button/timer UI).
    /// Frames are dropped until coordinator is ready (camera feed still shows).
    private func initializeCoordinatorIfNeeded(
        processingBackend: ProcessingBackendChoice
    ) {
        #if canImport(CAetherNativeBridge) && canImport(Metal)
        if let activeCoordinatorBackend,
           activeCoordinatorBackend == processingBackend,
           coordinatorBridge != nil {
            return
        }
        guard coordinatorBridge == nil, !isInitializingCoordinator else { return }
        isInitializingCoordinator = true
        let initStartTime = CFAbsoluteTimeGetCurrent()
        coordinatorInitStartTime = initStartTime
        NSLog(
            "[Aether3D] initializeCoordinatorIfNeeded: launching background creation for backend=%@...",
            processingBackend.rawValue
        )

        Task.detached(priority: .userInitiated) { [weak self] in
            let handles = Self.createCoordinatorHandles(processingBackend: processingBackend)
            await MainActor.run { [weak self] in
                let elapsed = CFAbsoluteTimeGetCurrent() - initStartTime
                guard let self else {
                    if let h = handles {
                        let teardown = CoordinatorTeardownBox(h.bridge)
                        let engine = h.splatEngine
                        let device = h.gpuDevice
                        DispatchQueue.global(qos: .utility).async {
                            teardown.bridge = nil
                            aether_splat_engine_destroy(engine)
                            aether_gpu_device_destroy(device)
                        }
                    }
                    NSLog("[Aether3D] Coordinator: ViewModel deallocated during init (%.1fs)", elapsed)
                    return
                }
                self.isInitializingCoordinator = false
                self.debugCoordinatorInitTime = elapsed

                // ── Guard: Discard coordinator if scan was already stopped ──
                // If user tapped Stop while CoreML was loading, the scan has
                // transitioned to .completed/.failed. Installing a coordinator now
                // would leak GPU resources (teardownCoordinatorAsync already ran).
                guard self.scanState != .completed && self.scanState != .failed else {
                    if let h = handles {
                        NSLog("[Aether3D] Coordinator: scan already ended (state=%@), discarding (%.1fs)",
                              "\(self.scanState)", elapsed)
                        // Destroy on background to avoid blocking MainActor
                        let teardown = CoordinatorTeardownBox(h.bridge)
                        let engine = h.splatEngine
                        let device = h.gpuDevice
                        DispatchQueue.global(qos: .utility).async {
                            teardown.bridge = nil
                            aether_splat_engine_destroy(engine)
                            aether_gpu_device_destroy(device)
                        }
                    }
                    return
                }

                guard let h = handles, let bridge = h.bridge else {
                    if let h = handles {
                        aether_splat_engine_destroy(h.splatEngine)
                        aether_gpu_device_destroy(h.gpuDevice)
                    }
                    NSLog("[Aether3D] Pipeline coordinator creation FAILED (%.1fs elapsed)", elapsed)
                    return
                }
                self.gpuDeviceHandle = h.gpuDevice
                self.splatEngineHandle = h.splatEngine
                self.coordinatorBridge = bridge
                self.activeCoordinatorBackend = processingBackend
                self.debugBridgeReady = true
                NSLog(
                    "[Aether3D] Pipeline coordinator READY backend=%@ (%.1fs elapsed)",
                    processingBackend.rawValue,
                    elapsed
                )
                if self.pendingCaptureStartAfterCoordinatorReady &&
                    processingBackend.usesLocalPreviewPipeline &&
                    self.scanState == .ready {
                    self.pendingCaptureStartAfterCoordinatorReady = false
                    self.transition(to: .capturing)
                } else {
                    self.refreshCaptureGuidance()
                }
            }
        }
        #endif
    }

    // MARK: - Pixel Format Conversion

    /// Convert ARKit YCbCr BiPlanar pixel buffer to BGRA for C++ pipeline.
    /// Uses GPU-accelerated CIContext. Reuses a single CVPixelBuffer to avoid allocations.
    /// Returns the original buffer untouched if already in a 4-channel format.
    #if canImport(CoreImage) && canImport(CoreVideo)
    /// Convert YCbCr → BGRA. Called exclusively from frameForwardQueue (serial).
    /// Accesses only nonisolated(unsafe) properties (pixelConvertContext, bgraBuffer).
    nonisolated private func convertToBGRA(_ pixelBuffer: CVPixelBuffer) -> CVPixelBuffer? {
        let fmt = CVPixelBufferGetPixelFormatType(pixelBuffer)
        // Already 4-channel — pass through
        if fmt == kCVPixelFormatType_32BGRA || fmt == kCVPixelFormatType_32RGBA {
            return pixelBuffer
        }

        let w = CVPixelBufferGetWidth(pixelBuffer)
        let h = CVPixelBufferGetHeight(pixelBuffer)

        // Reuse existing buffer if size matches
        if let existing = bgraBuffer,
           CVPixelBufferGetWidth(existing) == w,
           CVPixelBufferGetHeight(existing) == h {
            // Render into existing buffer
            let ciImage = CIImage(cvPixelBuffer: pixelBuffer)
            pixelConvertContext.render(ciImage, to: existing)
            return existing
        }

        // Allocate new BGRA buffer
        let attrs: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: Int(kCVPixelFormatType_32BGRA),
            kCVPixelBufferWidthKey as String: w,
            kCVPixelBufferHeightKey as String: h,
            kCVPixelBufferIOSurfacePropertiesKey as String: [:]
        ]
        var newBuf: CVPixelBuffer?
        let status = CVPixelBufferCreate(
            kCFAllocatorDefault, w, h,
            kCVPixelFormatType_32BGRA,
            attrs as CFDictionary, &newBuf)
        guard status == kCVReturnSuccess, let outBuf = newBuf else { return nil }

        let ciImage = CIImage(cvPixelBuffer: pixelBuffer)
        pixelConvertContext.render(ciImage, to: outBuf)
        bgraBuffer = outBuf
        return outBuf
    }
    #endif

    /// Sendable wrapper for CVPixelBuffer (refcounted, safe to transfer across queues).
    private struct SendablePixelBuffer: @unchecked Sendable {
        let buffer: CVPixelBuffer
    }

    /// Sendable wrapper for OpaquePointer (C handle, safe to transfer for teardown).
    private struct SendableHandle: @unchecked Sendable {
        let pointer: OpaquePointer
    }

    /// Captures all data needed for background frame forwarding.
    private struct FrameForwardPayload: @unchecked Sendable {
        let bridge: PipelineCoordinatorBridge
        let pixelBuffer: SendablePixelBuffer
        let lidarBuffer: SendablePixelBuffer?
        let cameraTransform: simd_float4x4
        let intrinsics: simd_float3x3
        let flatFeatures: [Float]
        let featureCount: UInt32
        let thermalState: Int
    }

    /// Forward frame data to PipelineCoordinator on background serial queue.
    /// CIContext BGRA conversion + memcpy runs off main thread (~5-10ms freed).
    /// At most 1 frame in-flight on the queue; excess frames are dropped.
    private func forwardFrameToCoordinator(
        cameraTransform: simd_float4x4,
        timestamp: TimeInterval,
        pixelBuffer: CVPixelBuffer?,
        cameraIntrinsics: simd_float3x3?,
        lidarDepthBuffer: CVPixelBuffer? = nil,
        featurePoints: [SIMD3<Float>]? = nil
    ) {
        #if canImport(CAetherNativeBridge) && canImport(CoreVideo) && canImport(CoreImage)
        guard let bridge = coordinatorBridge, let pixelBuffer = pixelBuffer else {
            // Log frame drops while coordinator is loading (throttled)
            if coordinatorBridge == nil, pixelBuffer != nil {
                if frameCounter <= 3 || frameCounter % 300 == 0 {
                    NSLog("[Aether3D] forwardFrame: bridge=nil, frame %d dropped", frameCounter)
                }
            }
            return
        }

        // Drop if previous frame still processing (prevent queue buildup)
        guard !isForwardingFrame else { return }
        isForwardingFrame = true

        // Flatten ARKit feature points on main thread (needs ARPointCloud access).
        var features: [Float] = []
        let featureCount: UInt32
        if let pts = featurePoints, !pts.isEmpty {
            let maxPts = min(pts.count, 512)
            features.reserveCapacity(maxPts * 3)
            for i in 0..<maxPts {
                features.append(pts[i].x)
                features.append(pts[i].y)
                features.append(pts[i].z)
            }
            featureCount = UInt32(maxPts)
        } else {
            featureCount = 0
        }

        // Pack everything into Sendable payload for background dispatch.
        let payload = FrameForwardPayload(
            bridge: bridge,
            pixelBuffer: SendablePixelBuffer(buffer: pixelBuffer),
            lidarBuffer: lidarDepthBuffer.map { SendablePixelBuffer(buffer: $0) },
            cameraTransform: cameraTransform,
            intrinsics: cameraIntrinsics ?? simd_float3x3(1),
            flatFeatures: features,
            featureCount: featureCount,
            thermalState: ProcessInfo.processInfo.thermalState.rawValue
        )

        // Dispatch heavy work (CIContext conversion + C++ enqueue) to serial queue.
        // CRITICAL: Use autoreleasepool to ensure CVPixelBuffer references are
        // released promptly. Without this, ARKit's pixel buffer pool exhausts
        // and ARSession complains about "retaining 11+ ARFrames".
        frameForwardQueue.async { [weak self] in
            guard let self else { return }
            defer { self.isForwardingFrame = false }

            autoreleasepool {
            // Convert YCbCr → BGRA (GPU-accelerated, now off main thread)
            guard let bgraPixelBuffer = self.convertToBGRA(payload.pixelBuffer.buffer) else { return }

            let width = UInt32(CVPixelBufferGetWidth(bgraPixelBuffer))
            let height = UInt32(CVPixelBufferGetHeight(bgraPixelBuffer))

            CVPixelBufferLockBaseAddress(bgraPixelBuffer, .readOnly)
            defer { CVPixelBufferUnlockBaseAddress(bgraPixelBuffer, .readOnly) }

            guard let baseAddress = CVPixelBufferGetBaseAddress(bgraPixelBuffer) else { return }
            let rgbaPtr = baseAddress.assumingMemoryBound(to: UInt8.self)

            // LiDAR depth
            var lidarPtr: UnsafePointer<Float>?
            var lidarW: UInt32 = 0
            var lidarH: UInt32 = 0

            if let lidarBuf = payload.lidarBuffer?.buffer {
                CVPixelBufferLockBaseAddress(lidarBuf, .readOnly)
            }
            defer {
                if let lidarBuf = payload.lidarBuffer?.buffer {
                    CVPixelBufferUnlockBaseAddress(lidarBuf, .readOnly)
                }
            }

            if let lidarBuf = payload.lidarBuffer?.buffer,
               let lidarBase = CVPixelBufferGetBaseAddress(lidarBuf) {
                lidarPtr = UnsafePointer<Float>(lidarBase.assumingMemoryBound(to: Float.self))
                lidarW = UInt32(CVPixelBufferGetWidth(lidarBuf))
                lidarH = UInt32(CVPixelBufferGetHeight(lidarBuf))
            }

            // C++ enqueue (lock-free, <0.3ms)
            payload.flatFeatures.withUnsafeBufferPointer { featureBuf in
                let fPtr = featureBuf.isEmpty ? nil : featureBuf.baseAddress

                _ = payload.bridge.onFrame(
                    rgba: rgbaPtr,
                    width: width, height: height,
                    transform: payload.cameraTransform,
                    intrinsics: payload.intrinsics,
                    featurePoints: fPtr, featureCount: payload.featureCount,
                    neDepth: nil, neDepthW: 0, neDepthH: 0,
                    lidarDepth: lidarPtr, lidarW: lidarW, lidarH: lidarH,
                    thermalState: payload.thermalState
                )
            }
            } // autoreleasepool — releases CVPixelBuffer refs immediately
        }
        #endif
    }

    /// Request quality enhancement (extra training iterations).
    func requestQualityEnhance(iterations: Int = 200) {
        _ = coordinatorBridge?.requestEnhance(iterations: iterations)
    }

    /// Poll training/snapshot state without a live AR frame.
    /// Used by viewer waiting screen after capture stops.
    func refreshTrainingStatusFromCoordinator() {
        #if canImport(CAetherNativeBridge)
        guard let bridge = coordinatorBridge else { return }

        if let snapshot = bridge.getSnapshot() {
            coveragePercent = snapshot.coverage
            trainingProgress = snapshot.training_progress
            trainingActive = snapshot.training_active != 0
            debugSelectedFrames = Int(snapshot.selected_frames)
            debugMinFramesNeeded = Int(snapshot.min_frames_needed)
            debugKeyframeGateAccepts = Int(snapshot.preview_keyframe_gate_accepts)
            debugKeyframeGateRejects = Int(snapshot.preview_keyframe_gate_rejects)
            debugIsGPUTraining = bridge.isGPUTraining
            debugHasS6Quality = snapshot.has_s6_quality != 0
            debugNumGaussians = Int(snapshot.num_gaussians)
            debugAssignedBlocks = Int(snapshot.assigned_blocks)
            debugPendingGaussians = Int(snapshot.pending_gaussian_count)
            debugPreviewSeedAccepted = Int(snapshot.preview_seed_accepted)
            debugPreviewSeedCandidates = Int(snapshot.preview_seed_candidates)
        }

        if let progress = bridge.trainingProgress() {
            if progress.total_steps > 0 {
                trainingProgress = Float(progress.step) / Float(progress.total_steps)
            }
            debugTrainingStep = Int(progress.step)
            debugTotalSteps = Int(progress.total_steps)
            debugLoss = progress.loss
        }
        #endif
    }

    /// Export trained 3DGS to PLY file.
    func exportTrainedPLY(to path: String) -> Bool {
        return coordinatorBridge?.exportPLY(path: path) ?? false
    }

    #if canImport(AVFoundation)
    private func prepareRemoteVideoRecorderIfNeeded(targetFPS: Double = 18.0) {
        let outputURL = Self.exportDirectoryURL()
            .appendingPathComponent("remote_inputs", isDirectory: true)
            .appendingPathComponent("\(UUID().uuidString).mp4")
        remoteVideoRecorder?.cancel()
        remoteVideoRecorder = ARFrameVideoRecorder(
            outputURL: outputURL,
            targetFPS: targetFPS,
            detachSourceFrames: targetFPS <= 4.0
        )
        remoteVideoRecorderMinFrameStep = max(0.0, 1.0 / max(1.0, targetFPS))
        lastRemoteVideoFrameEnqueueTimestamp = nil
    }

    private func appendRemoteVideoFrame(pixelBuffer: CVPixelBuffer?, timestamp: TimeInterval) {
        guard let pixelBuffer else { return }
        if let lastTimestamp = lastRemoteVideoFrameEnqueueTimestamp,
           timestamp - lastTimestamp < remoteVideoRecorderMinFrameStep {
            return
        }
        lastRemoteVideoFrameEnqueueTimestamp = timestamp
        remoteVideoRecorder?.appendFrame(pixelBuffer: pixelBuffer, timestamp: timestamp)
    }
    #else
    private func prepareRemoteVideoRecorderIfNeeded(targetFPS: Double = 18.0) {
        _ = targetFPS
    }
    private func appendRemoteVideoFrame(pixelBuffer: CVPixelBuffer?, timestamp: TimeInterval) {}
    #endif

    nonisolated private static func exportDirectoryURL() -> URL {
        let documents = FileManager.default.urls(
            for: .documentDirectory, in: .userDomainMask)[0]
        return documents
            .appendingPathComponent("Aether3D")
            .appendingPathComponent("exports")
    }

    nonisolated private static func importsDirectoryURL() -> URL {
        let documents = FileManager.default.urls(
            for: .documentDirectory, in: .userDomainMask)[0]
        return documents
            .appendingPathComponent("Aether3D")
            .appendingPathComponent("imports")
    }

    nonisolated static func relativeArtifactPath(for recordId: UUID) -> String {
        "exports/\(recordId.uuidString).ply"
    }

    nonisolated private static func relativeSourceVideoPath(for recordId: UUID, fileExtension: String) -> String {
        "imports/\(recordId.uuidString).\(fileExtension)"
    }

    nonisolated private static func status(for stage: GenerateProgressStage) -> ScanRecordStatus {
        switch stage {
        case .preparing:
            return .preparing
        case .uploading:
            return .uploading
        case .queued:
            return .queued
        case .reconstructing:
            return .reconstructing
        case .training:
            return .training
        case .packaging:
            return .packaging
        case .downloading:
            return .downloading
        case .localFallback:
            return .localFallback
        case .completed:
            return .completed
        case .failed:
            return .failed
        }
    }

    nonisolated private static func failureDetail(for reason: FailReason) -> String {
        switch reason {
        case .networkTimeout, .timeout:
            return "远端等待超时了。你可以稍后重试，或先返回主页继续别的作品。"
        case .uploadFailed:
            return "视频上传没有完成，请检查网络后再试。"
        case .downloadFailed:
            return "远端已经生成了结果，但回传到手机时失败了。"
        case .apiError, .apiNotConfigured:
            return "丹麦 5090 当前不可用，请稍后重试。"
        case .inputInvalid:
            return "这段视频暂时不适合进入当前白盒流程，请换一个角度更完整的视频。"
        case .outOfMemory:
            return "远端显存不足，建议缩短视频或降低场景复杂度后重试。"
        case .stalledProcessing:
            return "远端长时间没有推进，这次任务已经被停止。"
        case .jobTimeout, .invalidResponse, .unknownError:
            return "远端返回了异常结果，请稍后重试。"
        }
    }

    private func applyProgressSnapshot(_ snapshot: GenerateProgressSnapshot) {
        backgroundExportStatusMessage = snapshot.title
        if let progress = snapshot.progressFraction {
            trainingProgress = Float(max(0.0, min(1.0, progress)))
        }
        trainingActive = snapshot.stage != .completed && snapshot.stage != .failed
    }

    #if canImport(AVFoundation)
    nonisolated private static func persistSourceVideoIfNeeded(
        from temporaryURL: URL,
        recordId: UUID
    ) -> (relativePath: String, persistedURL: URL)? {
        let importsDirectory = importsDirectoryURL()
        do {
            try FileManager.default.createDirectory(at: importsDirectory, withIntermediateDirectories: true)
            let ext = temporaryURL.pathExtension.isEmpty ? "mp4" : temporaryURL.pathExtension.lowercased()
            let targetURL = importsDirectory.appendingPathComponent("\(recordId.uuidString).\(ext)")
            if FileManager.default.fileExists(atPath: targetURL.path) {
                try FileManager.default.removeItem(at: targetURL)
            }
            if temporaryURL.path != targetURL.path {
                try FileManager.default.moveItem(at: temporaryURL, to: targetURL)
            }
            return (relativeSourceVideoPath(for: recordId, fileExtension: ext), targetURL)
        } catch {
            NSLog("[Aether3D] Failed to persist source video: %@", String(describing: error))
            return nil
        }
    }
    #endif

    #if canImport(AVFoundation) && canImport(UIKit)
    nonisolated private static func makeThumbnailData(for videoURL: URL) -> Data? {
        let asset = AVURLAsset(url: videoURL)
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        guard let cgImage = try? generator.copyCGImage(at: .zero, actualTime: nil) else {
            return nil
        }
        let image = UIImage(cgImage: cgImage)
        return image.jpegData(compressionQuality: 0.82)
    }
    #endif

    private struct CaptureIntrinsicsSidecar: Codable {
        let version: String
        let fx: Float
        let fy: Float
        let cx: Float
        let cy: Float
    }

    nonisolated private static func representativeCaptureIntrinsics(
        from frames: [RawWorldStateFrame]
    ) -> simd_float3x3? {
        let valid = frames.compactMap(\.cameraIntrinsics).filter {
            $0[0][0].isFinite && $0[1][1].isFinite &&
            $0[0][2].isFinite && $0[1][2].isFinite &&
            $0[0][0] > 1.0 && $0[1][1] > 1.0
        }
        guard !valid.isEmpty else { return nil }

        let count = Float(valid.count)
        let fx = valid.reduce(0.0) { $0 + $1[0][0] } / count
        let fy = valid.reduce(0.0) { $0 + $1[1][1] } / count
        let cx = valid.reduce(0.0) { $0 + $1[0][2] } / count
        let cy = valid.reduce(0.0) { $0 + $1[1][2] } / count

        return simd_float3x3(
            SIMD3<Float>(fx, 0, 0),
            SIMD3<Float>(0, fy, 0),
            SIMD3<Float>(cx, cy, 1)
        )
    }

    nonisolated private static func persistSourceVideoIntrinsicsIfAvailable(
        for recordId: UUID,
        worldStateFrames: [RawWorldStateFrame]
    ) {
        guard let intrinsics = representativeCaptureIntrinsics(from: worldStateFrames) else {
            return
        }

        let sidecarURL = importsDirectoryURL().appendingPathComponent("\(recordId.uuidString).intrinsics.json")
        let payload = CaptureIntrinsicsSidecar(
            version: "aether_capture_intrinsics_v1",
            fx: intrinsics[0][0],
            fy: intrinsics[1][1],
            cx: intrinsics[0][2],
            cy: intrinsics[1][2]
        )

        do {
            let data = try JSONEncoder().encode(payload)
            try data.write(to: sidecarURL, options: .atomic)
            NSLog("[Aether3D] ✅ Persisted live capture intrinsics sidecar → %@", sidecarURL.path)
        } catch {
            NSLog("[Aether3D] ❌ Failed to persist live capture intrinsics sidecar: %@", String(describing: error))
        }
    }

    nonisolated static func writeWorldStateIfAvailable(
        recordId: UUID,
        exportDir: URL,
        worldStateFrames: [RawWorldStateFrame],
        surfaceSamples: [SIMD3<Float>]
    ) {
        guard !worldStateFrames.isEmpty else {
            NSLog("[Aether3D] Background export: world-state recorder empty; skipping JSON export")
            return
        }

        let worldStateURL = exportDir.appendingPathComponent("\(recordId.uuidString).world_state.json")
        do {
            let exportPayload = makeWorldStateExport(
                sceneID: recordId.uuidString,
                frames: worldStateFrames,
                surfacePoints: surfaceSamples
            )
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(exportPayload)
            try data.write(to: worldStateURL, options: .atomic)
            NSLog("[Aether3D] ✅ Background export: world-state JSON → %@", worldStateURL.path)
        } catch {
            NSLog("[Aether3D] ❌ Background export: world-state JSON failed: %@", String(describing: error))
        }
    }

    /// Start background export (non-blocking — viewer navigates immediately).
    /// Training continues → exports PLY when ready → updates ScanRecord artifact path.
    func startBackgroundExport(
        recordId: UUID,
        processingBackend: ProcessingBackendChoice = .cloud
    ) {
        let bridge = coordinatorBridge
        let worldStateFrames = worldStateRecorder.snapshot()
        let selectedFrameSamplingProfile = {
            let store = ScanRecordStore()
            if let rawValue = store.record(id: recordId)?.frameSamplingProfile,
               let profile = FrameSamplingProfile(rawValue: rawValue) {
                return profile
            }
            return FrameSamplingProfile.currentSelection()
        }()
        let localWorkflowStageKey = processingBackend.localWorkflowStageKey ?? "local_subject_first"
        let localModeResultTitle = "本地结果已生成"
        let localModeFailureTitle = "本地处理失败了"
        let localModeRefineDetail = "采集结束后会直接在手机上继续本地处理，再做 cutout 和保守 cleanup。"
        #if canImport(AVFoundation)
        let remoteVideoRecorder = remoteVideoRecorder
        self.remoteVideoRecorder = nil
        #endif

        Task.detached(priority: .userInitiated) {
            let exportDir = Self.exportDirectoryURL()
            try? FileManager.default.createDirectory(at: exportDir, withIntermediateDirectories: true)
            let plyURL = exportDir.appendingPathComponent("\(recordId.uuidString).ply")
            let store = ScanRecordStore()
            let surfaceSamples = {
                let copied = bridge?.copySurfacePoints(
                    maxPoints: Int(ScanViewModel.worldStateSurfaceMaxPoints)
                ) ?? []
                if !copied.isEmpty {
                    return copied
                }
                return ScanViewModel.sampleSurfacePoints(from: bridge?.getRenderData())
            }()

            #if canImport(AVFoundation)
            var sourceVideoRelativePath: String?
            let capturedVideoURL = await remoteVideoRecorder?.finish()

            if let temporaryVideoURL = capturedVideoURL,
               let persistedVideo = Self.persistSourceVideoIfNeeded(from: temporaryVideoURL, recordId: recordId) {
                let persistedSourcePath = persistedVideo.relativePath
                sourceVideoRelativePath = persistedSourcePath
                Self.persistSourceVideoIntrinsicsIfAvailable(
                    for: recordId,
                    worldStateFrames: worldStateFrames
                )

                #if canImport(UIKit)
                if let thumbnailData = Self.makeThumbnailData(for: persistedVideo.persistedURL),
                   let thumbnailPath = store.saveThumbnail(thumbnailData, for: recordId) {
                    store.updateThumbnailPath(recordId: recordId, thumbnailPath: thumbnailPath)
                }
                #endif

                if processingBackend == .cloud {
                    store.updateProcessingState(
                        recordId: recordId,
                        status: .preparing,
                        statusMessage: "正在准备远端任务",
                        detailMessage: "会先把本次视频交给后台上传服务，然后由后端调度可用 GPU 开始训练。",
                        progressFraction: 0.01,
                        estimatedRemainingMinutes: nil,
                        sourceVideoPath: persistedSourcePath
                    )
                    await MainActor.run {
                        self.applyProgressSnapshot(
                            GenerateProgressSnapshot(
                                stage: .preparing,
                                progressFraction: 0.01,
                                title: "正在准备远端任务",
                                detail: "你可以留在等待页查看，也可以先回主页稍后继续。",
                                etaMinutes: nil
                            )
                        )
                    }

                    let remoteRunner = PipelineRunner(backend: .productDefault())
                    let request = BuildRequest(
                        source: .file(url: persistedVideo.persistedURL),
                        requestedMode: .enter,
                        deviceTier: DeviceTier.current(),
                        frameSamplingProfile: selectedFrameSamplingProfile,
                        processingBackend: .cloud
                    )
                    let remoteResult = await remoteRunner.runGenerate(request: request) { snapshot in
                        let progressStore = ScanRecordStore()
                        progressStore.updateProcessingState(
                            recordId: recordId,
                            status: Self.status(for: snapshot.stage),
                            statusMessage: snapshot.title,
                            detailMessage: snapshot.detail,
                            progressFraction: snapshot.progressFraction,
                            progressBasis: snapshot.progressBasis,
                            remoteStageKey: snapshot.remoteStageKey,
                            remotePhaseName: snapshot.remotePhaseName,
                            currentTier: snapshot.currentTier,
                            runtimeMetrics: snapshot.runtimeMetrics,
                            uploadedBytes: snapshot.uploadedBytes,
                            totalBytes: snapshot.totalBytes,
                            uploadBytesPerSecond: snapshot.uploadBytesPerSecond,
                            estimatedRemainingMinutes: snapshot.etaMinutes,
                            sourceVideoPath: persistedSourcePath,
                            frameSamplingProfile: selectedFrameSamplingProfile.rawValue,
                            remoteJobId: snapshot.remoteJobId
                        )
                        await MainActor.run {
                            self.applyProgressSnapshot(snapshot)
                        }
                    }

                    switch remoteResult {
                    case .success(let artifact, _):
                        do {
                            let payload = try Data(contentsOf: artifact.localPath)
                            try payload.write(to: plyURL, options: .atomic)
                            Self.writeWorldStateIfAvailable(
                                recordId: recordId,
                                exportDir: exportDir,
                                worldStateFrames: worldStateFrames,
                                surfaceSamples: surfaceSamples
                            )
                            let artifactPath = Self.relativeArtifactPath(for: recordId)
                            store.updateArtifactPath(recordId: recordId, artifactPath: artifactPath)
                            await MainActor.run {
                                self.backgroundExportStatusMessage = "3DGS 已回传到手机"
                                self.trainingProgress = 1.0
                                self.trainingActive = false
                                NSLog("[Aether3D] Background export: remote artifact=%@", artifactPath)
                            }
                            return
                        } catch {
                            NSLog("[Aether3D] ❌ Background export: remote artifact copy failed: %@", String(describing: error))
                        }
                    case .fail(let reason, _):
                        NSLog("[Aether3D] Background export: remote pipeline failed (%@), falling back to local export", reason.rawValue)
                        let remoteFailureDetail = store.record(id: recordId)?.detailMessage ?? Self.failureDetail(for: reason)
                        store.updateProcessingState(
                            recordId: recordId,
                            status: .localFallback,
                            statusMessage: "远端不可用，正在本地兜底",
                            detailMessage: remoteFailureDetail,
                            progressFraction: 0.82,
                            estimatedRemainingMinutes: nil,
                            sourceVideoPath: sourceVideoRelativePath,
                            frameSamplingProfile: selectedFrameSamplingProfile.rawValue,
                            failureReason: reason.rawValue
                        )
                        await MainActor.run {
                            self.applyProgressSnapshot(
                                GenerateProgressSnapshot(
                                    stage: .localFallback,
                                    progressFraction: 0.82,
                                    title: "远端不可用，正在本地兜底",
                                    detail: "这次会直接退回到手机本地导出。",
                                    etaMinutes: nil
                                )
                            )
                        }
                    }
                } else {
                    if processingBackend == .localSubjectFirst {
                        store.updateProcessingState(
                            recordId: recordId,
                            status: .training,
                            statusMessage: LocalPreviewWorkflowPhase.depth.title,
                            detailMessage: "录制已经结束，正在直接基于本地视频走本地处理链路。",
                            progressFraction: LocalPreviewWorkflowPhase.depth.startFraction,
                            progressBasis: LocalPreviewWorkflowPhase.depth.progressBasis,
                            remoteStageKey: localWorkflowStageKey,
                            remotePhaseName: LocalPreviewWorkflowPhase.depth.phaseName,
                            runtimeMetrics: [
                                "processing_backend": processingBackend.rawValue,
                                "preview_source_kind": "captured_video",
                                "preview_active_phase": LocalPreviewWorkflowPhase.depth.phaseName,
                                "preview_phase_model": "captured_video_depth_seed_refine_cutout_cleanup_export"
                            ],
                            estimatedRemainingMinutes: nil,
                            sourceVideoPath: persistedSourcePath,
                            frameSamplingProfile: selectedFrameSamplingProfile.rawValue,
                            clearRemoteJobId: true
                        )
                        await MainActor.run {
                            self.applyProgressSnapshot(
                                GenerateProgressSnapshot(
                                    stage: .training,
                                    progressFraction: LocalPreviewWorkflowPhase.depth.startFraction,
                                    progressBasis: LocalPreviewWorkflowPhase.depth.progressBasis,
                                    remoteStageKey: localWorkflowStageKey,
                                    remotePhaseName: LocalPreviewWorkflowPhase.depth.phaseName,
                                    title: LocalPreviewWorkflowPhase.depth.title,
                                    detail: "这次拍摄会先转成本地视频输入，再继续做主体 cutout 和保守 cleanup。",
                                    etaMinutes: nil,
                                    runtimeMetrics: [
                                        "processing_backend": processingBackend.rawValue,
                                        "preview_source_kind": "captured_video"
                                    ]
                                )
                            )
                        }

                        let applyPersistedImportPhase: @MainActor @Sendable (LocalPreviewPhaseUpdate) -> Void = { update in
                            let phaseStore = ScanRecordStore()
                            phaseStore.updateProcessingState(
                                recordId: recordId,
                                status: update.phase == .export ? ScanRecordStatus.packaging : ScanRecordStatus.training,
                                statusMessage: update.title,
                                detailMessage: update.detail,
                                progressFraction: update.progressFraction,
                                progressBasis: update.phase.progressBasis,
                                remoteStageKey: localWorkflowStageKey,
                                remotePhaseName: update.phase.phaseName,
                                runtimeMetrics: update.runtimeMetrics,
                                estimatedRemainingMinutes: nil,
                                sourceVideoPath: persistedSourcePath,
                                frameSamplingProfile: selectedFrameSamplingProfile.rawValue,
                                clearRemoteJobId: true
                            )
                        }

                        let importResult = LocalPreviewImportRunner.execute(
                            sourceVideoURL: persistedVideo.persistedURL,
                            artifactURL: plyURL,
                            sourceRelativePath: persistedSourcePath,
                            frameSamplingProfile: selectedFrameSamplingProfile,
                            processingBackend: processingBackend,
                            onPhaseUpdate: { update in
                                Task { @MainActor in
                                    applyPersistedImportPhase(update)
                                }
                            }
                        )

                        if importResult.exported {
                            store.updateProcessingState(
                                recordId: recordId,
                                status: .completed,
                                statusMessage: localModeResultTitle,
                                detailMessage: importResult.detailMessage,
                                progressFraction: 1.0,
                                progressBasis: LocalPreviewWorkflowPhase.export.progressBasis,
                                remoteStageKey: localWorkflowStageKey,
                                remotePhaseName: LocalPreviewWorkflowPhase.export.phaseName,
                                runtimeMetrics: importResult.runtimeMetrics,
                                estimatedRemainingMinutes: 0,
                                sourceVideoPath: persistedSourcePath,
                                frameSamplingProfile: selectedFrameSamplingProfile.rawValue,
                                clearRemoteJobId: true
                            )
                            store.updateArtifactPath(recordId: recordId, artifactPath: Self.relativeArtifactPath(for: recordId))
                            await MainActor.run {
                                self.backgroundExportStatusMessage = "本地处理完成"
                                self.trainingProgress = 1.0
                                self.trainingActive = false
                                NSLog("[Aether3D] Background export: local subject-first imported-video artifact=%@", Self.relativeArtifactPath(for: recordId))
                            }
                        } else {
                            store.updateProcessingState(
                                recordId: recordId,
                                status: .failed,
                                statusMessage: localModeFailureTitle,
                                detailMessage: importResult.detailMessage,
                                progressFraction: importResult.terminalProgressFraction,
                                progressBasis: importResult.terminalPhase.progressBasis,
                                remoteStageKey: localWorkflowStageKey,
                                remotePhaseName: importResult.terminalPhase.phaseName,
                                runtimeMetrics: importResult.runtimeMetrics,
                                estimatedRemainingMinutes: nil,
                                sourceVideoPath: persistedSourcePath,
                                frameSamplingProfile: selectedFrameSamplingProfile.rawValue,
                                failureReason: importResult.runtimeMetrics["preview_failure_reason"] ?? "local_subject_import_failed"
                            )
                            await MainActor.run {
                                self.backgroundExportStatusMessage = "本地处理失败"
                                self.trainingActive = false
                            }
                        }
                    } else {
                        let localPreviewMetrics = LocalPreviewMetricsArchive.runtimeMetrics(
                            snapshot: bridge?.getSnapshot(),
                            sourceVideo: persistedSourcePath,
                            sourceKind: LocalPreviewProductProfile.directCaptureSourceKind(
                                sourceVideoRelativePath: persistedSourcePath
                            ),
                            processingBackend: processingBackend
                        )
                        store.updateProcessingState(
                            recordId: recordId,
                            status: .training,
                            statusMessage: LocalPreviewWorkflowPhase.refine.title,
                            detailMessage: localModeRefineDetail,
                            progressFraction: LocalPreviewWorkflowPhase.refine.startFraction,
                            progressBasis: LocalPreviewWorkflowPhase.refine.progressBasis,
                            remoteStageKey: localWorkflowStageKey,
                            remotePhaseName: LocalPreviewWorkflowPhase.refine.phaseName,
                            runtimeMetrics: localPreviewMetrics,
                            estimatedRemainingMinutes: nil,
                            sourceVideoPath: persistedSourcePath,
                            frameSamplingProfile: selectedFrameSamplingProfile.rawValue,
                            clearRemoteJobId: true
                        )
                        await MainActor.run {
                            self.applyProgressSnapshot(
                                GenerateProgressSnapshot(
                                    stage: .training,
                                    progressFraction: LocalPreviewWorkflowPhase.refine.startFraction,
                                    progressBasis: LocalPreviewWorkflowPhase.refine.progressBasis,
                                    remoteStageKey: localWorkflowStageKey,
                                    remotePhaseName: LocalPreviewWorkflowPhase.refine.phaseName,
                                    title: LocalPreviewWorkflowPhase.refine.title,
                                    detail: "这次不会走云端，而是直接使用手机上的本地处理链路。",
                                    etaMinutes: nil,
                                    runtimeMetrics: localPreviewMetrics
                                )
                            )
                        }

                        guard let bridge else {
                            store.updateProcessingState(
                                recordId: recordId,
                                status: .failed,
                                statusMessage: "本地处理没有启动成功",
                                detailMessage: "本地协调器没有准备好，这次无法继续生成本地结果。",
                                progressFraction: LocalPreviewWorkflowPhase.refine.startFraction,
                                progressBasis: LocalPreviewWorkflowPhase.refine.progressBasis,
                                remoteStageKey: localWorkflowStageKey,
                                remotePhaseName: LocalPreviewWorkflowPhase.refine.phaseName,
                                runtimeMetrics: localPreviewMetrics,
                                estimatedRemainingMinutes: nil,
                                sourceVideoPath: persistedSourcePath,
                                frameSamplingProfile: selectedFrameSamplingProfile.rawValue,
                                failureReason: "local_subject_first_bridge_missing"
                            )
                            await MainActor.run {
                                self.backgroundExportStatusMessage = "本地处理失败"
                                self.trainingActive = false
                            }
                            return
                        }

                        let applyPersistedLocalPreviewPhase: @MainActor @Sendable (LocalPreviewPhaseUpdate) -> Void = { update in
                            let phaseStore = ScanRecordStore()
                            phaseStore.updateProcessingState(
                                recordId: recordId,
                                status: update.phase == .export ? ScanRecordStatus.packaging : ScanRecordStatus.training,
                                statusMessage: update.title,
                                detailMessage: update.detail,
                                progressFraction: update.progressFraction,
                                progressBasis: update.phase.progressBasis,
                                remoteStageKey: localWorkflowStageKey,
                                remotePhaseName: update.phase.phaseName,
                                runtimeMetrics: update.runtimeMetrics,
                                estimatedRemainingMinutes: nil,
                                sourceVideoPath: persistedSourcePath,
                                frameSamplingProfile: selectedFrameSamplingProfile.rawValue,
                                clearRemoteJobId: true
                            )
                        }

                        let localResult = LocalPreviewCaptureRunner.execute(
                            recordId: recordId,
                            bridge: bridge,
                            exportDir: exportDir,
                            plyURL: plyURL,
                            worldStateFrames: worldStateFrames,
                            surfaceSamples: surfaceSamples,
                            sourceVideoRelativePath: persistedSourcePath,
                            processingBackend: processingBackend,
                            onPhaseUpdate: { update in
                                Task { @MainActor in
                                    applyPersistedLocalPreviewPhase(update)
                                }
                            }
                        )

                        if localResult.exported, let artifactPath = localResult.artifactRelativePath {
                            store.updateProcessingState(
                                recordId: recordId,
                                status: .completed,
                                statusMessage: localModeResultTitle,
                                detailMessage: localResult.detailMessage,
                                progressFraction: 1.0,
                                progressBasis: LocalPreviewWorkflowPhase.export.progressBasis,
                                remoteStageKey: localWorkflowStageKey,
                                remotePhaseName: LocalPreviewWorkflowPhase.export.phaseName,
                                runtimeMetrics: localResult.runtimeMetrics,
                                estimatedRemainingMinutes: 0,
                                sourceVideoPath: persistedSourcePath,
                                frameSamplingProfile: selectedFrameSamplingProfile.rawValue,
                                clearRemoteJobId: true
                            )
                            store.updateArtifactPath(recordId: recordId, artifactPath: artifactPath)
                            await MainActor.run {
                                self.backgroundExportStatusMessage = "本地导出完成"
                                self.trainingProgress = 1.0
                                self.trainingActive = false
                                NSLog("[Aether3D] Background export: local result artifact=%@", artifactPath)
                            }
                        } else {
                            store.updateProcessingState(
                                recordId: recordId,
                                status: .failed,
                                statusMessage: localModeFailureTitle,
                                detailMessage: localResult.detailMessage,
                                progressFraction: 0.92,
                                progressBasis: LocalPreviewWorkflowPhase.export.progressBasis,
                                remoteStageKey: localWorkflowStageKey,
                                remotePhaseName: LocalPreviewWorkflowPhase.export.phaseName,
                                runtimeMetrics: localResult.runtimeMetrics,
                                estimatedRemainingMinutes: nil,
                                sourceVideoPath: persistedSourcePath,
                                frameSamplingProfile: selectedFrameSamplingProfile.rawValue,
                                failureReason: "local_export_failed"
                            )
                            await MainActor.run {
                                self.backgroundExportStatusMessage = "导出失败"
                                self.trainingActive = false
                            }
                        }
                    }
                    return
                }
            } else {
                if processingBackend == .cloud {
                    store.updateProcessingState(
                        recordId: recordId,
                        status: .localFallback,
                        statusMessage: "没有拿到可用视频，正在本地兜底",
                        detailMessage: "本次不会上传远端，会直接退回手机本地导出。",
                        progressFraction: 0.80,
                        estimatedRemainingMinutes: nil,
                        frameSamplingProfile: selectedFrameSamplingProfile.rawValue
                    )
                    await MainActor.run {
                        self.applyProgressSnapshot(
                            GenerateProgressSnapshot(
                                stage: .localFallback,
                                progressFraction: 0.80,
                                title: "正在本地兜底",
                                detail: "远端视频没有准备成功，这次会直接在手机端导出结果。",
                                etaMinutes: nil
                            )
                        )
                    }
                } else {
                    let localPreviewMetrics = LocalPreviewMetricsArchive.runtimeMetrics(
                        snapshot: bridge?.getSnapshot(),
                        sourceVideo: "memory_only",
                        sourceKind: LocalPreviewProductProfile.directCaptureSourceKind(
                            sourceVideoRelativePath: "memory_only"
                        ),
                        processingBackend: processingBackend
                    )
                    store.updateProcessingState(
                        recordId: recordId,
                        status: .training,
                        statusMessage: LocalPreviewWorkflowPhase.refine.title,
                        detailMessage: processingBackend == .localSubjectFirst
                            ? "这次会继续使用手机内存里的训练状态直接做主体 cutout 和保守 cleanup。"
                            : "这次会继续使用手机内存里的训练状态直接导出 preview。",
                        progressFraction: LocalPreviewWorkflowPhase.refine.startFraction,
                        progressBasis: LocalPreviewWorkflowPhase.refine.progressBasis,
                        remoteStageKey: localWorkflowStageKey,
                        remotePhaseName: LocalPreviewWorkflowPhase.refine.phaseName,
                        runtimeMetrics: localPreviewMetrics,
                        estimatedRemainingMinutes: nil,
                        frameSamplingProfile: selectedFrameSamplingProfile.rawValue,
                        clearRemoteJobId: true
                    )
                    await MainActor.run {
                        self.applyProgressSnapshot(
                            GenerateProgressSnapshot(
                                stage: .training,
                                progressFraction: LocalPreviewWorkflowPhase.refine.startFraction,
                                progressBasis: LocalPreviewWorkflowPhase.refine.progressBasis,
                                remoteStageKey: localWorkflowStageKey,
                                remotePhaseName: LocalPreviewWorkflowPhase.refine.phaseName,
                                title: LocalPreviewWorkflowPhase.refine.title,
                                detail: processingBackend == .localSubjectFirst
                                    ? "源视频没有落盘，但本地训练状态还在，会继续生成本地结果。"
                                    : "源视频没有落盘，但本地训练状态还在，会继续导出 preview。",
                                etaMinutes: nil,
                                runtimeMetrics: localPreviewMetrics
                            )
                        )
                    }

                    guard let bridge else {
                        store.updateProcessingState(
                            recordId: recordId,
                            status: .failed,
                            statusMessage: "本地处理没有启动成功",
                            detailMessage: "本地协调器没有准备好，这次无法继续生成本地结果。",
                            progressFraction: LocalPreviewWorkflowPhase.refine.startFraction,
                            progressBasis: LocalPreviewWorkflowPhase.refine.progressBasis,
                            remoteStageKey: localWorkflowStageKey,
                            remotePhaseName: LocalPreviewWorkflowPhase.refine.phaseName,
                            runtimeMetrics: localPreviewMetrics,
                            estimatedRemainingMinutes: nil,
                            frameSamplingProfile: selectedFrameSamplingProfile.rawValue,
                            failureReason: "local_subject_first_bridge_missing"
                        )
                        await MainActor.run {
                            self.backgroundExportStatusMessage = "本地处理失败"
                            self.trainingActive = false
                        }
                        return
                    }

                    let applyMemoryOnlyLocalPreviewPhase: @MainActor @Sendable (LocalPreviewPhaseUpdate) -> Void = { update in
                        let phaseStore = ScanRecordStore()
                        phaseStore.updateProcessingState(
                            recordId: recordId,
                            status: update.phase == .export ? ScanRecordStatus.packaging : ScanRecordStatus.training,
                            statusMessage: update.title,
                            detailMessage: update.detail,
                            progressFraction: update.progressFraction,
                            progressBasis: update.phase.progressBasis,
                            remoteStageKey: localWorkflowStageKey,
                            remotePhaseName: update.phase.phaseName,
                            runtimeMetrics: update.runtimeMetrics,
                            estimatedRemainingMinutes: nil,
                            sourceVideoPath: "memory_only",
                            frameSamplingProfile: selectedFrameSamplingProfile.rawValue,
                            clearRemoteJobId: true
                        )
                    }

                    let localResult = LocalPreviewCaptureRunner.execute(
                        recordId: recordId,
                        bridge: bridge,
                        exportDir: exportDir,
                        plyURL: plyURL,
                        worldStateFrames: worldStateFrames,
                        surfaceSamples: surfaceSamples,
                        sourceVideoRelativePath: "memory_only",
                        processingBackend: processingBackend,
                        onPhaseUpdate: { update in
                            Task { @MainActor in
                                applyMemoryOnlyLocalPreviewPhase(update)
                            }
                        }
                    )

                    if localResult.exported, let artifactPath = localResult.artifactRelativePath {
                        store.updateProcessingState(
                            recordId: recordId,
                            status: .completed,
                            statusMessage: localModeResultTitle,
                            detailMessage: localResult.detailMessage,
                            progressFraction: 1.0,
                            progressBasis: LocalPreviewWorkflowPhase.export.progressBasis,
                            remoteStageKey: localWorkflowStageKey,
                            remotePhaseName: LocalPreviewWorkflowPhase.export.phaseName,
                            runtimeMetrics: localResult.runtimeMetrics,
                            estimatedRemainingMinutes: 0,
                            sourceVideoPath: "memory_only",
                            frameSamplingProfile: selectedFrameSamplingProfile.rawValue,
                            clearRemoteJobId: true
                        )
                        store.updateArtifactPath(recordId: recordId, artifactPath: artifactPath)
                        await MainActor.run {
                            self.backgroundExportStatusMessage = "本地导出完成"
                            self.trainingProgress = 1.0
                            self.trainingActive = false
                            NSLog("[Aether3D] Background export: local result artifact=%@", artifactPath)
                        }
                    } else {
                        store.updateProcessingState(
                            recordId: recordId,
                            status: .failed,
                            statusMessage: localModeFailureTitle,
                            detailMessage: localResult.detailMessage,
                            progressFraction: 0.92,
                            progressBasis: LocalPreviewWorkflowPhase.export.progressBasis,
                            remoteStageKey: localWorkflowStageKey,
                            remotePhaseName: LocalPreviewWorkflowPhase.export.phaseName,
                            runtimeMetrics: localResult.runtimeMetrics,
                            estimatedRemainingMinutes: nil,
                            sourceVideoPath: "memory_only",
                            frameSamplingProfile: selectedFrameSamplingProfile.rawValue,
                            failureReason: "local_export_failed"
                        )
                        await MainActor.run {
                            self.backgroundExportStatusMessage = "导出失败"
                            self.trainingActive = false
                        }
                    }
                    return
                }
            }
            #endif

            NSLog("[Aether3D] Background export: waiting for local training convergence...")
            let stepsReached = bridge?.waitForTraining(
                minSteps: 500, timeoutSeconds: 60.0) ?? 0
            NSLog("[Aether3D] Background export: local training reached %d steps", stepsReached)

            let exported: Bool
            if bridge?.exportPLY(path: plyURL.path) == true {
                exported = true
                NSLog("[Aether3D] ✅ Background export: trained PLY → %@", plyURL.path)
            } else if bridge?.exportPointCloudPLY(path: plyURL.path) == true {
                exported = true
                NSLog("[Aether3D] ✅ Background export: point cloud fallback PLY → %@", plyURL.path)
            } else {
                exported = false
                NSLog("[Aether3D] ❌ Background export: both exports failed")
            }

            Self.writeWorldStateIfAvailable(
                recordId: recordId,
                exportDir: exportDir,
                worldStateFrames: worldStateFrames,
                surfaceSamples: surfaceSamples
            )

            if exported {
                let localPreviewMetrics = LocalPreviewMetricsArchive.runtimeMetrics(
                    snapshot: bridge?.getSnapshot(),
                    sourceVideo: sourceVideoRelativePath ?? "memory_only",
                    exported: true,
                    sourceKind: LocalPreviewProductProfile.directCaptureSourceKind(
                        sourceVideoRelativePath: sourceVideoRelativePath ?? "memory_only"
                    ),
                    processingBackend: processingBackend
                )
                store.updateProcessingState(
                    recordId: recordId,
                    status: .completed,
                    statusMessage: localModeResultTitle,
                    detailMessage: processingBackend == .localSubjectFirst
                        ? "现在可以进入本地结果查看，后续还能继续加 cutout / cleanup。"
                        : "现在可以进入黑色 3D 空间自由查看",
                    progressFraction: 1.0,
                    progressBasis: LocalPreviewWorkflowPhase.export.progressBasis,
                    remoteStageKey: localWorkflowStageKey,
                    remotePhaseName: LocalPreviewWorkflowPhase.export.phaseName,
                    runtimeMetrics: localPreviewMetrics,
                    estimatedRemainingMinutes: 0,
                    sourceVideoPath: sourceVideoRelativePath,
                    frameSamplingProfile: selectedFrameSamplingProfile.rawValue,
                    clearRemoteJobId: true
                )
                let artifactPath = Self.relativeArtifactPath(for: recordId)
                store.updateArtifactPath(recordId: recordId, artifactPath: artifactPath)
                await MainActor.run {
                    self.backgroundExportStatusMessage = "本地导出完成"
                    self.trainingProgress = 1.0
                    self.trainingActive = false
                    NSLog("[Aether3D] Background export: record updated with artifact=%@", artifactPath)
                }
            } else {
                let localPreviewMetrics = LocalPreviewMetricsArchive.runtimeMetrics(
                    snapshot: bridge?.getSnapshot(),
                    sourceVideo: sourceVideoRelativePath ?? "memory_only",
                    exported: false,
                    sourceKind: LocalPreviewProductProfile.directCaptureSourceKind(
                        sourceVideoRelativePath: sourceVideoRelativePath ?? "memory_only"
                    ),
                    processingBackend: processingBackend
                )
                store.updateProcessingState(
                    recordId: recordId,
                    status: .failed,
                    statusMessage: localModeFailureTitle,
                    detailMessage: "这次没有拿到可用的 3DGS 结果，请重新拍一轮。",
                    progressFraction: 0.92,
                    progressBasis: LocalPreviewWorkflowPhase.export.progressBasis,
                    remoteStageKey: localWorkflowStageKey,
                    remotePhaseName: LocalPreviewWorkflowPhase.export.phaseName,
                    runtimeMetrics: localPreviewMetrics,
                    estimatedRemainingMinutes: nil,
                    sourceVideoPath: sourceVideoRelativePath,
                    frameSamplingProfile: selectedFrameSamplingProfile.rawValue,
                    failureReason: "local_export_failed"
                )
                await MainActor.run {
                    self.backgroundExportStatusMessage = "导出失败"
                    self.trainingActive = false
                }
            }
        }
    }

    // ═══════════════════════════════════════════════════════════════════════
    // MARK: - Pose Stabilization
    // ═══════════════════════════════════════════════════════════════════════

    private func stabilizedCameraTransform(
        rawCameraTransform: simd_float4x4,
        timestamp: TimeInterval
    ) -> simd_float4x4 {
        if !isSubjectFirstLocalMode {
            ensurePoseStabilizerIfNeeded()
        }
        guard let stabilizer = poseStabilizer else {
            return rawCameraTransform
        }

        let rawPose = simdToColumnMajor(rawCameraTransform)
        let timestampNs = UInt64(max(timestamp, 0.0) * 1_000_000_000.0)
        let imuZero: [Float] = [0.0, 0.0, 0.0]
        var stabilizedResult: ([Float], Float)?
        rawPose.withUnsafeBufferPointer { rawPtr in
            imuZero.withUnsafeBufferPointer { gyroPtr in
                imuZero.withUnsafeBufferPointer { accelPtr in
                    guard let rawBase = rawPtr.baseAddress,
                          let gyroBase = gyroPtr.baseAddress,
                          let accelBase = accelPtr.baseAddress else {
                        stabilizedResult = nil
                        return
                    }
                    stabilizedResult = NativePoseStabilizerBridge.update(
                        stabilizer,
                        rawPose: rawBase,
                        gyro: gyroBase,
                        accel: accelBase,
                        timestampNs: timestampNs
                    )
                }
            }
        }
        guard let (stabilizedPose, quality) = stabilizedResult else {
            return rawCameraTransform
        }

        lastPoseQuality = quality
        if quality < Self.poseMinimumAcceptedQuality {
            return rawCameraTransform
        }

        let predictTimestampNs = timestampNs > UInt64.max - Self.posePredictionLeadNs
            ? UInt64.max
            : timestampNs + Self.posePredictionLeadNs
        let predictedPose = NativePoseStabilizerBridge.predict(
            stabilizer,
            targetTimestampNs: predictTimestampNs
        ) ?? stabilizedPose

        return columnMajorToSimd(predictedPose)
            ?? columnMajorToSimd(stabilizedPose)
            ?? rawCameraTransform
    }

    private func ensurePoseStabilizerIfNeeded() {
        guard poseStabilizer == nil else { return }
        poseStabilizer = NativePoseStabilizerBridge.create()
    }

    private func simdToColumnMajor(_ matrix: simd_float4x4) -> [Float] {
        [
            matrix.columns.0.x, matrix.columns.0.y, matrix.columns.0.z, matrix.columns.0.w,
            matrix.columns.1.x, matrix.columns.1.y, matrix.columns.1.z, matrix.columns.1.w,
            matrix.columns.2.x, matrix.columns.2.y, matrix.columns.2.z, matrix.columns.2.w,
            matrix.columns.3.x, matrix.columns.3.y, matrix.columns.3.z, matrix.columns.3.w
        ]
    }

    private func columnMajorToSimd(_ values: [Float]) -> simd_float4x4? {
        guard values.count >= 16 else { return nil }
        return simd_float4x4(columns: (
            SIMD4<Float>(values[0], values[1], values[2], values[3]),
            SIMD4<Float>(values[4], values[5], values[6], values[7]),
            SIMD4<Float>(values[8], values[9], values[10], values[11]),
            SIMD4<Float>(values[12], values[13], values[14], values[15])
        ))
    }

    private func refreshCaptureGuidance(force: Bool = false, now: CFAbsoluteTime = CFAbsoluteTimeGetCurrent()) {
        if scanState == .capturing && !force {
            if now - lastGuidancePublishTime < Self.guidancePublishInterval {
                return
            }
        }
        lastGuidancePublishTime = now
        switch scanState {
        case .initializing:
            liveGuidanceTitle = isSubjectFirstLocalMode ? "正在启动本地模式" : "正在启动扫描环境"
            liveGuidanceDetail = isSubjectFirstLocalMode
                ? "第一次进入会做相机和本地几何引擎准备，请保持手机稳定。"
                : "第一次进入会做相机和本地引擎准备，请保持手机稳定。"
        case .ready:
            if pendingCaptureStartAfterCoordinatorReady || isInitializingCoordinator {
                liveGuidanceTitle = isSubjectFirstLocalMode ? "相机已就绪，本地引擎仍在加载" : "相机已就绪，扫描引擎仍在加载"
                liveGuidanceDetail = isSubjectFirstLocalMode
                    ? "本地链路准备好后会自动开始计时，请先把目标和接触面稳稳放进画面。"
                    : "本地几何引擎准备好后会自动开始计时和扫描，请先稳住构图。"
            } else {
                liveGuidanceTitle = isSubjectFirstLocalMode ? "可以开始主体采集了" : "可以开始拍摄了"
                liveGuidanceDetail = isSubjectFirstLocalMode
                    ? "先把主体正面和桌面接触区拍稳，再缓慢补侧面、顶部和背面。"
                    : "先拍正面，再缓慢绕到侧面和顶部，尽量让物体始终留在画面里。"
            }
        case .capturing:
            if pendingCaptureStartAfterCoordinatorReady && coordinatorBridge == nil {
                liveGuidanceTitle = "相机已启动，正在加载本地引擎"
                liveGuidanceDetail = isSubjectFirstLocalMode
                    ? "你可以先正常围绕主体拍摄，画面会保留；引擎准备好后会自动接管后续处理。"
                    : "你可以先正常拍摄，画面不会黑屏；本地引擎准备好后会自动开始接收帧。"
                return
            }
            if isSubjectFirstLocalMode && isInitializingCoordinator && coordinatorBridge == nil {
                liveGuidanceTitle = "正在连接几何反馈"
                liveGuidanceDetail = "视频录制已经开始；绿黄红几何点会在本地引擎准备好后出现。"
                return
            }
            if motionWarningActive {
                liveGuidanceTitle = "移动有点快"
                liveGuidanceDetail = isSubjectFirstLocalMode
                    ? "请放慢绕拍速度，优先保证主体边界和底部接触区清楚。"
                    : "请放慢绕拍速度，尽量保持稳定，让远端更容易重建相机轨迹。"
            } else if exposureWarningActive {
                liveGuidanceTitle = "当前光线不太理想"
                liveGuidanceDetail = "尽量避免过暗、过曝和强烈背光，让物体表面纹理更清楚。"
            } else if stabilityWarningActive {
                liveGuidanceTitle = "请再稳一点"
                liveGuidanceDetail = "短暂停一下再继续，让姿态稳定器更快收敛。"
            } else if isSubjectFirstLocalMode {
                liveGuidanceTitle = subjectCaptureTargetTitle
                liveGuidanceDetail = subjectCaptureTargetDetail
            } else {
                liveGuidanceTitle = sceneCaptureTargetTitle
                liveGuidanceDetail = sceneCaptureTargetDetail
            }
        case .paused:
            liveGuidanceTitle = "扫描已暂停"
            liveGuidanceDetail = sessionPauseMessage ?? "你可以继续拍摄，也可以直接结束，稍后进入等待页。"
        case .finishing:
            liveGuidanceTitle = isSubjectFirstLocalMode ? "正在整理本地结果" : "正在整理本次拍摄"
            liveGuidanceDetail = isSubjectFirstLocalMode
                ? "稍后会继续执行主体 cutout、边角 cleanup 和本地导出。"
                : "稍后会自动进入后台上传与远端训练流程，并进入等待页。"
        case .completed:
            liveGuidanceTitle = "作品已经准备好"
            liveGuidanceDetail = "现在可以在黑色空间里自由查看 3DGS。"
        case .failed:
            liveGuidanceTitle = "扫描被中断了"
            liveGuidanceDetail = scanFailureMessage ?? "请返回主页重新开始一次新的拍摄。"
        }
    }

    private func shouldPublishCaptureHUD(now: CFAbsoluteTime) -> Bool {
        guard scanState == .capturing else { return true }
        if now - lastCaptureHUDPublishTime >= Self.captureHUDPublishInterval {
            lastCaptureHUDPublishTime = now
            return true
        }
        return false
    }

    nonisolated private static func summarizeCaptureGeometry(
        from renderData: PipelineCoordinatorBridge.RenderData?
    ) -> CaptureGeometrySummary {
        #if canImport(CAetherNativeBridge)
        if let renderData,
           renderData.pointCloudCount > 0,
           let pointCloudVertices = renderData.pointCloudVertices {
            let floatsPerPoint = 8
            let totalFloats = renderData.pointCloudCount * floatsPerPoint
            let pointPointer = pointCloudVertices.bindMemory(
                to: Float.self,
                capacity: totalFloats
            )
            let values = UnsafeBufferPointer(start: pointPointer, count: totalFloats)

            var weak = 0
            var recoverable = 0
            var stable = 0
            for index in 0..<renderData.pointCloudCount {
                let base = index * floatsPerPoint
                let r = max(0, min(1, values[base + 3]))
                let g = max(0, min(1, values[base + 4]))
                let alpha = max(0, min(1, values[base + 7]))
                if alpha < 0.05 { continue }
                if g >= 0.80 && r <= 0.45 {
                    stable += 1
                } else if r >= 0.85 && g <= 0.45 {
                    weak += 1
                } else {
                    recoverable += 1
                }
            }
            return CaptureGeometrySummary(weakCount: weak, recoverableCount: recoverable, stableCount: stable)
        }
        return CaptureGeometrySummary(weakCount: 0, recoverableCount: 0, stableCount: 0)
        #else
        _ = renderData
        return CaptureGeometrySummary(weakCount: 0, recoverableCount: 0, stableCount: 0)
        #endif
    }

    private func updateCaptureGeometrySummary(from renderData: PipelineCoordinatorBridge.RenderData?) {
        let summary = Self.summarizeCaptureGeometry(from: renderData)
        captureWeakGeometryCount = summary.weakCount
        captureRecoverableGeometryCount = summary.recoverableCount
        captureStableGeometryCount = summary.stableCount
    }

    private enum CaptureGeometryFocus {
        case waiting
        case gather
        case expand
        case reinforce
        case finish
    }

    private var captureGeometrySummary: CaptureGeometrySummary {
        CaptureGeometrySummary(
            weakCount: captureWeakGeometryCount,
            recoverableCount: captureRecoverableGeometryCount,
            stableCount: captureStableGeometryCount
        )
    }

    private var captureGeometryFocus: CaptureGeometryFocus {
        let summary = captureGeometrySummary
        let total = summary.totalCount
        if total == 0 {
            return .waiting
        }

        let weakRatio = Float(summary.weakCount) / Float(max(total, 1))
        let stableRatio = Float(summary.stableCount) / Float(max(total, 1))

        if debugHasS6Quality && weakRatio < 0.10 && stableRatio > 0.45 {
            return .finish
        }
        if total < 12 || summary.stableCount < 4 {
            return .gather
        }
        if weakRatio > 0.42 || stableRatio < 0.18 {
            return .expand
        }
        if summary.recoverableCount >= summary.stableCount {
            return .reinforce
        }
        if debugSelectedFrames >= 90 && weakRatio < 0.16 {
            return .finish
        }
        return .reinforce
    }

    var subjectCaptureCompactTargetText: String {
        switch captureGeometryFocus {
        case .waiting:
            return "等几何图"
        case .gather:
            return "先拿到几何"
        case .expand:
            return "补新视角"
        case .reinforce:
            return "补红黄区域"
        case .finish:
            return "可以结束"
        }
    }

    private var captureKeyframeBudget: CaptureKeyframeBudget {
        let engineStart = isSubjectFirstLocalMode ? 3 : max(debugMinFramesNeeded, 1)
        let recommended: (Int, Int, Int)
        switch FrameSamplingProfile.currentSelection() {
        case .full:
            recommended = (30, 90, 150)
        case .half:
            recommended = (24, 72, 120)
        case .third:
            recommended = (20, 60, 90)
        }
        return CaptureKeyframeBudget(
            engineStart: engineStart,
            recommendedMin: max(engineStart, recommended.0),
            recommendedTarget: max(engineStart, recommended.1),
            recommendedMax: max(engineStart, recommended.2)
        )
    }

    var captureKeyframeEngineStartCount: Int {
        captureKeyframeBudget.engineStart
    }

    var captureKeyframeRecommendedMin: Int {
        captureKeyframeBudget.recommendedMin
    }

    var captureKeyframeRecommendedTarget: Int {
        captureKeyframeBudget.recommendedTarget
    }

    var captureKeyframeRecommendedMax: Int {
        captureKeyframeBudget.recommendedMax
    }

    var captureSeedEstimatedCount: Int {
        let queuedEstimate = max(debugAssignedBlocks + debugPendingGaussians, 0)
        let previewEstimate = max(debugPreviewSeedAccepted, 0)
        return max(previewEstimate, queuedEstimate)
    }

    var captureSeedTargetCount: Int {
        12_000
    }

    var captureSeedProgressFraction: Double {
        min(1.0, Double(captureSeedEstimatedCount) / Double(max(captureSeedTargetCount, 1)))
    }

    var captureSeedMetricText: String {
        "\(captureSeedEstimatedCount)/\(captureSeedTargetCount)"
    }

    var captureSeedStatusTitle: String {
        let estimated = captureSeedEstimatedCount
        switch estimated {
        case ..<1500:
            return "保底偏弱"
        case ..<5000:
            return "正在长 seed"
        case ..<12000:
            return "接近保底"
        default:
            return "保底已够"
        }
    }

    var captureSeedHint: String {
        let estimated = captureSeedEstimatedCount
        switch estimated {
        case ..<1500:
            return "当前 live 几何证据还偏薄，拍后本地链大概率还拿不到稳定 seed。"
        case ..<5000:
            return "已经在长 seed 了，但还不稳，继续补真正的新视角最有用。"
        case ..<12000:
            return "seed 保底快够了，再补几圈有效视角，拍后更容易直接开训。"
        default:
            return "seed 保底已经够了，后面优先补缺口，不用再单纯刷数量。"
        }
    }

    var captureKeyframeProgressFraction: Double {
        let target = max(captureKeyframeRecommendedTarget, 1)
        return min(1.0, Double(debugSelectedFrames) / Double(target))
    }

    var captureKeyframeAcceptanceRatio: Double {
        let total = max(debugKeyframeGateAccepts + debugKeyframeGateRejects, 1)
        return Double(debugKeyframeGateAccepts) / Double(total)
    }

    var captureKeyframeAcceptanceRateText: String {
        let total = debugKeyframeGateAccepts + debugKeyframeGateRejects
        guard total > 0 else { return "等待判帧" }
        return String(
            format: "%.0f%% 通过",
            captureKeyframeAcceptanceRatio * 100.0
        )
    }

    var captureKeyframeRecommendedRangeText: String {
        "\(captureKeyframeRecommendedMin)-\(captureKeyframeRecommendedMax)"
    }

    var captureKeyframeStatusTitle: String {
        let selected = debugSelectedFrames
        if selected < captureKeyframeRecommendedMin {
            return "继续收关键帧"
        }
        if selected < captureKeyframeRecommendedTarget {
            return "关键帧正在变稳"
        }
        if selected <= captureKeyframeRecommendedMax {
            return "关键帧充足"
        }
        return "数量已经够了"
    }

    var captureKeyframeHint: String {
        let selected = debugSelectedFrames
        if motionWarningActive {
            return "放慢一点。移动过快时，很多帧会因为模糊或姿态不稳变成无效关键帧。"
        }
        if stabilityWarningActive {
            return "先稳一下再继续。姿态稳定后，新的观察角度才更容易被记成有效关键帧。"
        }
        if exposureWarningActive {
            return "先把光线拉稳。纹理不清时，关键帧即使进来了，后面的 seed 质量也会偏差。"
        }
        if selected < captureKeyframeRecommendedMin {
            if captureKeyframeAcceptanceRatio < 0.35 && debugKeyframeGateRejects >= 6 {
                return "当前很多帧被判成近重复视角了。别原地抖，继续绕着物体换到新角度。"
            }
            return "继续补到 \(captureKeyframeRecommendedMin)+ 张有效关键帧，先把关键帧和 seed 保底一起拉稳。"
        }
        if selected < captureKeyframeRecommendedTarget {
            return "继续补新方向，把有效关键帧推到 \(captureKeyframeRecommendedTarget) 左右会更稳。"
        }
        if selected <= captureKeyframeRecommendedMax {
            return "关键帧已经够用。现在优先补缺口，不用为了刷数量在原地抖动。"
        }
        return "关键帧已经偏多了。除非还有明显缺口，否则可以考虑结束拍摄。"
    }

    var subjectCaptureTargetTitle: String {
        switch captureGeometryFocus {
        case .waiting:
            return "正在准备稀疏几何图"
        case .gather:
            return "先让几何稳定成片"
        case .expand:
            return "继续补新的观察方向"
        case .reinforce:
            return "把红黄区域补成绿色"
        case .finish:
            return "当前几何已经比较稳了"
        }
    }

    var subjectCaptureTargetDetail: String {
        if motionWarningActive {
            return "先放慢移动，别让拖影和近重复视角把几何质量拉低。"
        }
        if exposureWarningActive {
            return "先把光线调稳，表面纹理不清会让几何图长期停在黄红色。"
        }
        if stabilityWarningActive {
            return "先稳一下再继续，姿态不稳时补拍价值很低。"
        }
        switch captureGeometryFocus {
        case .waiting:
            return "先保持主体或场景主体区域稳定入镜，几何图起来后再看红黄绿反馈。"
        case .gather:
            return "别原地抖动，缓慢移动到新的角度，让稀疏几何先真正长出来。"
        case .expand:
            return "继续绕拍或换到新的方向，优先补当前还是红色的薄弱区域。"
        case .reinforce:
            return "保持慢速小步移动，把黄色区域拍成绿色，再顺手补掉少量红色缺口。"
        case .finish:
            return "大部分区域已经稳定；满意就可以结束，后面再做 cutout 和边界整理。"
        }
    }

    var sceneCaptureTargetTitle: String {
        switch captureGeometryFocus {
        case .waiting:
            return "正在准备稀疏几何图"
        case .gather:
            return "先让几何稳定成片"
        case .expand:
            return "继续补新的观察方向"
        case .reinforce:
            return "把黄红区域补稳"
        case .finish:
            return "当前几何已经比较稳了"
        }
    }

    var sceneCaptureTargetDetail: String {
        if motionWarningActive {
            return "请放慢移动，先保证画面清晰和足够的新视角。"
        }
        if exposureWarningActive {
            return "尽量避免过暗、过曝和强烈背光，让表面纹理和几何证据更稳定。"
        }
        if stabilityWarningActive {
            return "短暂停一下再继续，让姿态和几何估计先稳定下来。"
        }
        switch captureGeometryFocus {
        case .waiting:
            return "先把主要区域稳稳拍进来，等稀疏几何图起来后再看红黄绿状态。"
        case .gather:
            return "别原地抖动，缓慢移动到新角度，让几何证据先真正长出来。"
        case .expand:
            return "继续补新的方向，优先覆盖目前还是红色或薄弱的区域。"
        case .reinforce:
            return "保持慢速小步移动，把黄色区域补成绿色，再顺手补掉少量红色缺口。"
        case .finish:
            return "大部分区域已经稳定；满意就可以结束，后面再做重建和边界整理。"
        }
    }

    var subjectCaptureBudgetAdvice: String {
        let selected = debugSelectedFrames
        if selected < captureKeyframeRecommendedMin {
            return "继续补到 \(captureKeyframeRecommendedMin)+ 张有效关键帧"
        }
        if selected <= captureKeyframeRecommendedMax {
            return "关键帧预算合适，优先补缺口"
        }
        return "关键帧偏多，除非还有缺口否则可以结束"
    }

    // ═══════════════════════════════════════════════════════════════════════
    // MARK: - Motion & Feedback
    // ═══════════════════════════════════════════════════════════════════════

    private func extractMotionMagnitude(from transform: simd_float4x4, timestamp: TimeInterval) -> Double {
        let position = SIMD3<Float>(
            transform.columns.3.x,
            transform.columns.3.y,
            transform.columns.3.z
        )
        defer {
            lastMotionSample = (position: position, timestamp: timestamp)
        }

        guard let previous = lastMotionSample else { return 0 }
        let dt = max(timestamp - previous.timestamp, 1.0 / 240.0)
        let delta = position - previous.position
        return Double(simd_length(delta) / Float(dt))
    }

    // ═══════════════════════════════════════════════════════════════════════
    // MARK: - Timer
    // ═══════════════════════════════════════════════════════════════════════

    private func startElapsedTimer() {
        elapsedTimer?.invalidate()
        elapsedTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self = self, let start = self.captureStartTime else { return }
                self.elapsedTime = Date().timeIntervalSince(start)
            }
        }
    }

    private func stopElapsedTimer() {
        elapsedTimer?.invalidate()
        elapsedTimer = nil
    }

    // ═══════════════════════════════════════════════════════════════════════
    // MARK: - Thermal Monitoring
    // ═══════════════════════════════════════════════════════════════════════

    private func setupThermalMonitoring() {
        #if os(iOS)
        thermalObserver = NotificationCenter.default.addObserver(
            forName: ProcessInfo.thermalStateDidChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                let state = ProcessInfo.processInfo.thermalState
                self?.thermalAdapter.updateThermalState(state)
                self?.coordinatorBridge?.setThermalState(state.rawValue)
            }
        }
        thermalAdapter.updateThermalState(ProcessInfo.processInfo.thermalState)
        #endif
    }

    // ═══════════════════════════════════════════════════════════════════════
    // MARK: - Reset
    // ═══════════════════════════════════════════════════════════════════════

    private func resetSubsystems() {
        #if canImport(AVFoundation)
        remoteVideoRecorder?.cancel()
        remoteVideoRecorder = nil
        remoteVideoRecorderMinFrameStep = 0
        lastRemoteVideoFrameEnqueueTimestamp = nil
        #endif
        backgroundExportStatusMessage = nil

        // ── 1. Shut down Metal render pipeline (drain semaphore, prevent deadlock) ──
        // Must happen BEFORE coordinator teardown so the MTKView draw loop
        // doesn't block on a semaphore that will never be signaled.
        #if canImport(Metal)
        renderPipeline?.shutdown()
        #endif

        // ── 2. Move C++ coordinator + native handles to background for teardown ──
        // PipelineCoordinatorBridge.deinit → aether_pipeline_coordinator_destroy
        //   → stop_threads() → thread.join()
        // The training thread's train_step() can block for 1-5 seconds on GPU work.
        // Joining on the main thread freezes the entire UI.
        teardownCoordinatorAsync()

        // ── 3. Reset local state ──
        trainingActive = false
        trainingProgress = 0.0
        coveragePercent = 0.0
        debugPointCloudCount = 0
        debugOverlayCount = 0
        debugSplatCount = 0
        debugPointCloudAlpha = -1.0
        debugTrainingStep = 0
        debugTotalSteps = 0
        debugLoss = 0.0
        debugNumGaussians = 0
        debugAssignedBlocks = 0
        debugPendingGaussians = 0
        debugPreviewSeedAccepted = 0
        debugPreviewSeedCandidates = 0
        debugEncodeDrawCount = 0
        debugEncodeSkipCount = 0
        debugSelectedFrames = 0
        debugKeyframeGateAccepts = 0
        debugKeyframeGateRejects = 0
        debugPipelineFrameCount = 0
        debugFrameCount = 0
        debugHasS6Quality = false
        debugIsGPUTraining = false
        captureWeakGeometryCount = 0
        captureRecoverableGeometryCount = 0
        captureStableGeometryCount = 0
        if let stabilizer = poseStabilizer {
            NativePoseStabilizerBridge.reset(stabilizer)
        }
        lastPoseQuality = 0.0
        frameCounter = 0
        lastMotionSample = nil
        isInitializingCoordinator = false
        pendingCaptureStartAfterCoordinatorReady = false
        activeCoordinatorBackend = nil
        worldStateRecorder.reset()
    }

    /// Detach C++ coordinator + native handle destruction to a background queue.
    /// Destroy order: coordinator → splatEngine → gpuDevice (each references the next).
    private func teardownCoordinatorAsync() {
        let teardown = CoordinatorTeardownBox(coordinatorBridge)
        coordinatorBridge = nil

        #if canImport(CAetherNativeBridge) && canImport(Metal)
        let engine = splatEngineHandle.map { SendableHandle(pointer: $0) }
        let device = gpuDeviceHandle.map { SendableHandle(pointer: $0) }
        splatEngineHandle = nil
        gpuDeviceHandle = nil

        DispatchQueue.global(qos: .utility).async {
            // bridge deinit → aether_pipeline_coordinator_destroy → stop_threads → join
            // Releasing bridge forces deallocation at this exact point.
            teardown.bridge = nil

            // Then destroy engine and device (must outlive coordinator)
            if let e = engine { aether_splat_engine_destroy(e.pointer) }
            if let d = device { aether_gpu_device_destroy(d.pointer) }
        }
        #else
        teardown.bridge = nil
        #endif
    }
}

#if canImport(AVFoundation) && canImport(CoreVideo)
private final class ARFrameVideoRecorder: @unchecked Sendable {
    private let outputURL: URL
    private let targetFPS: Double
    private let detachSourceFrames: Bool
    private let queue = DispatchQueue(label: "com.aether3d.scan.remote-video-recorder")
    private let appendStateLock = NSLock()

    private var writer: AVAssetWriter?
    private var writerInput: AVAssetWriterInput?
    private var pixelBufferAdaptor: AVAssetWriterInputPixelBufferAdaptor?
    private var didAppendFrame = false
    private var isFinishing = false
    private var startTimestamp: TimeInterval?
    private var lastAppendedPresentationTime: TimeInterval?
    private var finishContinuations: [CheckedContinuation<URL?, Never>] = []
    private var queuedFrameCount = 0
    private let maxQueuedFrames = 2

    init(
        outputURL: URL,
        targetFPS: Double = 18.0,
        detachSourceFrames: Bool = false
    ) {
        self.outputURL = outputURL
        self.targetFPS = max(1.0, targetFPS)
        self.detachSourceFrames = detachSourceFrames
    }

    func appendFrame(pixelBuffer: CVPixelBuffer, timestamp: TimeInterval) {
        appendStateLock.lock()
        let shouldDropForBackpressure = isFinishing || queuedFrameCount >= maxQueuedFrames
        if !shouldDropForBackpressure {
            queuedFrameCount += 1
        }
        appendStateLock.unlock()
        guard !shouldDropForBackpressure else { return }

        let queuedPixelBuffer: CVPixelBuffer
        if detachSourceFrames {
            guard let copied = Self.clonePixelBuffer(pixelBuffer) else {
                appendStateLock.lock()
                queuedFrameCount = max(0, queuedFrameCount - 1)
                appendStateLock.unlock()
                return
            }
            queuedPixelBuffer = copied
        } else {
            queuedPixelBuffer = pixelBuffer
        }

        queue.async { [weak self] in
            guard let self else { return }
            defer {
                self.appendStateLock.lock()
                self.queuedFrameCount = max(0, self.queuedFrameCount - 1)
                self.appendStateLock.unlock()
            }
            guard !self.isFinishing else { return }
            guard self.prepareWriterIfNeeded(from: queuedPixelBuffer) else { return }

            if self.startTimestamp == nil {
                self.startTimestamp = timestamp
                self.writer?.startWriting()
                self.writer?.startSession(atSourceTime: .zero)
            }

            let baseTimestamp = self.startTimestamp ?? timestamp
            let presentationSeconds = max(0.0, timestamp - baseTimestamp)
            let minStep = 1.0 / self.targetFPS
            if let last = self.lastAppendedPresentationTime,
               presentationSeconds - last < minStep {
                return
            }

            guard let writerInput = self.writerInput,
                  let adaptor = self.pixelBufferAdaptor,
                  writerInput.isReadyForMoreMediaData else {
                return
            }

            let presentationTime = CMTime(seconds: presentationSeconds, preferredTimescale: 600)
            if adaptor.append(queuedPixelBuffer, withPresentationTime: presentationTime) {
                self.didAppendFrame = true
                self.lastAppendedPresentationTime = presentationSeconds
            }
        }
    }

    func finish() async -> URL? {
        await withCheckedContinuation { continuation in
            queue.async { [weak self] in
                guard let self else {
                    continuation.resume(returning: nil)
                    return
                }

                self.finishContinuations.append(continuation)
                if self.isFinishing {
                    return
                }
                self.isFinishing = true

                guard let writer = self.writer,
                      let writerInput = self.writerInput,
                      self.didAppendFrame else {
                    try? FileManager.default.removeItem(at: self.outputURL)
                    self.resolveFinishContinuations(with: nil)
                    return
                }

                writerInput.markAsFinished()
                writer.finishWriting { [weak self] in
                    guard let self else { return }
                    self.queue.async {
                        let result: URL?
                        if writer.status == .completed {
                            result = self.outputURL
                        } else {
                            try? FileManager.default.removeItem(at: self.outputURL)
                            result = nil
                        }
                        self.resolveFinishContinuations(with: result)
                    }
                }
            }
        }
    }

    func cancel() {
        queue.async { [weak self] in
            guard let self else { return }
            self.isFinishing = true
            self.writerInput?.markAsFinished()
            self.writer?.cancelWriting()
            try? FileManager.default.removeItem(at: self.outputURL)
            self.resolveFinishContinuations(with: nil)
        }
    }

    private func prepareWriterIfNeeded(from pixelBuffer: CVPixelBuffer) -> Bool {
        if writer != nil {
            return true
        }

        let width = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)
        let pixelFormat = CVPixelBufferGetPixelFormatType(pixelBuffer)

        do {
            try FileManager.default.createDirectory(
                at: outputURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            if FileManager.default.fileExists(atPath: outputURL.path) {
                try FileManager.default.removeItem(at: outputURL)
            }

            let writer = try AVAssetWriter(outputURL: outputURL, fileType: .mp4)
            let outputSettings: [String: Any] = [
                AVVideoCodecKey: AVVideoCodecType.h264,
                AVVideoWidthKey: width,
                AVVideoHeightKey: height,
            ]
            let input = AVAssetWriterInput(mediaType: .video, outputSettings: outputSettings)
            input.expectsMediaDataInRealTime = true

            let sourceAttributes: [String: Any] = [
                kCVPixelBufferPixelFormatTypeKey as String: Int(pixelFormat),
                kCVPixelBufferWidthKey as String: width,
                kCVPixelBufferHeightKey as String: height,
            ]
            let adaptor = AVAssetWriterInputPixelBufferAdaptor(
                assetWriterInput: input,
                sourcePixelBufferAttributes: sourceAttributes
            )

            guard writer.canAdd(input) else {
                return false
            }
            writer.add(input)

            self.writer = writer
            self.writerInput = input
            self.pixelBufferAdaptor = adaptor
            return true
        } catch {
            return false
        }
    }

    private func resolveFinishContinuations(with result: URL?) {
        let continuations = finishContinuations
        finishContinuations.removeAll(keepingCapacity: false)
        continuations.forEach { $0.resume(returning: result) }
    }

    private static func clonePixelBuffer(_ source: CVPixelBuffer) -> CVPixelBuffer? {
        let pixelFormat = CVPixelBufferGetPixelFormatType(source)
        let width = CVPixelBufferGetWidth(source)
        let height = CVPixelBufferGetHeight(source)
        let attributes: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: pixelFormat,
            kCVPixelBufferWidthKey as String: width,
            kCVPixelBufferHeightKey as String: height,
            kCVPixelBufferIOSurfacePropertiesKey as String: [:]
        ]

        var destination: CVPixelBuffer?
        guard CVPixelBufferCreate(
            kCFAllocatorDefault,
            width,
            height,
            pixelFormat,
            attributes as CFDictionary,
            &destination
        ) == kCVReturnSuccess,
        let destination else {
            return nil
        }

        CVPixelBufferLockBaseAddress(source, .readOnly)
        CVPixelBufferLockBaseAddress(destination, [])
        defer {
            CVPixelBufferUnlockBaseAddress(destination, [])
            CVPixelBufferUnlockBaseAddress(source, .readOnly)
        }

        let planeCount = CVPixelBufferGetPlaneCount(source)
        if planeCount > 0 {
            for plane in 0..<planeCount {
                guard let srcBase = CVPixelBufferGetBaseAddressOfPlane(source, plane),
                      let dstBase = CVPixelBufferGetBaseAddressOfPlane(destination, plane) else {
                    return nil
                }
                let srcStride = CVPixelBufferGetBytesPerRowOfPlane(source, plane)
                let dstStride = CVPixelBufferGetBytesPerRowOfPlane(destination, plane)
                let rows = CVPixelBufferGetHeightOfPlane(source, plane)
                let bytesPerRow = min(srcStride, dstStride)
                for row in 0..<rows {
                    memcpy(
                        dstBase.advanced(by: row * dstStride),
                        srcBase.advanced(by: row * srcStride),
                        bytesPerRow
                    )
                }
            }
            return destination
        }

        guard let srcBase = CVPixelBufferGetBaseAddress(source),
              let dstBase = CVPixelBufferGetBaseAddress(destination) else {
            return nil
        }
        let srcStride = CVPixelBufferGetBytesPerRow(source)
        let dstStride = CVPixelBufferGetBytesPerRow(destination)
        let rows = CVPixelBufferGetHeight(source)
        let bytesPerRow = min(srcStride, dstStride)
        for row in 0..<rows {
            memcpy(
                dstBase.advanced(by: row * dstStride),
                srcBase.advanced(by: row * srcStride),
                bytesPerRow
            )
        }
        return destination
    }
}
#endif

#endif
