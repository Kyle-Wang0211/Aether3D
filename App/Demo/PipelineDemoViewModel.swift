// SPDX-License-Identifier: LicenseRef-Aether3D-Proprietary
// Copyright (c) 2024-2026 Aether3D. All rights reserved.

//
//  PipelineDemoViewModel.swift
//  progect2
//
//  Created by Kaidong Wang on 12/18/25.
//

import Foundation
import SwiftUI
#if canImport(AVFoundation)
import AVFoundation
#endif
import PhotosUI
import UniformTypeIdentifiers
import Combine

enum UIState {
    case idle
    case generating(progress: Double?)
    case success(artifact: ArtifactRef)
    case failed(reason: String)
}

@MainActor
final class PipelineDemoViewModel: ObservableObject {
    @Published var selectedItem: PhotosPickerItem?
    @Published var selectedURL: URL?
    @Published var selectedFileName: String?
    @Published var isCopyingVideo = false
    @Published var copyingError: String?
    
    @Published var uiState: UIState = .idle
    @Published var isRunning = false
    
    private let pipelineRunner = PipelineRunner()
    private var currentTask: Task<Void, Never>?
    
    /// 选择视频后复制到 sandbox
    func handleVideoSelection(_ item: PhotosPickerItem?) {
        guard let item = item else {
            selectedURL = nil
            selectedFileName = nil
            copyingError = nil
            return
        }
        
        isCopyingVideo = true
        copyingError = nil
        
        Task {
            do {
                guard let data = try await item.loadTransferable(type: Data.self) else {
                    await MainActor.run {
                        copyingError = "Failed to load video data"
                        isCopyingVideo = false
                    }
                    return
                }
                
                let fileExtension = item.supportedContentTypes.first?.preferredFilenameExtension ?? "mov"
                let documentsPath = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
                let targetDir = documentsPath.appendingPathComponent("Phase1-2b", isDirectory: true)
                try FileManager.default.createDirectory(at: targetDir, withIntermediateDirectories: true)
                
                let fileName = "\(UUID().uuidString).\(fileExtension)"
                let targetURL = targetDir.appendingPathComponent(fileName)
                
                try data.write(to: targetURL)
                
                await MainActor.run {
                    selectedURL = targetURL
                    selectedFileName = fileName
                    copyingError = nil
                    isCopyingVideo = false
                }
            } catch {
                await MainActor.run {
                    copyingError = "Copy failed: \(error.localizedDescription)"
                    selectedURL = nil
                    selectedFileName = nil
                    isCopyingVideo = false
                }
            }
        }
    }
    
    /// 运行 Pipeline（Day 2: 只支持 .enter 模式）
    func runPipeline(mode: BuildMode) {
        guard !isRunning, let url = selectedURL else { return }
        
        // Day 2: 只支持 .enter
        guard mode == .enter else {
            uiState = .failed(reason: "Day 2 only supports .enter mode")
            return
        }
        
        uiState = .generating(progress: nil)
        isRunning = true
        
        currentTask = Task {
            #if canImport(AVFoundation)
            let deviceTier = DeviceTier.current()
            let asset = AVAsset(url: url)
            let request = BuildRequest(
                source: .video(asset: asset),
                requestedMode: .enter,
                deviceTier: deviceTier
            )
            
            let result = await pipelineRunner.runGenerate(request: request)
            #else
            // Linux stub: AVFoundation unavailable
            let result: GenerateResult = .fail(reason: .inputInvalid, elapsedMs: 0)
            #endif
            
            await MainActor.run {
                switch result {
                case .success(let artifact, _):
                    uiState = .success(artifact: artifact)
                    
                case .fail(let reason, _):
                    uiState = .failed(reason: reason.rawValue)
                }
                
                isRunning = false
            }
        }
    }
    
    /// 取消 Pipeline
    func cancelPipeline() {
        currentTask?.cancel()
        isRunning = false
        uiState = .failed(reason: "Cancelled")
    }
}
