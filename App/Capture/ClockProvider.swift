// SPDX-License-Identifier: LicenseRef-Aether3D-Proprietary
// Copyright (c) 2024-2026 Aether3D. All rights reserved.

//
//  ClockProvider.swift
//  progect2
//
//  Created for PR#4 Capture Recording
//
//  CI-HARDENED: This file is the ONLY allowed location for Date() usage in App/Capture.
//  DefaultClockProvider implementation uses Date() to provide system time.

import Foundation

// MARK: - ClockProvider Protocol

protocol ClockProvider {
    func now() -> Date
}

// MARK: - Default Implementation

struct DefaultClockProvider: ClockProvider {
    func now() -> Date { Date() }
}

