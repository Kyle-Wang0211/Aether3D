import Foundation

#if canImport(SwiftUI) && canImport(UIKit) && canImport(ARKit)
import SwiftUI
import UIKit
import ARKit

/// 显示 ARKit session 捕获的相机画面。替换老的 AVCaptureVideoPreviewLayer 方案,
/// 使 dome 的 6DoF 姿态与相机画面来自同一个 ARSession。
struct ObjectModeV2ARKitPreview: UIViewRepresentable {
    let session: ARSession
    let bridge: ObjectModeV2PreviewBridge

    func makeUIView(context: Context) -> ARSCNView {
        let v = ARSCNView(frame: .zero)
        v.session = session
        v.automaticallyUpdatesLighting = true
        v.scene = SCNScene()           // 空 scene,只用它展示 camera feed
        v.rendersContinuously = true   // 让 ARSCNView 持续刷新 camera background
        v.antialiasingMode = .none     // preview 层不抗锯齿,省电
        // 触发 VM 的 hasPreviewAttached 流程 —— prepareCameraIfNeeded 才会被调用,
        // recorder.prepare() 才会 session.run(config)。不触发这个 callback 屏幕就永远黑。
        DispatchQueue.main.async { [bridge] in
            bridge.onPreviewAttached?()
        }
        return v
    }

    func updateUIView(_ uiView: ARSCNView, context: Context) {
        if uiView.session !== session {
            uiView.session = session
        }
    }
}

// NOTE: external mode 下本文件不会被实际挂载;如果将来切回 ARKit preview,
// 需要在 ObjectModeV2CameraPreview 里加 arSnapshotProvider 属性 + 在此 extension
// 里重新接上 ARSCNView.snapshot()。

#endif
