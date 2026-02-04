//
// PlatformAbstractionLayer.swift
// PR5Capture
//
// PR5 v1.8.1 - PART K: 跨平台确定性
// 平台抽象层，统一 iOS/macOS/visionOS API
//

import Foundation

#if canImport(UIKit)
import UIKit
#endif

#if canImport(AppKit)
import AppKit
#endif

/// Platform abstraction layer
///
/// Provides unified API across iOS/macOS/visionOS.
/// Abstracts platform-specific differences.
public enum PlatformAbstractionLayer {
    
    // MARK: - Platform Detection
    
    /// Current platform
    public static var currentPlatform: Platform {
        #if os(iOS)
        return .iOS
        #elseif os(macOS)
        return .macOS
        #elseif os(visionOS)
        return .visionOS
        #else
        return .unknown
        #endif
    }
    
    /// Platform type
    public enum Platform: String, Sendable {
        case iOS
        case macOS
        case visionOS
        case unknown
    }
    
    // MARK: - Unified APIs
    
    /// Get screen scale
    public static func screenScale() -> CGFloat {
        #if canImport(UIKit)
        return UIScreen.main.scale
        #elseif canImport(AppKit)
        return NSScreen.main?.backingScaleFactor ?? 1.0
        #else
        return 1.0
        #endif
    }
    
    /// Get screen bounds
    public static func screenBounds() -> CGRect {
        #if canImport(UIKit)
        return UIScreen.main.bounds
        #elseif canImport(AppKit)
        return NSScreen.main?.frame ?? CGRect.zero
        #else
        return CGRect.zero
        #endif
    }
    
    /// Check if running on simulator
    public static func isSimulator() -> Bool {
        #if targetEnvironment(simulator)
        return true
        #else
        return false
        #endif
    }
}
