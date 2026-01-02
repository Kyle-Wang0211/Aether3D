//
//  ResultPreviewView.swift
//  progect2
//
//  Created by Kaidong Wang on 12/18/25.
//

import SwiftUI
import CoreGraphics

struct ResultPreviewView: View {
    let output: PipelineOutput
    
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                // 1. 标题区
                titleSection
                
                // 2. 源信息区
                sourceSection
                
                // 3. 帧网格区
                framesGridSection
                
                // 4. 元数据区（反作弊）
                metadataSection
            }
            .padding()
        }
        .navigationTitle("Result Preview")
        .navigationBarTitleDisplayMode(.inline)
    }
    
    // MARK: - Title Section
    
    private var titleSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Output ID")
                .font(.headline)
            Text(String(output.id.uuidString.prefix(8)))
                .font(.system(.body, design: .monospaced))
                .foregroundColor(.secondary)
            
            Text("Created At")
                .font(.headline)
                .padding(.top, 4)
            Text(formatDate(output.createdAt))
                .font(.system(.body, design: .monospaced))
                .foregroundColor(.secondary)
        }
        .padding()
        .background(Color.gray.opacity(0.1))
        .cornerRadius(8)
    }
    
    // MARK: - Source Section
    
    private var sourceSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Source Video")
                .font(.headline)
            Text(output.sourceVideoURL.lastPathComponent)
                .font(.caption)
                .foregroundColor(.secondary)
        }
        .padding()
        .background(Color.blue.opacity(0.1))
        .cornerRadius(8)
    }
    
    // MARK: - Frames Grid Section
    
    private var framesGridSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Frames (\(output.frames.count))")
                .font(.headline)
            
            if output.frames.isEmpty {
                Text("No frames available")
                    .foregroundColor(.secondary)
                    .padding()
            } else {
                LazyVGrid(columns: [
                    GridItem(.flexible()),
                    GridItem(.flexible()),
                    GridItem(.flexible())
                ], spacing: 12) {
                    ForEach(Array(output.frames.enumerated()), id: \.offset) { index, frame in
                        FrameThumbnailView(frame: frame)
                    }
                }
            }
        }
        .padding()
        .background(Color.gray.opacity(0.1))
        .cornerRadius(8)
    }
    
    // MARK: - Metadata Section (Anti-cheat)
    
    private var metadataSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Build Plan Summary")
                .font(.headline)
            
            Text(output.buildPlan.displaySummary)
                .font(.system(.caption, design: .monospaced))
                .padding()
                .background(Color.blue.opacity(0.1))
                .cornerRadius(8)
        }
        .padding()
        .background(Color.gray.opacity(0.1))
        .cornerRadius(8)
    }
    
    // MARK: - Helper
    
    private func formatDate(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .medium
        return formatter.string(from: date)
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
    NavigationView {
        ResultPreviewView(
            output: PipelineOutput(
                id: UUID(),
                sourceVideoURL: URL(fileURLWithPath: "/test/video.mov"),
                frames: [],
                buildPlan: BuildPlan(
                    deviceTier: .medium,
                    mode: .enter,
                    timeBudgetMs: 2000,
                    frameBudget: 60,
                    maxSplats: 300000,
                    lodLevel: 2,
                    shOrder: 2,
                    progressive: true,
                    stopRules: StopRules.default(for: .medium)
                ),
                pluginResult: nil,
                state: .success,
                metadata: PipelineMetadata(processingTimeMs: 1500, totalFrames: 60),
                createdAt: Date()
            )
        )
    }
}

