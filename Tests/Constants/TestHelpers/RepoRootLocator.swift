// SPDX-License-Identifier: LicenseRef-Aether3D-Proprietary
// Copyright (c) 2024-2026 Aether3D. All rights reserved.

//
// RepoRootLocator.swift
// Aether3D
//
// Utility for locating repository root and resolving file paths.
// Phase 1: macOS CLI only (swift test).
//

import Foundation

/// Locates repository root and resolves file paths.
public enum RepoRootLocator {
    /// Find package root by preferring nearest `Package.swift`.
    /// This avoids resolving to an outer mono-repo `.git` when package is nested.
    public static func findRepoRoot() -> URL? {
        let fileAnchor = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        if let packageRoot = nearestAncestor(containing: "Package.swift", from: fileAnchor) {
            return packageRoot
        }

        let cwdAnchor = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        if let packageRoot = nearestAncestor(containing: "Package.swift", from: cwdAnchor) {
            return packageRoot
        }

        if let gitRoot = gitTopLevel(),
           FileManager.default.fileExists(atPath: gitRoot.appendingPathComponent("Package.swift").path) {
            return gitRoot
        }

        return nil
    }

    private static func nearestAncestor(containing marker: String, from start: URL, maxDepth: Int = 32) -> URL? {
        var current = start.standardizedFileURL
        for _ in 0..<maxDepth {
            let markerPath = current.appendingPathComponent(marker)
            if FileManager.default.fileExists(atPath: markerPath.path) {
                return current
            }

            let parent = current.deletingLastPathComponent()
            if parent.path == current.path {
                break
            }
            current = parent
        }
        return nil
    }

    private static func gitTopLevel() -> URL? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["git", "rev-parse", "--show-toplevel"]

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()

        guard (try? process.run()) != nil else {
            return nil
        }
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            return nil
        }

        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        guard let path = String(data: data, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines),
            !path.isEmpty else {
            return nil
        }
        return URL(fileURLWithPath: path)
    }
    
    /// Resolve a file path relative to repository root
    public static func resolvePath(_ relativePath: String) -> URL? {
        guard let root = findRepoRoot() else {
            return nil
        }
        return root.appendingPathComponent(relativePath)
    }
    
    /// Check if a file exists at the given path
    public static func fileExists(at path: String) -> Bool {
        guard let url = resolvePath(path) else {
            return false
        }
        return FileManager.default.fileExists(atPath: url.path)
    }
    
    /// Get file URL for a relative path
    public static func fileURL(for relativePath: String) throws -> URL {
        guard let url = resolvePath(relativePath) else {
            throw NSError(domain: "RepoRootLocator", code: 1, userInfo: [NSLocalizedDescriptionKey: "Could not resolve path: \(relativePath)"])
        }
        return url
    }
    
    /// Get directory URL for a relative path
    public static func directoryURL(for relativePath: String) throws -> URL {
        return try fileURL(for: relativePath)
    }
}
