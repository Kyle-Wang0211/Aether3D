//
//  InterruptionHandler.swift
//  progect2
//
//  Created for PR#4 Capture Recording
//

import Foundation
import AVFoundation
import UIKit

// CI-HARDENED: This file must not use DispatchQueue.main.asyncAfter.
// All timer operations must use injected TimerScheduler for determinism.

final class InterruptionHandler {
    private let session: AVCaptureSession
    private let onInterruptionBegan: (InterruptionReasonCode) -> Void
    private let onInterruptionEnded: () -> Void
    private let timerScheduler: TimerScheduler
    private var isObserving = false
    private var hasReceivedInterruption = false
    
    private var interruptionObserver: NSObjectProtocol?
    private var interruptionEndedObserver: NSObjectProtocol?
    private var didBecomeActiveObserver: NSObjectProtocol?
    private var delayToken: Cancellable?
    
    // CI-HARDENED: TimerScheduler injection for deterministic timers
    init(session: AVCaptureSession,
         onInterruptionBegan: @escaping (InterruptionReasonCode) -> Void,
         onInterruptionEnded: @escaping () -> Void,
         timerScheduler: TimerScheduler = DefaultTimerScheduler()) {
        self.session = session
        self.onInterruptionBegan = onInterruptionBegan
        self.onInterruptionEnded = onInterruptionEnded
        self.timerScheduler = timerScheduler
    }
    
    func startObserving() {
        guard !isObserving else { return }
        isObserving = true
        
        let center = NotificationCenter.default
        
        // PRIMARY: AVCaptureSession.wasInterruptedNotification
        interruptionObserver = center.addObserver(
            forName: .AVCaptureSessionWasInterrupted,
            object: session,
            queue: .main
        ) { [weak self] notification in
            guard let self = self else { return }
            self.hasReceivedInterruption = true
            
            let reason: InterruptionReasonCode
            if let userInfo = notification.userInfo,
               let interruptionReason = userInfo[AVCaptureSessionInterruptionReasonKey] as? AVCaptureSession.InterruptionReason {
                switch interruptionReason {
                case .videoDeviceInUseByAnotherClient:
                    reason = .cameraInUseByOtherApp
                case .videoDeviceNotAvailableInBackground:
                    reason = .multitaskingNotSupported
                case .audioDeviceInUseByAnotherClient:
                    reason = .audioConflict
                @unknown default:
                    reason = .unknown
                }
            } else {
                reason = .unknown
            }
            
            self.onInterruptionBegan(reason)
        }
        
        // SECONDARY: AVCaptureSession.interruptionEndedNotification
        interruptionEndedObserver = center.addObserver(
            forName: .AVCaptureSessionInterruptionEnded,
            object: session,
            queue: .main
        ) { [weak self] _ in
            guard let self = self else { return }
            self.onInterruptionEnded()
            self.hasReceivedInterruption = false
        }
        
        // SECONDARY: UIApplication.didBecomeActiveNotification
        didBecomeActiveObserver = center.addObserver(
            forName: UIApplication.didBecomeActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            guard let self = self else { return }
            if self.hasReceivedInterruption {
                // CI-HARDENED: Use TimerScheduler instead of asyncAfter
                // Cancel any existing delay token
                self.delayToken?.cancel()
                // Schedule new delay
                self.delayToken = self.timerScheduler.schedule(after: CaptureRecordingConstants.reconfigureDelaySeconds) {
                    DispatchQueue.main.async {
                        self.onInterruptionEnded()
                        self.hasReceivedInterruption = false
                    }
                }
            }
        }
    }
    
    func stopObserving() {
        guard isObserving else { return }
        isObserving = false
        
        // Cancel any pending timer
        delayToken?.cancel()
        delayToken = nil
        
        if let observer = interruptionObserver {
            NotificationCenter.default.removeObserver(observer)
            interruptionObserver = nil
        }
        
        if let observer = interruptionEndedObserver {
            NotificationCenter.default.removeObserver(observer)
            interruptionEndedObserver = nil
        }
        
        if let observer = didBecomeActiveObserver {
            NotificationCenter.default.removeObserver(observer)
            didBecomeActiveObserver = nil
        }
        
        hasReceivedInterruption = false
    }
    
    deinit {
        stopObserving()
    }
}

