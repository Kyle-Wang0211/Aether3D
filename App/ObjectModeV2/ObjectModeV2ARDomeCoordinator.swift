import Foundation

#if canImport(ARKit) && canImport(SwiftUI) && canImport(simd) && canImport(UIKit)
import ARKit
import SwiftUI
import Combine
import simd
import UIKit
import Accelerate
import CoreImage
import Aether3DCore

// MARK: - Snapshot published to SwiftUI

struct ObjectModeV2DomeSnapshot: Equatable {
    var validFrames: Int = 0
    var excellentCells: Int = 0
    var okCells: Int = 0
    var currentAzimuth: Float = 0       // rad(相对 worldYaw)
    var currentElevation: Float = 0     // rad
    var currentCellState: DomeCellState = .empty
    var trackingOK: Bool = false
    var hintText: String = "把物体放在画面中心,点一下开始。"
    var hasLockedOrigin: Bool = false
}

// MARK: - Coordinator

/// ARKit-based capture coordinator with 36-cell coverage map.
/// 性能:
///   - 不在 coordinator 里持有 ARFrame(只取 pose + imageBuffer 做瞬时 sharpness)。
///   - sharpness 在 background queue 算,主线程不阻塞。
///   - 每帧 publish 一次 snapshot(throttle 到 ~15Hz),SwiftUI 不会爆。
@MainActor
final class ObjectModeV2ARDomeCoordinator: NSObject, ObservableObject {

    // MARK: - Published
    @Published var snapshot = ObjectModeV2DomeSnapshot()

    /// Coverage map 供 DomeView 直读状态(不走 @Published 降低开销)。
    let coverage = DomeCoverageMap()

    /// 外部可注册:当新有效帧落地时触发(用于关联 ImageRecorder 存实图)。
    var onValidFrame: ((UUID, Float, Float, CVPixelBuffer) -> Void)?

    /// 每帧 ARFrame 的分发钩子(nonisolated 线程,别阻塞):给 AR video writer 等消费者用。
    /// unsafe 因为 ARSessionDelegate callback 在非主线程回来。set 约定只能在 main actor 做,
    /// 读在 delegate 线程。写一次 nil→closure 后不再变即可。
    nonisolated(unsafe) var onARFrame: ((ARFrame) -> Void)?

    /// 每次成功 ingest 一个 sample 时触发(MainActor 上下文)。参数 = ARFrame.timestamp(绝对)。
    /// VM 用这个补齐 acceptedFrameTimestampsSec(服务端 curate 阶段要这个字段)。
    var onValidSampleTimestamp: ((TimeInterval) -> Void)?

    /// CaptureSession 接入点 —— ViewModel 在 init 里注入。
    ///
    /// 新管线(Core/Capture): session(_:didUpdate:) 会把每帧 CaptureFrame 推进
    /// 这里,QualityAnalysisObserver 在 10Hz 节流后算 Laplacian variance,
    /// 把 FrameQualityReport 写进 snapshot。本 Coordinator 的 handleFrame
    /// 再从同一个 snapshot 读 sharpness,替代之前的 hardcode 1000。
    ///
    /// 未来的实时渲染 UI 只需 register 一个新的 CaptureFrameObserver 到这个
    /// session,完全不用动本文件。
    ///
    /// 弱引用:这个 coordinator 不应该延长 session 的生命周期。
    /// `nonisolated(unsafe)` 因为 `session(_:didUpdate:)` 在 ARKit delegate
    /// queue 上读这个字段,而本类是 @MainActor。写操作(ViewModel init)只在
    /// MainActor 做,读是对 weak ref 的原子加载,安全。
    nonisolated(unsafe) weak var captureSession: CaptureSession?

    // MARK: - AR
    let session = ARSession()
    private let configuration: ARWorldTrackingConfiguration = {
        let c = ARWorldTrackingConfiguration()
        c.planeDetection = [.horizontal]
        c.worldAlignment = .gravity
        c.isLightEstimationEnabled = true
        return c
    }()

