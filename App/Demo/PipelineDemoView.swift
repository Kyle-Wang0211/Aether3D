// SPDX-License-Identifier: LicenseRef-Aether3D-Proprietary
// Copyright (c) 2024-2026 Aether3D. All rights reserved.

//
//  PipelineDemoView.swift
//  progect2
//
//  Created by Kaidong Wang on 12/18/25.
//

import SwiftUI
import PhotosUI
import UniformTypeIdentifiers

struct PipelineDemoView: View {
    @StateObject private var viewModel = PipelineDemoViewModel()
    
    var body: some View {
        NavigationView {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    // 视频选择区域
                    videoSelectionSection
                    
                    // 运行按钮区域
                    runButtonsSection
                    
                    // 状态显示区域
                    stateSection
                }
                .padding()
            }
            .navigationTitle("Whitebox Demo (Day 2)")
        }
        .onChange(of: viewModel.selectedItem) { newItem in
            viewModel.handleVideoSelection(newItem)
        }
    }
    
    // MARK: - Video Selection Section
    
    private var videoSelectionSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("1. Select Video")
                .font(.headline)
            
            PhotosPicker(
                selection: $viewModel.selectedItem,
                matching: .videos,
                photoLibrary: .shared()
            ) {
                Label("Choose Video", systemImage: "video.fill")
                    .frame(maxWidth: .infinity)
                    .padding()
                    .background(Color.blue.opacity(0.1))
                    .cornerRadius(8)
            }
            .disabled(viewModel.isRunning)
            
            if viewModel.isCopyingVideo {
                HStack {
                    ProgressView()
                        .scaleEffect(0.8)
                    Text("Copying video...")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }
            
            if let fileName = viewModel.selectedFileName {
                Text("Selected: \(fileName)")
                    .font(.caption)
                    .foregroundColor(.green)
            }
            
            if let error = viewModel.copyingError {
                Text("Error: \(error)")
                    .font(.caption)
                    .foregroundColor(.red)
            }
        }
    }
    
    // MARK: - Run Buttons Section
    
    private var runButtonsSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("2. Run Generate")
                .font(.headline)
            
            HStack(spacing: 12) {
                Button("Run Enter") {
                    viewModel.runPipeline(mode: .enter)
                }
                .buttonStyle(.borderedProminent)
                .disabled(viewModel.selectedURL == nil || viewModel.isRunning)
                
                if viewModel.isRunning {
                    Button("Cancel") {
                        viewModel.cancelPipeline()
                    }
                    .buttonStyle(.bordered)
                    .foregroundColor(.red)
                }
            }
        }
    }
    
    // MARK: - State Section
    
    private var stateSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("3. Status")
                .font(.headline)
            
            Text(stateDescription)
                .font(.system(.body, design: .monospaced))
                .padding()
                .background(Color.gray.opacity(0.1))
                .cornerRadius(8)
            
            if viewModel.isRunning {
                ProgressView()
                    .padding(.top, 4)
            }
        }
    }
    
    private var stateDescription: String {
        switch viewModel.uiState {
        case .idle:
            return "Idle"
        case .generating(let progress):
            if let progress = progress {
                return String(format: "Generating... %.0f%%", progress * 100)
            } else {
                return "Generating..."
            }
        case .success(let artifact):
            return "Success!\nArtifact: \(artifact.localPath.lastPathComponent)\nFormat: \(artifact.format == .splat ? "splat" : "unknown")"
        case .failed(let reason):
            return "Failed: \(reason)"
        }
    }
}

#Preview {
    PipelineDemoView()
}
