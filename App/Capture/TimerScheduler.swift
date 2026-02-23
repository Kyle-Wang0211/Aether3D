// SPDX-License-Identifier: LicenseRef-Aether3D-Proprietary
// Copyright (c) 2024-2026 Aether3D. All rights reserved.

//
//  TimerScheduler.swift
//  progect2
//
//  Created for PR#4 Capture Recording
//
//  CI-HARDENED: This file is the ONLY allowed location for Timer.scheduledTimer usage in App/Capture.
//  DefaultTimerScheduler implementation uses Timer.scheduledTimer to provide timer functionality.

import Foundation

// MARK: - Cancellable Protocol

protocol Cancellable {
    func cancel()
}

// MARK: - TimerScheduler Protocol

protocol TimerScheduler {
    @discardableResult
    func schedule(after: TimeInterval, _ block: @escaping () -> Void) -> Cancellable
}

// MARK: - Default Implementation

struct DefaultTimerScheduler: TimerScheduler {
    @discardableResult
    func schedule(after: TimeInterval, _ block: @escaping () -> Void) -> Cancellable {
        let timer = Timer.scheduledTimer(withTimeInterval: after, repeats: false) { _ in block() }
        return TimerCancellable(timer: timer)
    }
}

// MARK: - TimerCancellable

struct TimerCancellable: Cancellable {
    let timer: Timer
    func cancel() { timer.invalidate() }
}

