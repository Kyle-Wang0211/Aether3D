// SPDX-License-Identifier: LicenseRef-Aether3D-Proprietary
// Copyright (c) 2024-2026 Aether3D. All rights reserved.

//
// FileSecureDeleter.swift
// Aether3D
//
// SecureDataDeleter implementation using multi-pass file overwrite.
// Same 5-pass pattern as SecureDeleteHandler (INV-SEC-062 compliant).
//

import Foundation

/// File-based secure deleter
///
/// Implements the SecureDataDeleter protocol with 5-pass overwrite:
/// 1. All zeros (0x00)
/// 2. All ones (0xFF)
/// 3. Alternating pattern 1 (0x55, 0xAA)
/// 4. Alternating pattern 2 (0xAA, 0x55)
/// 5. Random bytes
///
/// After overwriting, the file is deleted via FileManager.
/// This matches the SecureDeleteHandler pattern in PR5Capture.
public final class FileSecureDeleter: SecureDataDeleter, Sendable {

    public init() {}

    public func secureDelete(at path: URL) async throws -> Bool {
        let fm = FileManager.default

        guard fm.fileExists(atPath: path.path) else {
            // File already gone — treat as success
            return true
        }

        let overwritePatterns: [[UInt8]] = [
            [0x00],
            [0xFF],
            [0x55, 0xAA],
            [0xAA, 0x55],
            // Random pass handled separately
        ]

        do {
            let handle = try FileHandle(forUpdating: path)
            defer { try? handle.close() }

            let attrs = try fm.attributesOfItem(atPath: path.path)
            let fileSize = (attrs[.size] as? Int) ?? 0

            guard fileSize > 0 else {
                // Empty file — just delete
                try fm.removeItem(at: path)
                return true
            }

            // Fixed-pattern passes
            for pattern in overwritePatterns {
                try handle.seek(toOffset: 0)
                var data = Data()
                while data.count < fileSize {
                    data.append(contentsOf: pattern)
                }
                data = data.prefix(fileSize)
                try handle.write(contentsOf: data)
                try handle.synchronize()
            }

            // Random pass
            try handle.seek(toOffset: 0)
            var randomData = Data(count: fileSize)
            randomData.withUnsafeMutableBytes { ptr in
                guard let base = ptr.baseAddress else { return }
                for i in 0..<fileSize {
                    base.storeBytes(of: UInt8.random(in: 0...255), toByteOffset: i, as: UInt8.self)
                }
            }
            try handle.write(contentsOf: randomData)
            try handle.synchronize()

            // Close before delete
            try handle.close()

            // Delete the file
            try fm.removeItem(at: path)
            return true

        } catch {
            return false
        }
    }
}
