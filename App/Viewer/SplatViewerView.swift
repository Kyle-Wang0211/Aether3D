//
// SplatViewerView.swift
// Aether3D
//
// Post-scan 3D Gaussian Splatting viewer.
// Pure black background with orbit camera (pan/pinch gestures).
// Wraps GaussianSplatViewController via UIViewControllerRepresentable.
// Apple-platform only (SwiftUI + Metal + UIKit)
//

import Foundation

#if canImport(SwiftUI) && canImport(UIKit) && canImport(Metal)
import SwiftUI

/// Post-scan 3D viewer: renders Gaussian splats on a black background.
///
/// Features:
///   - Orbit camera: pan to rotate, pinch to zoom
///   - Loads exported PLY from ScanRecord.artifactPath
///   - HUD: close button, share button, loading indicator, scan info
///
/// Uses GaussianSplatViewController internally (MTKView + Metal rendering).
struct SplatViewerView: View {
    let record: ScanRecord
    var scanViewModel: ScanViewModel? = nil
    var homeViewModel: HomeViewModel? = nil
    var onReturnHome: (() -> Void)? = nil
    @Environment(\.dismiss) private var dismiss
    @State private var isLoading = true

    var body: some View {
        ZStack {
            // Pure black background
            Color.black.ignoresSafeArea()

            // Metal 3DGS rendering view (when trained model exists)
            if let url = resolvedArtifactURL() {
                let _ = NSLog("[Aether3D] SplatViewerView: loading PLY from %@", url.path)
                SplatViewerRepresentable(
                    artifactURL: url,
                    onLoaded: { isLoading = false }
                )
                .ignoresSafeArea()
            } else {
                // No trained model yet — show scan completion summary
                let _ = NSLog("[Aether3D] SplatViewerView: NO artifact! artifactPath=%@",
                              record.artifactPath ?? "nil")
                VStack(spacing: 24) {
                    Image(systemName: "cube.transparent")
                        .font(.system(size: 64))
                        .foregroundColor(.white.opacity(0.3))

                    Text("扫描已完成")
                        .font(.system(size: 24, weight: .semibold))
                        .foregroundColor(.white)

                    VStack(spacing: 8) {
                        Text("时长: \(formatDuration(record.durationSeconds))")
                            .font(.system(size: 16))
                            .foregroundColor(.white.opacity(0.6))
                    }

                    Text("3D 模型训练将在后台继续")
                        .font(.system(size: 14))
                        .foregroundColor(.white.opacity(0.4))
                        .padding(.top, 8)
                }
                .onAppear { isLoading = false }
            }

            // HUD overlay
            VStack {
                // Top bar: close + share
                HStack {
                    Button(action: { closeExperience() }) {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 28))
                            .foregroundColor(.white)
                            .shadow(radius: 2)
                    }
                    .accessibilityLabel("关闭")
                    .padding(.leading, 16)

                    Spacer()

                    if let url = resolvedArtifactURL() {
                        ShareLink(
                            item: url,
                            subject: Text(record.name),
                            message: Text("Aether3D 扫描")
                        ) {
                            Image(systemName: "square.and.arrow.up.circle.fill")
                                .font(.system(size: 28))
                                .foregroundColor(.white)
                                .shadow(radius: 2)
                        }
                        .padding(.trailing, 16)
                    }
                }
                .padding(.top, 8)

                Spacer()

                // Loading indicator (centered, only when loading 3DGS model)
                if isLoading, resolvedArtifactURL() != nil {
                    VStack(spacing: 8) {
                        ProgressView()
                            .tint(.white)
                        Text("渲染中...")
                            .font(.system(size: 14))
                            .foregroundColor(.gray)
                    }
                }

                Spacer()

                // Bottom bar: scan info
                HStack {
                    Text(record.name)
                        .font(.system(size: 14, weight: .medium))
                        .foregroundColor(.white.opacity(0.7))
                    Spacer()
                    Text(formatDuration(record.durationSeconds))
                        .font(.system(size: 12))
                        .foregroundColor(.white.opacity(0.5))
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 16)
            }
        }
        .navigationBarHidden(true)
        .statusBarHidden(true)
    }

    private func formatDuration(_ seconds: TimeInterval) -> String {
        let m = Int(seconds) / 60
        let s = Int(seconds) % 60
        return String(format: "%02d:%02d", m, s)
    }

    // MARK: - Helpers

    private func resolvedArtifactURL() -> URL? {
        guard let relativePath = record.artifactPath else { return nil }
        let documents = FileManager.default.urls(
            for: .documentDirectory, in: .userDomainMask)[0]
        return documents
            .appendingPathComponent("Aether3D")
            .appendingPathComponent(relativePath)
    }

    private func closeExperience() {
        if let onReturnHome {
            onReturnHome()
        } else {
            dismiss()
        }
    }
}

// MARK: - UIViewControllerRepresentable wrapper

/// Wraps GaussianSplatViewController for use in SwiftUI.
/// Configures the file URL and handles lifecycle.
struct SplatViewerRepresentable: UIViewControllerRepresentable {
    let artifactURL: URL
    var onLoaded: (() -> Void)?

    func makeUIViewController(context: Context) -> GaussianSplatViewController {
        let vc = GaussianSplatViewController()
        vc.fileURL = artifactURL
        return vc
    }

    func updateUIViewController(_ uiViewController: GaussianSplatViewController, context: Context) {
        // GaussianSplatViewController loads fileURL in viewDidLoad automatically.
        // Notify loading complete after first draw cycle.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            onLoaded?()
        }
    }
}

#endif
