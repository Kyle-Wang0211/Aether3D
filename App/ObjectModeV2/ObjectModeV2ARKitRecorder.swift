import Foundation

#if canImport(UIKit) && canImport(ARKit) && canImport(simd)
import UIKit
import ARKit
import CoreImage
import ImageIO
import MobileCoreServices
import UniformTypeIdentifiers
import simd

/// ARKit 路线下的 Recorder:不写 .mov,而是把每一"有效帧"存成 JPEG + pose。
/// 产出一个目录 `ObjectModeV2Captures/<uuid>/` 内容:
///   frames/000123.jpg
///   manifest.json   (帧列表 + 每帧 extrinsic/intrinsic)
/// 和现有 CaptureRecorder(AVCapture/.mov)独立存在,由 ViewModel 选择挂哪一个。
///
/// 性能设计:
///   - 主线程 onValidFrame 收到 CVPixelBuffer 后**立即**复制一份 CIImage(避免 ARKit 回收)
///   - JPEG 编码在 background queue,30ms/帧(~33 fps 极限,我们采样 6 fps 所以很稳)
///   - 空间估算:每帧 1920x1080 JPEG q=0.8 约 400-700 KB;50 帧 = 25-35 MB,一次扫描没压力
///   - manifest 用原子写,每 10 帧刷一次盘(断电回滚最多丢 10 帧元数据)
@MainActor
final class ObjectModeV2ARKitRecorder: ObservableObject {

    @Published private(set) var isRecording = false
    @Published private(set) var acceptedFrameCount = 0

    struct RecordedFrame: Codable, Sendable {
        let id: String
        let filename: String        // 相对 frames/ 的文件名
        let timestamp: TimeInterval
        let azimuth: Float
        let elevation: Float
        /// camera→world 变换矩阵(row-major,16 floats)
        let cameraTransform: [Float]
        /// 相机内参 fx, fy, cx, cy
        let intrinsics: [Float]
    }

    struct RecordingManifest: Codable, Sendable {
        var captureVersion: Int = 2
        var createdAt: Date = Date()
        var framesDir: String = "frames"
        var frames: [RecordedFrame] = []
    }

    // MARK: - State
    private var sessionDir: URL?
    private var framesDir: URL?
    private var manifest: RecordingManifest = .init()
    private let jpegQueue = DispatchQueue(label: "aether3d.recorder.jpeg", qos: .userInitiated)
    private let ciContext = CIContext(options: [.useSoftwareRenderer: false])
    private var pendingWrites = 0

    // MARK: - API

    func startRecording() throws {
        guard !isRecording else { return }
        let base = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("ObjectModeV2Captures", isDirectory: true)
        let sid = UUID().uuidString.lowercased()
        let sess = base.appendingPathComponent(sid, isDirectory: true)
        let frames = sess.appendingPathComponent("frames", isDirectory: true)
        try FileManager.default.createDirectory(at: frames, withIntermediateDirectories: true)
        self.sessionDir = sess
        self.framesDir = frames
        self.manifest = .init()
        self.acceptedFrameCount = 0
        self.isRecording = true
    }

    func stopRecording() async throws -> URL {
        guard isRecording, let sess = sessionDir else {
            throw NSError(domain: "ObjectModeV2ARKitRecorder", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "not recording"])
        }
        // 等待 pending JPEG 写完
        await withCheckedContinuation { cont in
            jpegQueue.async { cont.resume() }
        }
        try flushManifest()
        isRecording = false
        return sess
    }

    /// 协调器(ObjectModeV2ARDomeCoordinator)检测到一个有效帧时调用。
    /// frameID 由 coordinator 指派,我们只是把图写到 frames/frameID.jpg。
    func ingestValidFrame(
        frameID: UUID,
        pixelBuffer: CVPixelBuffer,
        cameraTransform: simd_float4x4,
        intrinsics: simd_float3x3,
        azimuth: Float,
        elevation: Float,
        timestamp: TimeInterval
    ) {
        guard isRecording, let framesDir else { return }

        // 先把 CVPixelBuffer 转成 CIImage 再入队,避免 buffer 被 ARKit 回收
        let ci = CIImage(cvPixelBuffer: pixelBuffer)
        let filename = "\(frameID.uuidString.lowercased()).jpg"
        let destURL = framesDir.appendingPathComponent(filename)

        // 立刻记元数据(顺序性不重要,JSON 里按 timestamp 排)
        let record = RecordedFrame(
            id: frameID.uuidString.lowercased(),
            filename: filename,
            timestamp: timestamp,
            azimuth: azimuth,
            elevation: elevation,
            cameraTransform: Self.flatten(cameraTransform),
            intrinsics: [intrinsics[0,0], intrinsics[1,1], intrinsics[2,0], intrinsics[2,1]]
        )
        manifest.frames.append(record)
        acceptedFrameCount += 1
        pendingWrites += 1
        if manifest.frames.count % 10 == 0 {
            try? flushManifest()
        }

        // JPEG 编码异步写盘
        jpegQueue.async { [ctx = ciContext] in
            let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)
            let options: [CIImageRepresentationOption: Any] = [
                .init(rawValue: kCGImageDestinationLossyCompressionQuality as String): 0.8 as Any
            ]
            try? ctx.writeJPEGRepresentation(
                of: ci,
                to: destURL,
                colorSpace: colorSpace ?? CGColorSpaceCreateDeviceRGB(),
                options: options
            )
        }
    }

    // MARK: - Helpers

    private func flushManifest() throws {
        guard let sess = sessionDir else { return }
        let data = try JSONEncoder.pretty.encode(manifest)
        let url = sess.appendingPathComponent("manifest.json")
        let tmp = url.appendingPathExtension("tmp")
        try data.write(to: tmp)
        _ = try? FileManager.default.replaceItemAt(url, withItemAt: tmp)
    }

    private static func flatten(_ m: simd_float4x4) -> [Float] {
        [m.columns.0.x, m.columns.0.y, m.columns.0.z, m.columns.0.w,
         m.columns.1.x, m.columns.1.y, m.columns.1.z, m.columns.1.w,
         m.columns.2.x, m.columns.2.y, m.columns.2.z, m.columns.2.w,
         m.columns.3.x, m.columns.3.y, m.columns.3.z, m.columns.3.w]
    }
}

private extension JSONEncoder {
    static var pretty: JSONEncoder {
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        e.dateEncodingStrategy = .iso8601
        return e
    }
}

#endif
