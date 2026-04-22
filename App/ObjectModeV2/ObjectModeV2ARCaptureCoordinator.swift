import Foundation

#if canImport(ARKit) && canImport(AVFoundation) && canImport(UIKit) && canImport(simd)
import ARKit
@preconcurrency import AVFoundation
import UIKit
import CoreImage
import CoreMedia
import ImageIO
import simd

/// AR 版捕获协调器 — 和 `ObjectModeV2CaptureRecorder` 外部 API 同构,但底层:
///   • 相机 / 姿态 都来自 `ObjectModeV2ARDomeCoordinator` 拥有的 ARSession (6DoF VIO)
///   • 录制靠 AVAssetWriter + ARFrame.capturedImage,产出格式仍是 .mov(下游 pipeline 不用改)
///   • previewSession 返回一个从不 startRunning 的空 AVCaptureSession(仅为保持 VM 兼容)
///   • 画面由 SwiftUI 层用 `ObjectModeV2ARKitPreview` 直接显示 ARSession
///
/// 目标: VM 只需把 `let recorder = ObjectModeV2CaptureRecorder()` 换成本类即可。
/// 录制等 API 的 duration / fileURL / fileSize 行为和旧 recorder 一致。
@MainActor
final class ObjectModeV2ARCaptureCoordinator: NSObject, @unchecked Sendable {

    // MARK: - Public API(对齐 ObjectModeV2CaptureRecorder)

    /// VM 兼容字段 —— 非 nil,但不会 startRunning。View 层使用 ARKit Preview。
    nonisolated let previewSession: AVCaptureSession = AVCaptureSession()

    /// 旧 recorder 的钩子语义:每个被选中的"视觉帧"样本。AR 模式下我们节流到 ~6 Hz 发送。
    var onVisualFrameSample: ((ObjectModeV2VisualFrameSample) -> Void)?

    let domeCoordinator: ObjectModeV2ARDomeCoordinator

    private(set) var isPrepared = false
    /// nonisolated(unsafe):handle(_:) 在 AR delegate 线程里读;main actor 里写。
    /// 读一个 Bool 即使有 race 也只会多写一帧或漏一帧,不影响 writer 正确性。
    nonisolated(unsafe) private(set) var isRecording = false

    // MARK: - 内部状态

    private let writerQueue = DispatchQueue(label: "com.aether3d.objectmodev2.ar.writer", qos: .userInitiated)
    private let ciContext = CIContext(options: [.useSoftwareRenderer: false])
    nonisolated(unsafe) private var writer: AVAssetWriter?
    nonisolated(unsafe) private var writerInput: AVAssetWriterInput?
    nonisolated(unsafe) private var writerAdaptor: AVAssetWriterInputPixelBufferAdaptor?
    nonisolated(unsafe) private var startPTS: CMTime?
    nonisolated(unsafe) private var recordedFrameCount: Int = 0
    nonisolated(unsafe) private var recordingOutputURL: URL?
    nonisolated(unsafe) private var lastVisualSampleTS: TimeInterval = 0
    private let visualSampleInterval: TimeInterval = 1.0 / 6.0

    // MARK: - Init

    init(domeCoordinator: ObjectModeV2ARDomeCoordinator) {
        self.domeCoordinator = domeCoordinator
        super.init()
        domeCoordinator.onARFrame = { [weak self] frame in
            self?.handle(frame)
        }
    }

    // MARK: - recorder API

