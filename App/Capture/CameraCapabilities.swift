//
// CameraCapabilities.swift
// Aether3D
//
// Camera Capabilities Detection - Device capability detection
// 符合 PR4-01: iOS 18/19 Camera API Integration
//

import Foundation
import AVFoundation

/// Camera Capabilities Detector
///
/// Detects device capabilities for advanced camera features.
public actor CameraCapabilities {
    
    /// Check if device supports HDR
    /// 
    /// - Returns: True if HDR is supported
    public func supportsHDR() -> Bool {
        let discoverySession = AVCaptureDevice.DiscoverySession(
            deviceTypes: [.builtInWideAngleCamera],
            mediaType: .video,
            position: .back
        )
        
        guard let device = discoverySession.devices.first else {
            return false
        }
        
        return device.activeFormat.isVideoHDRSupported
    }
    
    /// Check if device supports ProRes RAW
    /// 
    /// - Returns: True if ProRes RAW is supported
    public func supportsProResRAW() -> Bool {
        let discoverySession = AVCaptureDevice.DiscoverySession(
            deviceTypes: [.builtInWideAngleCamera],
            mediaType: .video,
            position: .back
        )
        
        guard let device = discoverySession.devices.first else {
            return false
        }
        
        // Check for ProRes RAW support (iOS 14.3+)
        for format in device.formats {
            if format.videoCodecType == .proResRAW {
                return true
            }
        }
        
        return false
    }
    
    /// Check if device supports LiDAR
    /// 
    /// - Returns: True if LiDAR is available
    public func supportsLiDAR() -> Bool {
        let discoverySession = AVCaptureDevice.DiscoverySession(
            deviceTypes: [.builtInLiDARDepthCamera],
            mediaType: .video,
            position: .back
        )
        
        return !discoverySession.devices.isEmpty
    }
    
    /// Check if device supports ARKit
    /// 
    /// - Returns: True if ARKit is available
    public func supportsARKit() -> Bool {
        #if canImport(ARKit)
        return ARSession.isSupported
        #else
        return false
        #endif
    }
    
    /// Get maximum supported resolution
    /// 
    /// - Returns: Maximum resolution
    public func getMaxResolution() -> VideoResolution {
        let discoverySession = AVCaptureDevice.DiscoverySession(
            deviceTypes: [.builtInWideAngleCamera],
            mediaType: .video,
            position: .back
        )
        
        guard let device = discoverySession.devices.first else {
            return .resolution1080p
        }
        
        var maxWidth: Int32 = 0
        var maxHeight: Int32 = 0
        
        for format in device.formats {
            let dimensions = CMVideoFormatDescriptionGetDimensions(format.formatDescription)
            if dimensions.width > maxWidth || dimensions.height > maxHeight {
                maxWidth = dimensions.width
                maxHeight = dimensions.height
            }
        }
        
        if maxWidth >= 3840 && maxHeight >= 2160 {
            return .resolution4K
        } else {
            return .resolution1080p
        }
    }
    
    /// Get maximum supported frame rate for resolution
    /// 
    /// - Parameter resolution: Video resolution
    /// - Returns: Maximum frame rate
    public func getMaxFrameRate(for resolution: VideoResolution) -> Double {
        let discoverySession = AVCaptureDevice.DiscoverySession(
            deviceTypes: [.builtInWideAngleCamera],
            mediaType: .video,
            position: .back
        )
        
        guard let device = discoverySession.devices.first else {
            return 30.0
        }
        
        let targetDimensions = resolution.dimensions
        var maxFrameRate: Double = 30.0
        
        for format in device.formats {
            let dimensions = CMVideoFormatDescriptionGetDimensions(format.formatDescription)
            if dimensions.width == targetDimensions.width && dimensions.height == targetDimensions.height {
                for range in format.videoSupportedFrameRateRanges {
                    maxFrameRate = max(maxFrameRate, range.maxFrameRate)
                }
            }
        }
        
        return maxFrameRate
    }
}

#if canImport(ARKit)
import ARKit

extension ARSession {
    /// Check if ARKit is supported
    static var isSupported: Bool {
        return ARWorldTrackingConfiguration.isSupported
    }
}
#endif