    // MARK: - State
    private var lastPublishTime: TimeInterval = 0
    private let publishInterval: TimeInterval = 1.0 / 15.0
    private var lastSampledTime: TimeInterval = 0
    private let sampleInterval: TimeInterval = 1.0 / 6.0   // 6 samples/sec 进 CoverageMap,防溢出
    private var lastGyroMagnitude: Float = 0
    private var isRunning = false

    /// Camera-up direction captured at the moment the user tapped "lock
    /// center". All subsequent frames are compared against this to
    /// compute tilt. nil before lock.
    private var referenceCameraUp: SIMD3<Float>?

    /// Hard-reject frames whose camera-up deviates from the reference
    /// by more than this many degrees. Chosen to be strict enough that
    /// the final reconstruction boundary isn't fuzzed by lens-corner
    /// bias from consistently-tilted views, while loose enough that
    /// natural handheld sway doesn't trip it.
    ///
    /// Tuning notes:
    ///   * 10° — very strict; users will complain
    ///   * 15° — strict; edges stay crisp
    ///   * 20° — recommended default; generous headroom for shake
    ///   * 30° — lenient; starts letting blur-adjacent frames through
    let maxTiltDegrees: Float = 20.0

    /// Absolute-orientation safety net. Independent of `maxTiltDegrees`
    /// because tilt's reference is "whatever pose you had at lock time"
    /// — if the lock happened in a weird pose, tilt gate is fooled.
    /// Gravity gate anchors on world-up (ARKit's worldAlignment = .gravity
    /// guarantees world y-axis is anti-parallel to gravity), so it's
    /// immune to lock-time noise.
    ///
    /// Rejection: `min(|angle - 0°|, |angle - 90°|) > maxGravityDeviationDegrees`
    /// where `angle = acos(dot(cameraUp, worldUp))` in degrees.
    ///
    /// Tuning notes (match the narration in
    /// CaptureSessionSnapshot.currentGravityDeviationDegrees):
    ///   * 10° — very strict; natural wrist wobble may trip it
    ///   * 15° — default; deliberate tilt from portrait/landscape rejected
    ///   * 20° — moderate; most "just slightly off" poses pass
    ///   * 30° — lenient; nearly anything between portrait and landscape passes
    let maxGravityDeviationDegrees: Float = 15.0

    private let sharpnessQueue = DispatchQueue(label: "aether3d.dome.sharpness", qos: .userInitiated)
    private let ciContext = CIContext(options: [.useSoftwareRenderer: false])

    // MARK: - Lifecycle

    func start() {
        guard !isRunning else { return }
        isRunning = true
        session.delegate = self
        session.run(configuration, options: [.resetTracking, .removeExistingAnchors])
        coverage.onCellStateChanged = { [weak self] _, _ in self?.publishIfDue(force: true) }
        coverage.onAggregateChanged = { [weak self] _, _, _ in self?.publishIfDue() }
    }

    func stop() {
        guard isRunning else { return }
        isRunning = false
        session.pause()
    }

    func resetAll() {
        coverage.reset()
        snapshot = ObjectModeV2DomeSnapshot()
        referenceCameraUp = nil
    }

    // MARK: - 外部驱动模式(不开 ARSession,从 CoreMotion / GuidanceEngine 喂数据)
    // 用于和现有 AVCaptureSession 共存的方案。yaw/pitch 可以直接用 CMDeviceMotion
    // 的 attitude.yaw / attitude.pitch。sharpness 如果没算,可以先传 1000 占位,
    // 上线后配合真实 Laplacian 再细调。

    /// 启用外部驱动模式(不启动 ARKit)。
    func startExternalMode() {
        guard !isRunning else { return }
        isRunning = true
        coverage.onCellStateChanged = { [weak self] _, _ in self?.publishIfDue(force: true) }
        coverage.onAggregateChanged = { [weak self] _, _, _ in self?.publishIfDue() }
        // 外部模式下,worldOrigin 不通过 raycast 锁定,改由 lockExternalOrigin() 调用。
    }

    /// 外部模式下锁定"逻辑原点"—— 用户点十字后调用,记当前 yaw 为扇区 0。
    func lockExternalOrigin(initialYaw: Float) {
        coverage.lockWorldOrigin(SIMD3<Float>(0, 0, 0), yaw: initialYaw)
        var snap = snapshot
        snap.hasLockedOrigin = true
        snap.hintText = "开始绕物体走,每个扇区深绿代表拍够了。"
        snapshot = snap
    }

