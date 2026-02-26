// SPDX-License-Identifier: LicenseRef-Aether3D-Proprietary
// Copyright (c) 2024-2026 Aether3D. All rights reserved.

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
protocol CameraSessionDelegate: AnyObject {
    /// Called when recording starts
    func cameraSessionDidStartRecording(_ session: CameraSessionProtocol)

    /// Called when recording stops
    func cameraSession(_ session: CameraSessionProtocol, didStopRecording result: RecordingResult)

    /// Called when recording fails
    func cameraSession(_ session: CameraSessionProtocol, didFailWithError error: CameraSessionError)

    /// Called when thermal state changes
    func cameraSession(_ session: CameraSessionProtocol, didChangeThermalState state: ThermalState)

    /// Called when interruption occurs
    func cameraSession(_ session: CameraSessionProtocol, didInterruptWithReason reason: String)
}

/// Default implementation (optional methods)
extension CameraSessionDelegate {
    func cameraSessionDidStartRecording(_ session: CameraSessionProtocol) {}
    func cameraSession(_ session: CameraSessionProtocol, didStopRecording result: RecordingResult) {}
    func cameraSession(_ session: CameraSessionProtocol, didFailWithError error: CameraSessionError) {}
    func cameraSession(_ session: CameraSessionProtocol, didChangeThermalState state: ThermalState) {}
    func cameraSession(_ session: CameraSessionProtocol, didInterruptWithReason reason: String) {}
}
