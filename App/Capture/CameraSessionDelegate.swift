//
// CameraSessionDelegate.swift
// Aether3D
//
// Camera Session Delegate - Delegate protocol for camera session events
//

import Foundation
import AVFoundation

/// Camera Session Delegate
///
/// Delegate protocol for camera session events.
public protocol CameraSessionDelegate: AnyObject {
    /// Called when recording starts
    /// 
    /// - Parameter session: Camera session
    func cameraSessionDidStartRecording(_ session: CameraSessionProtocol)
    
    /// Called when recording stops
    /// 
    /// - Parameters:
    ///   - session: Camera session
    ///   - result: Recording result
    func cameraSession(_ session: CameraSessionProtocol, didStopRecording result: RecordingResult)
    
    /// Called when recording fails
    /// 
    /// - Parameters:
    ///   - session: Camera session
    ///   - error: Error that occurred
    func cameraSession(_ session: CameraSessionProtocol, didFailWithError error: CameraSessionError)
    
    /// Called when thermal state changes
    /// 
    /// - Parameters:
    ///   - session: Camera session
    ///   - state: New thermal state
    func cameraSession(_ session: CameraSessionProtocol, didChangeThermalState state: ThermalState)
    
    /// Called when interruption occurs
    /// 
    /// - Parameters:
    ///   - session: Camera session
    ///   - reason: Interruption reason
    func cameraSession(_ session: CameraSessionProtocol, didInterruptWithReason reason: String)
}

/// Default implementation (optional methods)
public extension CameraSessionDelegate {
    func cameraSessionDidStartRecording(_ session: CameraSessionProtocol) {}
    func cameraSession(_ session: CameraSessionProtocol, didStopRecording result: RecordingResult) {}
    func cameraSession(_ session: CameraSessionProtocol, didFailWithError error: CameraSessionError) {}
    func cameraSession(_ session: CameraSessionProtocol, didChangeThermalState state: ThermalState) {}
    func cameraSession(_ session: CameraSessionProtocol, didInterruptWithReason reason: String) {}
}
