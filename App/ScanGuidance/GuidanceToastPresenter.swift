//
// GuidanceToastPresenter.swift
// Aether3D
//
// PR#7 Scan Guidance UI — Toast Message Presenter
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

/// Toast message presenter for scan guidance
public final class GuidanceToastPresenter {
    
    /// Current toast message
    @Published private(set) var currentMessage: String?
    
    /// Toast visibility state
    @Published private(set) var isVisible: Bool = false
    
    /// Toast duration (seconds)
    private let normalDuration: TimeInterval = 2.0
    private let voiceOverDuration: TimeInterval = 5.0
    
    public init() {}
    
    /// Show toast message
    ///
    /// - Parameter message: Message to display
    public func show(message: String) {
        currentMessage = message
        isVisible = true
        
        // Check if VoiceOver is active
        let duration = isVoiceOverActive() ? voiceOverDuration : normalDuration
        
        // Hide after duration
        DispatchQueue.main.asyncAfter(deadline: .now() + duration) { [weak self] in
            self?.isVisible = false
            self?.currentMessage = nil
        }
    }
    
    /// Check if VoiceOver is active
    private func isVoiceOverActive() -> Bool {
        #if os(iOS)
        return UIAccessibility.isVoiceOverRunning
        #else
        return false
        #endif
    }
    
    /// Get contrast ratio (white on 85% black background)
    /// WCAG 2.1 AAA requires >= 7:1 for normal text, >= 4.5:1 for large text
    /// White (255,255,255) on black (0,0,0) with 85% opacity = (0,0,0) * 0.85 + (255,255,255) * 0.15
    /// = (38.25, 38.25, 38.25) ≈ (38, 38, 38)
    /// Contrast ratio = (L1 + 0.05) / (L2 + 0.05) where L1 is lighter, L2 is darker
    /// L = 0.2126*R + 0.7152*G + 0.0722*B (relative luminance)
    /// White L = 1.0, Background L ≈ 0.15
    /// Contrast = (1.0 + 0.05) / (0.15 + 0.05) = 1.05 / 0.20 = 5.25
    /// Actually, with 85% black alpha, the effective background is darker.
    /// Let's calculate: black (0,0,0) with 85% opacity over white (255,255,255) background
    /// = (0,0,0) * 0.85 + (255,255,255) * 0.15 = (38.25, 38.25, 38.25)
    /// Relative luminance of (38,38,38): L = (38/255)^2.2 ≈ 0.015
    /// White L = 1.0
    /// Contrast = (1.0 + 0.05) / (0.015 + 0.05) = 1.05 / 0.065 ≈ 16.15
    /// But wait, the spec says "black background (alpha 0.85)" which means 85% opacity black overlay.
    /// If the overlay is 85% black, the effective color is darker.
    /// For WCAG AAA, we need >= 7:1 for normal text (15pt is normal).
    /// Our calculation shows ~16:1, which exceeds the requirement.
    public static func contrastRatio() -> Double {
        // White text luminance
        let whiteL = 1.0
        
        // Black background with 85% opacity over white
        // Effective color: (0,0,0) * 0.85 + (255,255,255) * 0.15 = (38.25, 38.25, 38.25)
        let bgR = 38.25 / 255.0
        let bgL = pow(bgR, 2.2)  // Gamma correction for relative luminance
        
        // Contrast ratio formula
        let contrast = (whiteL + 0.05) / (bgL + 0.05)
        return contrast
    }
}

#if canImport(SwiftUI)
/// SwiftUI toast overlay view
public struct ToastOverlay: View {
    @ObservedObject var presenter: GuidanceToastPresenter
    
    public var body: some View {
        if presenter.isVisible, let message = presenter.currentMessage {
            VStack {
                Spacer()
                Text(message)
                    .font(.system(size: 15))
                    .foregroundColor(.white)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 12)
                    .background(
                        Color.black.opacity(0.85)
                            .cornerRadius(12)
                    )
                    .padding(.bottom, 50)
            }
            .transition(.opacity)
            .animation(.easeInOut, value: presenter.isVisible)
        }
    }
}
#endif
