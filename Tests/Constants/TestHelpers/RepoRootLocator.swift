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
    /// Find repository root by looking for .git directory or Package.swift
    public static func findRepoRoot() -> URL? {
        var currentDir = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        
        // Limit search depth
        let maxDepth = 20
        var depth = 0
        
        while depth < maxDepth {
            let gitDir = currentDir.appendingPathComponent(".git")
            let packageFile = currentDir.appendingPathComponent("Package.swift")
            
            if FileManager.default.fileExists(atPath: gitDir.path) ||
               FileManager.default.fileExists(atPath: packageFile.path) {
                return currentDir
            }
            
            guard let parent = currentDir.deletingLastPathComponent().path.isEmpty ? nil : currentDir.deletingLastPathComponent() else {
                break
            }
            
            // Prevent infinite loop
            if parent.path == currentDir.path {
                break
            }
            
            currentDir = parent
            depth += 1
        }
        
        return nil
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

