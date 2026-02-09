// SPDX-License-Identifier: LicenseRef-Aether3D-Proprietary
// Copyright (c) 2024-2026 Aether3D. All rights reserved.

//
// CoordinateNormalizer.swift
// Aether3D
//
// PR2 Patch V4 - Coordinate Pipeline Specification
// Explicit pipeline: raw → undistorted → oriented → normalized
//

import Foundation
#if canImport(CoreGraphics)
import CoreGraphics
#endif

/// Coordinate pipeline specification for PatchId generation
///
/// PIPELINE STAGES:
/// 1. RAW: Direct from camera sensor (may have distortion, arbitrary orientation)
/// 2. UNDISTORTED: Lens distortion removed (still in sensor orientation)
/// 3. ORIENTED: Rotated to device orientation (portrait/landscape)
/// 4. NORMALIZED: Scaled to [0,1] x [0,1] with (0,0) = top-left
///
/// PR2 uses NORMALIZED coordinates for PatchId generation.
/// This ensures orientation-independence across capture sessions.
public enum PatchIdCoordinateSpec {
    
    /// Coordinate space used for PatchId
    public static let coordinateSpace: CoordinateSpace = .normalized
    
    public enum CoordinateSpace: String {
        case raw = "raw"
        case undistorted = "undistorted"
        case oriented = "oriented"
        case normalized = "normalized"  // PR2 default
    }
    
    /// Reference for normalization
    public static let normalizationReference: NormalizationReference = .longerEdge1920
    
    public enum NormalizationReference: String {
        case longerEdge1920 = "longer_edge_1920"  // PR2 default
        case fixedResolution = "fixed_1920x1080"
        case aspectRatioPreserving = "aspect_ratio"
    }
}

#if canImport(CoreGraphics)
/// Coordinate normalizer with explicit pipeline
public struct CoordinateNormalizer {
    
    /// Transform raw camera point to normalized coordinate
    ///
    /// PIPELINE:
    /// 1. Apply lens undistortion (if intrinsics available)
    /// 2. Rotate to device orientation
    /// 3. Scale to [0,1] x [0,1]
    public static func normalize(
        rawPoint: CGPoint,
        frameSize: CGSize,
        orientation: UIDeviceOrientation,
        intrinsics: CameraIntrinsics? = nil
    ) -> CGPoint {
        var point = rawPoint
        
        // Stage 1: Undistortion (optional, if intrinsics available)
        if let intrinsics = intrinsics {
            point = undistort(point: point, intrinsics: intrinsics)
        }
        
        // Stage 2: Orientation correction
        point = orientationCorrect(
            point: point,
            frameSize: frameSize,
            orientation: orientation
        )
        
        // Stage 3: Normalization to [0,1] x [0,1]
        let normalizedX = point.x / frameSize.width
        let normalizedY = point.y / frameSize.height
        
        return CGPoint(
            x: max(0, min(1, normalizedX)),
            y: max(0, min(1, normalizedY))
        )
    }
    
    /// Undistort point using camera intrinsics
    /// For PR2, we assume Apple's ARKit already provides undistorted coordinates
    /// This is a placeholder for custom camera support
    private static func undistort(point: CGPoint, intrinsics: CameraIntrinsics) -> CGPoint {
        // Brown-Conrady distortion model would go here
        // For PR2, assume already undistorted
        return point
    }
    
    /// Correct for device orientation
    /// Output: point in canonical orientation (portrait, home button at bottom)
    private static func orientationCorrect(
        point: CGPoint,
        frameSize: CGSize,
        orientation: UIDeviceOrientation
    ) -> CGPoint {
        switch orientation {
        case .portrait:
            return point  // Canonical
        case .portraitUpsideDown:
            return CGPoint(x: frameSize.width - point.x, y: frameSize.height - point.y)
        case .landscapeLeft:
            return CGPoint(x: point.y, y: frameSize.width - point.x)
        case .landscapeRight:
            return CGPoint(x: frameSize.height - point.y, y: point.x)
        default:
            return point  // Unknown, assume portrait
        }
    }
}


#if canImport(UIKit)
import UIKit
public typealias UIDeviceOrientation = UIKit.UIDeviceOrientation
#else
// Stub for non-UIKit platforms
public enum UIDeviceOrientation {
    case portrait
    case portraitUpsideDown
    case landscapeLeft
    case landscapeRight
    case unknown
}
#endif

/// Camera intrinsics (for future custom camera support)
public struct CameraIntrinsics: Codable {
    public let fx: Double  // Focal length X
    public let fy: Double  // Focal length Y
    public let cx: Double  // Principal point X
    public let cy: Double  // Principal point Y
    public let k1: Double  // Radial distortion 1
    public let k2: Double  // Radial distortion 2
    public let p1: Double  // Tangential distortion 1
    public let p2: Double  // Tangential distortion 2
}
#endif
