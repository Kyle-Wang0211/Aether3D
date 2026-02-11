//
// ScanCaptureControls.swift
// Aether3D
//
// PR#7 Scan Guidance UI — Scan Capture Controls
// Apple-platform only (SwiftUI)
// Phase 4: Full implementation
//

import Foundation

#if canImport(SwiftUI)
import SwiftUI
#endif

#if canImport(UIKit)
import UIKit
#endif

#if canImport(SwiftUI)
/// Scan capture control button
public struct ScanCaptureControls: View {
    @State private var isPressed = false
    @State private var showMenu = false
    
    let onStart: () -> Void
    let onStop: () -> Void
    let onPause: () -> Void
    
    public init(
        onStart: @escaping () -> Void,
        onStop: @escaping () -> Void,
        onPause: @escaping () -> Void
    ) {
        self.onStart = onStart
        self.onStop = onStop
        self.onPause = onPause
    }
    
    public var body: some View {
        VStack {
            Spacer()
            HStack {
                Spacer()
                
                // Main capture button (white border, black fill)
                Button(action: {
                    if isPressed {
                        onStop()
                    } else {
                        onStart()
                    }
                    isPressed.toggle()
                }) {
                    Circle()
                        .fill(Color.black)
                        .overlay(
                            Circle()
                                .stroke(Color.white, lineWidth: 3)
                        )
                        .frame(width: 60, height: 60)
                        .overlay(
                            Circle()
                                .fill(isPressed ? Color.red : Color.white)
                                .frame(width: 20, height: 20)
                        )
                }
                .buttonStyle(PlainButtonStyle())
                .simultaneousGesture(
                    LongPressGesture(minimumDuration: 0.5)
                        .onEnded { _ in
                            showMenu.toggle()
                        }
                )
                
                Spacer()
            }
            .padding(.bottom, 50)
            
            // Long-press menu
            if showMenu {
                VStack(spacing: 12) {
                    Button("暂停") {
                        onPause()
                        showMenu = false
                    }
                    .foregroundColor(.white)
                    .padding()
                    .background(Color.black.opacity(0.8))
                    .cornerRadius(8)
                    
                    Button("停止") {
                        onStop()
                        showMenu = false
                    }
                    .foregroundColor(.white)
                    .padding()
                    .background(Color.black.opacity(0.8))
                    .cornerRadius(8)
                }
                .padding(.bottom, 120)
            }
        }
    }
}
#endif
