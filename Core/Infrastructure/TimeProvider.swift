// SPDX-License-Identifier: LicenseRef-Aether3D-Proprietary
// Copyright (c) 2024-2026 Aether3D. All rights reserved.

//
// TimeProvider.swift
// Aether3D
//
// Abstraction for time access to enable deterministic testing.
// Direct Date() usage outside this file is prohibited.
//

import Foundation

/// Protocol for providing the current time.
public protocol TimeProvider {
    func now() -> Date
}

/// System time provider (uses Date()).
public struct SystemTimeProvider: TimeProvider {
    public init() {}
    
    public func now() -> Date {
        return Date()
    }
}

/// Test time provider (uses a fixed date).
public struct TestTimeProvider: TimeProvider {
    private let fixedDate: Date
    
    public init(fixedDate: Date) {
        self.fixedDate = fixedDate
    }
    
    public func now() -> Date {
        return fixedDate
    }
}

/// Global time provider instance.
/// Defaults to SystemTimeProvider, but can be overridden for testing.
public var globalTimeProvider: TimeProvider = SystemTimeProvider()

/// Get the current time using the global time provider.
/// Use this instead of Date() for deterministic testing.
public func currentTime() -> Date {
    return globalTimeProvider.now()
}

