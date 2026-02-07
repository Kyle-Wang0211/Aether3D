//
// CameraSessionError.swift
// Aether3D
//
// Camera Session Error - Error types for camera session
//

import Foundation

/// Camera Session Error
///
/// Error types for camera session operations.
public enum CameraSessionError: Error, Sendable {
    case permissionDenied
    case cameraUnavailable
    case configurationFailed(String)
    case recordingFailed(String)
    case fileSizeExceeded
    case durationExceeded
    case thermalShutdown
    case interruption(String)
    case codecNotSupported
    case formatNotSupported
    
    public var localizedDescription: String {
        switch self {
        case .permissionDenied:
            return "Camera permission denied"
        case .cameraUnavailable:
            return "Camera is not available"
        case .configurationFailed(let reason):
            return "Camera configuration failed: \(reason)"
        case .recordingFailed(let reason):
            return "Recording failed: \(reason)"
        case .fileSizeExceeded:
            return "File size exceeded maximum limit"
        case .durationExceeded:
            return "Recording duration exceeded maximum limit"
        case .thermalShutdown:
            return "Recording stopped due to thermal shutdown"
        case .interruption(let reason):
            return "Recording interrupted: \(reason)"
        case .codecNotSupported:
            return "Video codec is not supported"
        case .formatNotSupported:
            return "Video format is not supported"
        }
    }
}
