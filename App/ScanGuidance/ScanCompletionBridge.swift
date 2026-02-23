//
// ScanCompletionBridge.swift
// Aether3D
//
// PR#7 Scan Guidance UI — Scan Completion Bridge
// Bridges RecordingController → HapticEngine via NotificationCenter
// Phase 4: Full implementation
//

import Foundation

extension Notification.Name {
    /// Posted by RecordingController when scan stops
    public static let scanDidComplete = Notification.Name("PR7ScanDidComplete")
}

/// Observes scan completion and fires haptic
public final class ScanCompletionBridge {
    private let hapticEngine: GuidanceHapticEngine
    private var observation: NSObjectProtocol?
    
    public init(hapticEngine: GuidanceHapticEngine) {
        self.hapticEngine = hapticEngine
        observation = NotificationCenter.default.addObserver(
            forName: .scanDidComplete,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.hapticEngine.fireCompletion()
        }
    }
    
    deinit {
        if let obs = observation {
            NotificationCenter.default.removeObserver(obs)
        }
    }
}
