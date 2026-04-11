import Foundation

#if canImport(SwiftUI) && canImport(UIKit) && canImport(AVFoundation)
import SwiftUI
import UIKit
@preconcurrency import AVFoundation

@MainActor
final class ObjectModeV2PreviewBridge: ObservableObject {
    weak var previewView: PreviewView?
    var onPreviewAttached: (() -> Void)?
    var onSessionBound: (() -> Void)?
    private var hasNotifiedPreviewAttachment = false
    private var hasNotifiedSessionBinding = false

    func attach(_ previewView: PreviewView) {
        self.previewView = previewView
    }

    func captureSnapshotImage() -> UIImage? {
        previewView?.snapshotImage()
    }

    func notifyPreviewAttached() {
        guard !hasNotifiedPreviewAttachment else { return }
        hasNotifiedPreviewAttachment = true
        onPreviewAttached?()
    }

    func notifySessionBound(session: AVCaptureSession?) {
        guard session != nil else { return }
        guard !hasNotifiedSessionBinding else { return }
        hasNotifiedSessionBinding = true
        onSessionBound?()
    }
}

struct ObjectModeV2CameraPreview: UIViewRepresentable {
    let session: AVCaptureSession?
    let bridge: ObjectModeV2PreviewBridge

    func makeUIView(context: Context) -> PreviewView {
        let view = PreviewView()
        view.previewLayer.videoGravity = .resizeAspectFill
        view.previewLayer.session = session
        bridge.notifySessionBound(session: session)
        view.onAttachedToWindow = { [weak bridge] in
            bridge?.notifyPreviewAttached()
        }
        bridge.attach(view)
        return view
    }

    func updateUIView(_ uiView: PreviewView, context: Context) {
        if uiView.previewLayer.session !== session {
            uiView.previewLayer.session = session
            bridge.notifySessionBound(session: session)
        }
        uiView.onAttachedToWindow = { [weak bridge] in
            bridge?.notifyPreviewAttached()
        }
        bridge.attach(uiView)
    }
}

final class PreviewView: UIView {
    var onAttachedToWindow: (() -> Void)?

    override class var layerClass: AnyClass {
        AVCaptureVideoPreviewLayer.self
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        guard window != nil else { return }
        onAttachedToWindow?()
    }

    var previewLayer: AVCaptureVideoPreviewLayer {
        layer as! AVCaptureVideoPreviewLayer
    }

    func snapshotImage() -> UIImage? {
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = UIScreen.main.scale
        let renderer = UIGraphicsImageRenderer(bounds: bounds, format: format)
        return renderer.image { _ in
            drawHierarchy(in: bounds, afterScreenUpdates: false)
        }
    }
}

#endif