    /// 外部每帧喂姿态 + 质量。调用方(GuidanceEngine / CoreMotion handler)把
    /// attitude.yaw(绝对 yaw) / attitude.pitch 直接传进来;sharpness 若无实测
    /// 可传固定值(比如 1000)。我们会在内部做锁定原点、扇区映射、状态判定。
    func externalFeed(
        absoluteYaw: Float,
        pitch: Float,
        sharpness: Float = 1000,
        motionScore: Float = 0.2,
        trackingOK: Bool = true
    ) {
        // 先更新 snapshot 的 currentAz/El(给 dome 旋转用)
        let relativeAz = absoluteYaw - coverage.worldYaw
        var snap = snapshot
        snap.currentAzimuth = relativeAz
        snap.currentElevation = pitch
        snap.trackingOK = trackingOK
        snapshot = snap

        guard snapshot.hasLockedOrigin, trackingOK else {
            publishIfDue()
            return
        }

        // 节流 ingest,避免 60FPS 撞爆 cell
        let now = CACurrentMediaTime()
        if now - lastSampledTime < sampleInterval { return }
        lastSampledTime = now

        let sample = CapturedFrameSample(
            timestamp: now,
            azimuth: relativeAz,
            elevation: pitch,
            sharpness: sharpness,
            motionScore: motionScore,
            exposureScore: 0.85,
            frameID: UUID(),
            cameraExtrinsic4x4: nil,     // externalFeed(CoreMotion)路径无 ARKit transform
            cameraIntrinsicFxFyCxCy: nil
        )
        _ = coverage.ingest(sample: sample)
        publishIfDue()
    }

    /// 快捷 lock:把相机当前视线前方 `distanceMeters` 米处当成物体中心,
    /// 适合用户"对准物体按快门"的场景(不依赖 raycast 到平面)。
    @discardableResult
    func lockAtCameraForward(distanceMeters: Float = 0.5) -> Bool {
        guard let frame = session.currentFrame else { return false }
        let t = frame.camera.transform
        let camPos = SIMD3<Float>(t.columns.3.x, t.columns.3.y, t.columns.3.z)
        let forward = -SIMD3<Float>(t.columns.2.x, t.columns.2.y, t.columns.2.z)
        let origin = camPos + simd_normalize(forward) * distanceMeters
        // worldYaw = "相机相对物体的方位角基准"。handleFrame 里 az = atan2(rel.z, rel.x) - worldYaw,
        // 录制开始瞬间 rel = camPos - origin = -forward*d,用这个方向算基准才能让 az 从 0 起步。
        let relInitial = camPos - origin
        let yaw = atan2(relInitial.z, relInitial.x)
        coverage.lockWorldOrigin(origin, yaw: yaw)
        // 锁定 reference camera-up:后续每帧 handleFrame 用它算"相对锁定瞬间"
        // 的倾斜角,超 maxTiltDegrees 就拒帧。column 1 = camera's world-space up。
        referenceCameraUp = simd_normalize(SIMD3<Float>(t.columns.1.x, t.columns.1.y, t.columns.1.z))
        var snap = snapshot
        snap.hasLockedOrigin = true
        snap.hintText = "围绕物体慢走一圈,每个扇区深绿代表拍够了。"
        snapshot = snap
        return true
    }

    // NOTE: `lockObjectCenter(at:in:)` + its helper `unprojectDirection`
    // were removed on 2026-04-24. Historical context: they let a user tap
    // the screen to pick the object's center manually. In practice
    // `lockAtCameraForward` auto-runs at startRecording() (see
    // ObjectModeV2CaptureViewModel.swift start-recording path), so no UI
    // ever drove the manual tap. The function + its 20-line raycast
    // helper were pure dead code. Grep -r for either name before
    // resurrecting them.

    // MARK: - Private helpers

    private func publishIfDue(force: Bool = false) {
        let now = CACurrentMediaTime()
        if !force && now - lastPublishTime < publishInterval { return }
        lastPublishTime = now

        let counts = coverage.cellCounts()
        var snap = snapshot
        snap.validFrames = coverage.validFrameCount
        snap.excellentCells = counts.excellent
        snap.okCells = counts.ok
        snap.currentCellState = coverage.currentCellState
        // azimuth/elevation 在 didUpdate 里更新
        snap.hintText = resolveHint(snap: snap)
        snapshot = snap
    }

