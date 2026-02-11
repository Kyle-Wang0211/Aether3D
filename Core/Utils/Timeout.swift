// SPDX-License-Identifier: LicenseRef-Aether3D-Proprietary
// Copyright (c) 2024-2026 Aether3D. All rights reserved.

//
//  Timeout.swift
//  progect2
//
//  Created by Kaidong Wang on 12/27/25.
//

import Foundation

enum TimeoutError: Error {
    case timeout
}

enum Timeout {
    static func withTimeout<T>(
        seconds: TimeInterval,
        operation: @escaping @Sendable () async throws -> T
    ) async throws -> T {
        try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask {
                try await operation()
            }
            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
                throw TimeoutError.timeout
            }

            guard let result = try await group.next() else {
                throw TimeoutError.timeout
            }
            group.cancelAll()
            return result
        }
    }
}

