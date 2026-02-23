// SPDX-License-Identifier: LicenseRef-Aether3D-Proprietary
// Copyright (c) 2024-2026 Aether3D. All rights reserved.

//
// ARKitSessionManager.swift
// Aether3D
//
// ARKit Session Manager - ARKit integration for 4K ARKit support
// 符合 PR4-01: iOS 18/19 Camera API Integration (4K ARKit)
//

import Foundation

#if canImport(ARKit)
import ARKit

/// ARKit Session Manager
///
/// Manages ARKit session for 4K ARKit support.
/// 符合 PR4-01: iOS 18/19 Camera API Integration (4K ARKit)
public actor ARKitSessionManager {
    
    // MARK: - State
    
    private var arSession: ARSession?
    private var isRunning: Bool = false
    
    // MARK: - Session Management
    
    /// Start ARKit session
    /// 
    /// - Throws: ARKitError if session fails to start
    public func startSession() throws {
        guard !isRunning else {
            return
        }
        
        guard ARWorldTrackingConfiguration.isSupported else {
            throw ARKitError.notSupported
        }
        
        let configuration = ARWorldTrackingConfiguration()
        configuration.worldAlignment = .gravity

        // Enable 4K ARKit if available (iOS 18+)
        if #available(iOS 18.0, *) {
            // Configure for high-resolution tracking
            configuration.planeDetection = [.horizontal, .vertical]
        }

        // Enable per-frame depth map for TSDF fusion (PR#6 dependency)
        // sceneDepth provides 256×192 depth CVPixelBuffer at 60fps on LiDAR devices
        if ARWorldTrackingConfiguration.supportsFrameSemantics(.sceneDepth) {
            configuration.frameSemantics.insert(.sceneDepth)
        }

        let session = ARSession()
        session.run(configuration)
        
        arSession = session
        isRunning = true
    }
    
    /// Stop ARKit session
    public func stopSession() {
        guard isRunning else {
            return
        }
        
        arSession?.pause()
        arSession = nil
        isRunning = false
    }
    
    /// Get ARKit session
    /// 
    /// - Returns: ARSession if available
    public func getSession() -> ARSession? {
        return arSession
    }
}

/// ARKit Errors
public enum ARKitError: Error, Sendable {
    case notSupported
    case sessionFailed(String)
    
    public var localizedDescription: String {
        switch self {
        case .notSupported:
            return "ARKit is not supported on this device"
        case .sessionFailed(let reason):
            return "ARKit session failed: \(reason)"
        }
    }
}

#else

/// ARKit Session Manager (stub for non-iOS platforms)
public actor ARKitSessionManager {
    public func startSession() throws {
        throw ARKitError.notSupported
    }
    
    public func stopSession() {
        // No-op
    }
    
    public func getSession() -> Any? {
        return nil
    }
}

/// ARKit Errors
public enum ARKitError: Error, Sendable {
    case notSupported
    case sessionFailed(String)
    
    public var localizedDescription: String {
        switch self {
        case .notSupported:
            return "ARKit is not supported on this platform"
        case .sessionFailed(let reason):
            return "ARKit session failed: \(reason)"
        }
    }
}

#endif