    private func resolveHint(snap: ObjectModeV2DomeSnapshot) -> String {
        if !snap.hasLockedOrigin { return "把物体放在画面中心,点一下开始。" }
        if !snap.trackingOK { return "追踪丢失,重新对准物体中心。" }
        if snap.excellentCells >= 8 { return "覆盖充分,随时可以结束。" }
        if snap.excellentCells >= 3 { return "继续补其他方位,每个扇区 4 张以上才变深绿。" }
        return "绕物体慢走,保持距离稳定,拍满第一圈。"
    }
}

// MARK: - ARSessionDelegate

extension ObjectModeV2ARDomeCoordinator: ARSessionDelegate {

    nonisolated func session(_ session: ARSession, didUpdate frame: ARFrame) {
        // 消费 frame 的旁路 hook(video writer 等)—— 先分发,再释放让 VIO 继续。
        onARFrame?(frame)

        // 新管线广播 —— 把当前帧拷成 CaptureFrame 送入 actor-isolated
        // CaptureSession。QualityAnalysisObserver 会在 10Hz 节流后算
        // Laplacian variance 并填 snapshot.lastQualityReport;本 Coordinator
        // 的 handleFrame 再从同一 snapshot 读。不 retain ARFrame。
        if let target = captureSession {
            let captureFrame = CaptureFrame(
                timestamp: frame.timestamp,
                cameraTransform: frame.camera.transform,
                cameraIntrinsics: frame.camera.intrinsics,
                trackingOK: (frame.camera.trackingState == .normal),
                pixelBuffer: frame.capturedImage
            )
            Task { await target.ingest(frame: captureFrame) }
        }

        // ⚠️ 高频,别阻塞主线程。先把 pose + pixelbuffer 拿出来,释放 ARFrame。
        let trackingNormal: Bool
        switch frame.camera.trackingState {
        case .normal: trackingNormal = true
        default: trackingNormal = false
        }
        let camTransform = frame.camera.transform
        let camIntrinsics = frame.camera.intrinsics
        let timestamp = frame.timestamp
        // 取弱引用,避免延长 ARFrame 生命周期
        let pixelBuffer = frame.capturedImage

        Task { @MainActor [weak self] in
            guard let self else { return }
            await self.handleFrame(
                transform: camTransform,
                intrinsics: camIntrinsics,
                timestamp: timestamp,
                trackingNormal: trackingNormal,
                pixelBuffer: pixelBuffer
            )
        }
    }

    nonisolated func session(_ session: ARSession, didFailWithError error: Error) {
        Task { @MainActor [weak self] in
            var snap = self?.snapshot ?? .init()
            snap.trackingOK = false
            snap.hintText = "AR 会话异常,请重开扫描。"
            self?.snapshot = snap
        }
    }
}

// MARK: - Per-frame processing

@MainActor
private extension ObjectModeV2ARDomeCoordinator {

