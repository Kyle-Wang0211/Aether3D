//
// HomePage.swift
// Aether3D
//
// PR#7 Scan Guidance UI — Home Page
// Apple-platform only (SwiftUI)
//

import Foundation

#if canImport(SwiftUI)
import SwiftUI

#if canImport(UIKit)
import UIKit
#endif

/// Main screen: gallery of completed scans + "开始拍摄" button
///
/// Layout:
///   - ScrollView with LazyVGrid (2 columns, 16pt spacing)
///   - Empty state: centered "尚无扫描作品" + SF Symbol
///   - Bottom: full-width "开始拍摄" button (white bg, black text)
///
/// Navigation:
///   - Tap "开始拍摄" → ScanView (via NavigationStack destination)
///   - Swipe-to-delete on gallery cells
struct HomePage: View {
    @StateObject private var viewModel = HomeViewModel()
    @State private var navigateToScan = false

    private let columns = [
        GridItem(.flexible(), spacing: 16),
        GridItem(.flexible(), spacing: 16)
    ]

    var body: some View {
        ZStack {
            // Background
            Color.black.ignoresSafeArea()

            VStack(spacing: 0) {
                if viewModel.scanRecords.isEmpty && !viewModel.isLoading {
                    // Empty state
                    emptyStateView
                } else {
                    // Gallery
                    galleryView
                }

                Spacer()

                // Start scan button
                startButton
            }
        }
        .navigationTitle("Aether3D")
        .navigationBarTitleDisplayMode(.inline)
        .toolbarColorScheme(.dark, for: .navigationBar)
        .onAppear {
            viewModel.loadRecords()
        }
        #if canImport(ARKit)
        .navigationDestination(isPresented: $navigateToScan) {
            ScanView()
        }
        #endif
    }

    // MARK: - Empty State

    private var emptyStateView: some View {
        VStack(spacing: 16) {
            Spacer()

            Image(systemName: "viewfinder.circle")
                .font(.system(size: 64))
                .foregroundColor(.gray)

            Text("尚无扫描作品")
                .font(.system(size: 17))
                .foregroundColor(.gray)

            Spacer()
        }
    }

    // MARK: - Gallery Grid

    private var galleryView: some View {
        ScrollView {
            LazyVGrid(columns: columns, spacing: 20) {
                ForEach(viewModel.scanRecords) { record in
                    ScanRecordCell(
                        record: record,
                        relativeTime: viewModel.relativeTimeString(for: record.createdAt)
                    )
                    .contextMenu {
                        Button(role: .destructive) {
                            viewModel.deleteRecord(record)
                        } label: {
                            Label("删除", systemImage: "trash")
                        }
                    }
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 12)
        }
    }

    // MARK: - Start Button

    private var startButton: some View {
        Button(action: {
            #if canImport(UIKit)
            let generator = UIImpactFeedbackGenerator(style: .light)
            generator.impactOccurred()
            #endif
            navigateToScan = true
        }) {
            Text("开始拍摄")
                .font(.system(size: 17, weight: .bold))
                .foregroundColor(.black)
                .frame(maxWidth: .infinity)
                .frame(height: 56)
                .background(Color.white)
                .cornerRadius(28)
        }
        .padding(.horizontal, 24)
        .padding(.bottom, 16)
        .buttonStyle(ScaleButtonStyle())
    }
}

/// Scale animation button style (press effect)
private struct ScaleButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.95 : 1.0)
            .animation(.easeInOut(duration: 0.15), value: configuration.isPressed)
    }
}

#endif
