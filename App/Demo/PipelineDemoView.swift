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
    @State private var showPreview = false
    
    var body: some View {
        NavigationView {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    // 视频选择区域
                    videoSelectionSection
                    
                    // 运行按钮区域
                    runButtonsSection
                    
                    // 查看结果入口（Phase 1-3 新增）
                    if OutputManager.shared.latestOutput() != nil {
                        viewResultSection
                    }
                    
                    // 状态显示区域
                    stateSection
                    
                    // Plan Summary 显示（反作弊验收）
                    if !viewModel.planSummary.isEmpty {
                        planSummarySection
                    }
                    
                    // 错误显示
                    if let errorText = viewModel.errorText {
                        errorSection(errorText)
                    }
                    
                    // 结果缩略图
                    if !viewModel.resultFrames.isEmpty {
                        thumbnailsSection
                    }
                }
                .padding()
            }
            .navigationTitle("Pipeline Demo")
            .sheet(isPresented: $showPreview) {
                if let output = OutputManager.shared.latestOutput() {
                    NavigationView {
                        ResultPreviewView(output: output)
                            .toolbar {
                                ToolbarItem(placement: .navigationBarTrailing) {
                                    Button("Done") {
                                        showPreview = false
                                    }
                                }
                            }
                    }
                }
            }
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
            Text("2. Run Pipeline")
                .font(.headline)
            
            HStack(spacing: 12) {
                Button("Run Enter") {
                    viewModel.runPipeline(mode: .enter)
                }
                .buttonStyle(.borderedProminent)
                .disabled(viewModel.selectedURL == nil || viewModel.isRunning)
                
                Button("Run Publish") {
                    viewModel.runPipeline(mode: .publish)
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
    
    // MARK: - View Result Section (Phase 1-3)
    
    private var viewResultSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("3. View Result")
                .font(.headline)
            
            Button(action: {
                showPreview = true
            }) {
                Label("View Latest Result", systemImage: "eye.fill")
                    .frame(maxWidth: .infinity)
                    .padding()
                    .background(Color.green.opacity(0.1))
                    .cornerRadius(8)
            }
        }
    }
    
    // MARK: - State Section
    
    private var stateSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("4. Pipeline State")
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
        switch viewModel.pipelineState {
        case .idle:
            return "Idle"
        case .planning:
            return "Planning..."
        case .extractingFrames(let progress):
            return String(format: "Extracting frames... %.0f%%", progress * 100)
        case .buildingArtifact(let progress):
            return String(format: "Building artifact... %.0f%%", progress * 100)
        case .finished:
            return "Finished"
        case .failed(let message):
            return "Failed: \(message)"
        }
    }
    
    // MARK: - Plan Summary Section
    
    private var planSummarySection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Plan Summary")
                .font(.headline)
            
            Text(viewModel.planSummary)
                .font(.system(.caption, design: .monospaced))
                .padding()
                .background(Color.blue.opacity(0.1))
                .cornerRadius(8)
        }
    }
    
    // MARK: - Error Section
    
    private func errorSection(_ errorText: String) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Error")
                .font(.headline)
                .foregroundColor(.red)
            
            Text(errorText)
                .font(.caption)
                .foregroundColor(.red)
                .padding()
                .background(Color.red.opacity(0.1))
                .cornerRadius(8)
        }
    }
    
    // MARK: - Thumbnails Section
    
    private var thumbnailsSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Result Frames (\(viewModel.resultFrames.count))")
                .font(.headline)
            
            LazyVGrid(columns: [
                GridItem(.flexible()),
                GridItem(.flexible()),
                GridItem(.flexible())
            ], spacing: 12) {
                ForEach(Array(viewModel.resultFrames.enumerated()), id: \.offset) { index, frame in
                    FrameThumbnailView(frame: frame)
                }
            }
        }
    }
}

// MARK: - Frame Thumbnail View

struct FrameThumbnailView: View {
    let frame: Frame
    
    var body: some View {
        VStack(spacing: 4) {
            if let uiImage = cgImageToUIImage(frame.image) {
                Image(uiImage: uiImage)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .frame(width: 100, height: 100)
                    .clipped()
                    .cornerRadius(8)
            } else {
                Rectangle()
                    .fill(Color.gray.opacity(0.3))
                    .frame(width: 100, height: 100)
                    .cornerRadius(8)
            }
            
            Text("#\(frame.index)")
                .font(.caption2)
                .foregroundColor(.secondary)
        }
    }
    
    private func cgImageToUIImage(_ cgImage: CGImage) -> UIImage? {
        return UIImage(cgImage: cgImage)
    }
}

#Preview {
    PipelineDemoView()
}