    func handleFrame(
        transform: simd_float4x4,
        intrinsics: simd_float3x3,
        timestamp: TimeInterval,
        trackingNormal: Bool,
        pixelBuffer: CVPixelBuffer
    ) async {
        // 更新 tracking 状态 + dome yaw/pitch(即使未锁定也可以先转球)
        if let origin = coverage.worldOrigin {
            let camPos = SIMD3<Float>(transform.columns.3.x, transform.columns.3.y, transform.columns.3.z)
            let rel = camPos - origin
            let horizDist = sqrt(rel.x * rel.x + rel.z * rel.z)
            let az = atan2(rel.z, rel.x) - coverage.worldYaw
            let el = atan2(rel.y, max(horizDist, 0.001))
            var snap = snapshot
            snap.currentAzimuth = az
            snap.currentElevation = el
            snap.trackingOK = trackingNormal
            snapshot = snap
        } else {
            var snap = snapshot
            snap.trackingOK = trackingNormal
            snapshot = snap
        }

        // 采样节流 —— 每 1/6 秒才算一次 sharpness 并入 coverage。
        // 30 FPS 的 ARFrame 跟屏 dome,但 coverage 只吃 6 FPS 的 event。
        if timestamp - lastSampledTime < sampleInterval { return }
        lastSampledTime = timestamp

        guard let origin = coverage.worldOrigin, trackingNormal else {
            publishIfDue()
            return
        }

        // 计算姿态
        let camPos = SIMD3<Float>(transform.columns.3.x, transform.columns.3.y, transform.columns.3.z)
        let rel = camPos - origin
        let horizDist = sqrt(rel.x * rel.x + rel.z * rel.z)
        let az = atan2(rel.z, rel.x) - coverage.worldYaw
        let el = atan2(rel.y, max(horizDist, 0.001))

        // 真 Laplacian 现在来自新管线的 QualityAnalysisObserver(见
        // `captureSession` 字段的文档)。若 observer 尚未报出值(session 刚启动、
        // observer 没注册、或者帧太新还没轮到分析),回退到 1000 保留原有
        // 行为(>minSharpness=500 即被接受)。
        let ts = timestamp
        _ = pixelBuffer
        // 把 transform 和 intrinsics 展平成 [Float] 带进 sample,
        // 让 curateForUpload 之后能直接序列化进 curated.json 的 arkit_extrinsic_4x4 字段。
        let extrinsicFlat: [Float] = [
            transform.columns.0.x, transform.columns.0.y, transform.columns.0.z, transform.columns.0.w,
            transform.columns.1.x, transform.columns.1.y, transform.columns.1.z, transform.columns.1.w,
            transform.columns.2.x, transform.columns.2.y, transform.columns.2.z, transform.columns.2.w,
            transform.columns.3.x, transform.columns.3.y, transform.columns.3.z, transform.columns.3.w,
        ]
        let intrinsicFxFyCxCy: [Float] = [
            intrinsics.columns.0.x,   // fx
            intrinsics.columns.1.y,   // fy
            intrinsics.columns.2.x,   // cx
            intrinsics.columns.2.y,   // cy
        ]
        Task { @MainActor [weak self] in
            guard let self else { return }

            // 从 CaptureSession 的 snapshot 读最新的图像质量报告 + 运动状态。
            // QualityAnalysisObserver 在 10Hz 跑,dome 在 6Hz 跑,所以这里总能
            // 拿到 <=100ms 旧的 report,对 sharpness 门槛用是足够新的。
            // CaptureSession.snapshot 是 actor-isolated,一次 await 拿全。
            let snap = await self.captureSession?.snapshot
            let quality = snap?.lastQualityReport
            let angularVelocity = snap?.currentAngularVelocity ?? 0

            // ───── 角速度硬门槛 ─────
            // > 2.0 rad/s 时手机正在快速旋转:rolling-shutter 画面会歪,
            // ARKit VIO 的 yaw drift 也会被放大。variance 层抓不到这种
            // "局部清晰但几何错位"的帧 -> 必须用陀螺仪独立拒绝。
            //
            // 阈值 2.0 来源:手持缓慢环绕物体的典型值 0.3-0.8 rad/s;
            // 不小心晃一下 ~2.5 rad/s 起;故意甩手 5+ rad/s。
            //
            // 2.0 给手抖留了很大容差,只拦"明显在快速转"的情况。
            let angularVelocityLimit: Float = 2.0
            if angularVelocity > angularVelocityLimit {
                // 拒帧 —— 仍然 publishIfDue(),让 UI 更新 tracking/pose
                // 但不 ingest 到 coverage,不点亮 cell。
                self.publishIfDue()
                return
            }

            // ───── 倾斜硬门槛 ─────
            // 把当前 camera-up 和锁定瞬间的 camera-up 夹角算成度数。
            // 夹角大 = 用户扭手机旋转了。这个帧虽然可能清晰,但:
            //   1. 物体边缘会一直落在 lens corner(畸变+暗角最严重区域)
            //   2. ARKit VIO 的 yaw drift 在 off-axis 姿态下放大
            //   3. 连续倾斜导致 3DGS 训练时某些 Gaussian 缺乏 "中心区约束"
            //      -> 重建边界糊
            //
            // 用户说: "保证覆盖质量是底线。做 C" -> 拒帧。
            let currentCamUp = simd_normalize(SIMD3<Float>(
                transform.columns.1.x,
                transform.columns.1.y,
                transform.columns.1.z
            ))
            let tiltDegrees: Float
            if let refUp = self.referenceCameraUp {
                // dot(a,b) = |a||b|cos(θ);两个 unit vector 下 dot = cos(θ)
                let cosine = simd_clamp(simd_dot(refUp, currentCamUp), -1.0, 1.0)
                tiltDegrees = acos(cosine) * 180.0 / .pi
            } else {
                // 没锁定参考 -> 不做倾斜判定(本来 handleFrame 上面 guard
                // origin 就会把这条 path return 掉)。
                tiltDegrees = 0
            }

            // ───── 绝对重力门槛(second-layer sanity) ─────
            // Tilt gate 相对 lock 时姿态,如果 lock 时已经斜了就被它骗过;
            // 这里用世界重力(ARKit worldAlignment = .gravity ⇒ world +Y 就是
            // 重力反向)算一次绝对偏差:camera-up 离 portrait (0°) 和 landscape
            // (90°) 哪个最近,偏差 > 15° 就拒。
            //
            // 这样:
            //   * lock 时再怎么斜,gravity gate 每帧独立判断,把"明显不合理
            //     姿态"兜底拒掉,不依赖 lock 正确性。
            //   * portrait / landscape 都算正常 → 不把 横拍 误伤。
            //   * 纯对角姿态(45°)离两个 cardinal 都是 45° → 果断拒绝。
            let worldUp = SIMD3<Float>(0, 1, 0)
            let gravityAngleRad = acos(simd_clamp(simd_dot(currentCamUp, worldUp), -1.0, 1.0))
            let gravityAngleDeg = gravityAngleRad * 180.0 / .pi
            let devPortrait = abs(gravityAngleDeg - 0.0)
            let devLandscape = abs(gravityAngleDeg - 90.0)
            let gravityDeviation = min(devPortrait, devLandscape)

            // Publish both tilt + gravity deviation to snapshot so the HUD
            // can render live values regardless of accept/reject.
            if let target = self.captureSession {
                let tilt = tiltDegrees
                let gravDev = gravityDeviation
                Task { [target, tilt, gravDev] in
                    await target.mutateSnapshot { snap in
                        snap.currentTiltDegrees = tilt
                        snap.currentGravityDeviationDegrees = gravDev
                    }
                }
            }

            if tiltDegrees > self.maxTiltDegrees {
                self.publishIfDue()
                return
            }

            if gravityDeviation > self.maxGravityDeviationDegrees {
                self.publishIfDue()
                return
            }

            let sharpness: Float
            let exposure: Float
            if let q = quality {
                sharpness = Float(q.laplacianVariance)
                // meanBrightness 0..255 -> exposureScore 0..1
                exposure = Float(min(1.0, max(0.0, q.meanBrightness / 255.0)))
            } else {
                // observer 还没报第一帧 -> 退回旧 hardcode 行为,不阻塞首帧 accept。
                sharpness = 1000
                exposure = 0.85
            }

            let sample = CapturedFrameSample(
                timestamp: ts,
                azimuth: az,
                elevation: el,
                sharpness: sharpness,
                motionScore: self.motionBlurScore(),
                exposureScore: exposure,
                frameID: UUID(),
                cameraExtrinsic4x4: extrinsicFlat,
                cameraIntrinsicFxFyCxCy: intrinsicFxFyCxCy
            )
            let result = self.coverage.ingest(sample: sample)
            if result != nil {
                // ingest 成功(非 nil 表示命中 cell),报告时间戳给 VM 补 manifest。
                self.onValidSampleTimestamp?(ts)
            }
            self.publishIfDue()
        }
    }

