// SPDX-License-Identifier: LicenseRef-Aether3D-Proprietary
// Copyright (c) 2024-2026 Aether3D. All rights reserved.

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

#if canImport(CoreGraphics)
import CoreGraphics
#endif

/// Platform abstraction layer
///
/// Provides unified API across iOS/macOS/visionOS/Linux.
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
        #elseif os(Linux)
        return .linux
        #else
        return .unknown
        #endif
    }

    /// Platform type
    public enum Platform: String, Sendable {
        case iOS
        case macOS
        case visionOS
        case linux
        case unknown
    }

    // MARK: - Unified APIs

    /// Get screen scale
    public static func screenScale() -> Double {
        #if canImport(UIKit)
        return Double(UIScreen.main.scale)
        #elseif canImport(AppKit)
        return Double(NSScreen.main?.backingScaleFactor ?? 1.0)
        #else
        return 1.0
        #endif
    }

    /// Screen rect for cross-platform compatibility
    public struct ScreenRect: Sendable {
        public let x: Double
        public let y: Double
        public let width: Double
        public let height: Double

        public static let zero = ScreenRect(x: 0, y: 0, width: 0, height: 0)
    }

    /// Get screen bounds
    public static func screenBounds() -> ScreenRect {
        #if canImport(UIKit)
        let bounds = UIScreen.main.bounds
        return ScreenRect(x: Double(bounds.origin.x), y: Double(bounds.origin.y),
                         width: Double(bounds.width), height: Double(bounds.height))
        #elseif canImport(AppKit)
        if let frame = NSScreen.main?.frame {
            return ScreenRect(x: Double(frame.origin.x), y: Double(frame.origin.y),
                             width: Double(frame.width), height: Double(frame.height))
        }
        return ScreenRect.zero
        #else
        return ScreenRect.zero
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