    func prepare() async throws {
        if isPrepared { return }
        guard ARWorldTrackingConfiguration.isSupported else {
            throw NSError(domain: "ObjectModeV2ARCaptureCoordinator", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "当前设备不支持 ARKit world tracking"])
        }
        domeCoordinator.start()
        isPrepared = true
    }

    func startRecording() throws {
        guard isPrepared else {
            throw NSError(domain: "ObjectModeV2ARCaptureCoordinator", code: 2,
                          userInfo: [NSLocalizedDescriptionKey: "AR 会话尚未就绪"])
        }
        guard !isRecording else { return }

        let url = try makeOutputURL()

        let w = try AVAssetWriter(outputURL: url, fileType: .mov)
        let settings: [String: Any] = [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: 1920,
            AVVideoHeightKey: 1440
        ]
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: settings)
        input.expectsMediaDataInRealTime = true
        // ARKit 默认 portrait —— ARFrame 的 image 是 landscape 右转 90° 输出,这里不做转向,
        // 下游流水线按采集态自己 detect。
        w.add(input)

        let adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: input,
            sourcePixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarFullRange,
                kCVPixelBufferWidthKey as String: 1920,
                kCVPixelBufferHeightKey as String: 1440
            ]
        )

        guard w.startWriting() else {
            throw NSError(domain: "ObjectModeV2ARCaptureCoordinator", code: 3,
                          userInfo: [NSLocalizedDescriptionKey: "AVAssetWriter startWriting 失败: \(w.error?.localizedDescription ?? "未知")"])
        }
        w.startSession(atSourceTime: .zero)

        writer = w
        writerInput = input
        writerAdaptor = adaptor
        startPTS = nil
        recordedFrameCount = 0
        recordingOutputURL = url
        isRecording = true
    }

    func stopRecording() async throws -> ObjectModeV2RecordedClip {
        guard isRecording, let url = recordingOutputURL, let input = writerInput, let w = writer else {
            throw NSError(domain: "ObjectModeV2ARCaptureCoordinator", code: 4,
                          userInfo: [NSLocalizedDescriptionKey: "当前不在录制中"])
        }
        isRecording = false

        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            writerQueue.async {
                input.markAsFinished()
                w.finishWriting {
                    continuation.resume()
                }
            }
        }

        let attrs = try FileManager.default.attributesOfItem(atPath: url.path)
        let size = (attrs[.size] as? NSNumber)?.int64Value ?? 0
        let duration = TimeInterval(recordedFrameCount) / 30.0

        writer = nil
        writerInput = nil
        writerAdaptor = nil
        startPTS = nil
        recordingOutputURL = nil

        return ObjectModeV2RecordedClip(fileURL: url, duration: duration, fileSize: size)
    }

    func shutdown() {
        if isRecording {
            writerInput?.markAsFinished()
            writer?.cancelWriting()
            writer = nil; writerInput = nil; writerAdaptor = nil
            startPTS = nil; recordingOutputURL = nil
            isRecording = false
        }
        domeCoordinator.stop()
        isPrepared = false
    }

    func suspendPreview() {
        // ARKit 的 tracking 是连续的 —— 这里没有"预览暂停"对应物,noop。
    }

    /// VM 在瞬态 thumbnail/ snapshot 调用。从 ARSession 的 latest frame 渲染 UIImage。
    func captureSnapshotImage() -> UIImage? {
        guard let frame = domeCoordinator.session.currentFrame else { return nil }
        let ci = CIImage(cvPixelBuffer: frame.capturedImage)
        let oriented = ci.oriented(.right)   // ARKit capturedImage 是横着的,转正
        guard let cg = ciContext.createCGImage(oriented, from: oriented.extent) else { return nil }
        return UIImage(cgImage: cg, scale: UIScreen.main.scale, orientation: .up)
    }

    // MARK: - Internal

    private func makeOutputURL() throws -> URL {
        let base = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("ObjectModeV2Captures", isDirectory: true)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base.appendingPathComponent("\(UUID().uuidString.lowercased()).mov")
    }

    /// ARSessionDelegate.didUpdate 分发过来,线程:ARKit 自己的 delegate queue。
    nonisolated private func handle(_ frame: ARFrame) {
        // 录像: 无条件把每一帧写入 writer(写是否 drop 由 isReadyForMoreMediaData 决定)
        if isRecording, let adaptor = writerAdaptor, adaptor.assetWriterInput.isReadyForMoreMediaData {
            let now = CMTime(seconds: frame.timestamp, preferredTimescale: 600)
            if startPTS == nil { startPTS = now }
            let pts = CMTimeSubtract(now, startPTS ?? now)
            _ = adaptor.append(frame.capturedImage, withPresentationTime: pts)
            recordedFrameCount += 1
        }

        // onVisualFrameSample 在 AR 路径下故意不喂 —— 老 GuidanceEngine 的
        // "acceptedFrames" 统计由新球的 DomeCoverageMap 取代。如果将来想把两者
        // 打通,可在这里做 Laplacian variance + signature 生成后喂回 sample。
        _ = lastVisualSampleTS
        _ = visualSampleInterval
    }
}

#endif