    /// Accelerate 版 Laplacian variance(grayscale),~2 ms/1080p。
    nonisolated func computeLaplacianVariance(pixelBuffer: CVPixelBuffer) -> Float {
        CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly) }

        let w = CVPixelBufferGetWidthOfPlane(pixelBuffer, 0)
        let h = CVPixelBufferGetHeightOfPlane(pixelBuffer, 0)
        guard let baseAddr = CVPixelBufferGetBaseAddressOfPlane(pixelBuffer, 0) else { return 0 }
        let stride = CVPixelBufferGetBytesPerRowOfPlane(pixelBuffer, 0)

        // 子采样:每 4 像素取 1,够算边缘密度了,省 16x 计算
        let stepX = 4, stepY = 4
        var sum: Float = 0
        var sumSq: Float = 0
        var count: Int = 0
        let ptr = baseAddr.assumingMemoryBound(to: UInt8.self)

        var y = stepY
        while y < h - stepY {
            var x = stepX
            while x < w - stepX {
                let c = Int(ptr[y * stride + x])
                let up = Int(ptr[(y - 1) * stride + x])
                let down = Int(ptr[(y + 1) * stride + x])
                let left = Int(ptr[y * stride + (x - 1)])
                let right = Int(ptr[y * stride + (x + 1)])
                let lap = Float(-4 * c + up + down + left + right)
                sum += lap
                sumSq += lap * lap
                count += 1
                x += stepX
            }
            y += stepY
        }
        if count == 0 { return 0 }
        let mean = sum / Float(count)
        let variance = sumSq / Float(count) - mean * mean
        return max(0, variance)
    }

    /// 简化 motion score:看 gyroscope 的瞬时模(不取 IMU 直接用 CMMotion 传入)。
    /// 首版先返回固定低值;接入后用现有 GuidanceEngine 的 rotationRate。
    func motionBlurScore() -> Float {
        // 占位:返回 0.15(假设稳),有真实 IMU 后替换
        return 0.15
    }
}

