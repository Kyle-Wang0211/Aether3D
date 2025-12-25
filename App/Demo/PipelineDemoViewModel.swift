//
//  PipelineDemoViewModel.swift
//  progect2
//
//  Created by Kaidong Wang on 12/18/25.
//

import Foundation
import SwiftUI
import AVFoundation
import PhotosUI
import UniformTypeIdentifiers
import Combine

@MainActor
final class PipelineDemoViewModel: ObservableObject {
    @Published var selectedItem: PhotosPickerItem?
    @Published var selectedURL: URL?
    @Published var selectedFileName: String?
    @Published var isCopyingVideo = false
    @Published var copyingError: String?
    
    @Published var pipelineState: PipelineState = .idle
    @Published var planSummary: String = ""
    @Published var resultFrames: [Frame] = []
    @Published var errorText: String?
    
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
    
    /// 运行 Pipeline（Enter 或 Publish 模式）
    func runPipeline(mode: BuildMode) {
        guard !isRunning, let url = selectedURL else { return }
        
        resultFrames = []
        planSummary = ""
        errorText = nil
        
        isRunning = true
        pipelineState = .idle
        
        currentTask = Task {
            let deviceTier = DeviceTier.current()
            let asset = AVAsset(url: url)
            let request = BuildRequest(
                source: .video(asset: asset),
                requestedMode: mode,
                deviceTier: deviceTier
            )
            
            let result = await pipelineRunner.run(request: request) { [weak self] state in
                Task { @MainActor in
                    self?.pipelineState = state
                }
            }
            
            await MainActor.run {
                switch result {
                case .success(let buildResult):
                    if !buildResult.planSummary.isEmpty {
                        planSummary = buildResult.planSummary
                    } else if let lastPlan = pipelineRunner.lastPlan {
                        planSummary = lastPlan.debugSummary
                    } else {
                        planSummary = "⚠️ No plan summary available (Phase 1-2b limitation)"
                    }
                    
                    resultFrames = Array(buildResult.artifact.frames.prefix(6))
                    errorText = nil
                    
                case .failure(let error):
                    errorText = "Error: \(error)"
                    if case .cancelled = error {
                        pipelineState = .failed(message: "Cancelled")
                    }
                }
                
                isRunning = false
            }
        }
    }
    
    /// 取消 Pipeline
    func cancelPipeline() {
        currentTask?.cancel()
        pipelineRunner.cancel()
        isRunning = false
        pipelineState = .failed(message: "Cancelled")
        errorText = "Cancelled"
    }
}