// MARK: - SwiftUI-friendly dome view mount

/// 把 UIKit 的 DomeView 包成 SwiftUI 可用组件。
/// 接受一个 coordinator,自动订阅 snapshot → 更新 dome。
struct ObjectModeV2DomeContainerView: UIViewRepresentable {
    @ObservedObject var coordinator: ObjectModeV2ARDomeCoordinator
    var onTap: () -> Void

    func makeUIView(context: Context) -> ObjectModeV2DomeView {
        let v = ObjectModeV2DomeView(frame: .zero)
        v.onTap = onTap
        // 初始同步 cell 状态
        for a in 0..<DomeCellIndex.azimuthCount {
            for e in 0..<DomeCellIndex.elevationCount {
                v.updateCell(DomeCellIndex(az: a, el: e), state: .empty)
            }
        }
        context.coordinator.wire(view: v, coordinator: coordinator)
        return v
    }

    func updateUIView(_ uiView: ObjectModeV2DomeView, context: Context) {
        let snap = coordinator.snapshot
        // UI 坐标约定修正(让用户当前 cell 精确落在 dome 中心 = SceneKit +Z 方向):
        //   yaw:   球公式 a=0 在 SceneKit +X(屏幕右),-π/2 把 a=0 转到 +Z(屏幕中心)。
        //   pitch: yaw 后 cell 在 (0, sin(el), cos(el))。想把它转到 (0, 0, 1),
        //          需绕 X 轴正向转 el(推导:sin(el-θ)=0 → θ=el)。所以 pitch = +el。
        //          DomeView 内部的 pitchScale 应为 1.0 才能让对齐精确到 0 偏移。
        uiView.updateRotation(targetYaw: snap.currentAzimuth - .pi / 2,
                              targetPitch: snap.currentElevation)
        uiView.setCenterIndicator(snap.currentCellState)
        uiView.setTrackingFrozen(!snap.trackingOK)
        uiView.setHUD("\(snap.validFrames) 帧 · \(snap.excellentCells) 深绿")
        uiView.onTap = onTap
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator {
        private var cancellables = Set<AnyCancellable>()

        @MainActor
        func wire(view: ObjectModeV2DomeView, coordinator: ObjectModeV2ARDomeCoordinator) {
            // 监听 cell 状态变化 → 直接改 dome 对应 cell 颜色(不触发 SwiftUI 刷新)
            coordinator.coverage.onCellStateChanged = { [weak view] index, state in
                view?.updateCell(index, state: state)
            }
        }
    }
}

#endif
