//
//  RepoRootLocator.swift
//  Aether3D
//
//  Utility for locating repository root and resolving file paths.
//  CI-HARDENED: Foundation-only, platform-agnostic implementation.
//

import Foundation

/// Locates repository root and resolves file paths.
public enum RepoRootLocator {
    /// Find repository root by looking for .git directory, Package.swift, or README.md
    public static func findRepoRoot() -> URL? {
        // Use #filePath to get current file location, then walk up
        let currentFile = URL(fileURLWithPath: #filePath)
        var currentDir = currentFile.deletingLastPathComponent()
        
        // Limit search depth
        let maxDepth = 20
        var depth = 0
        
        // Closed set of markers that indicate repo root
        let markers = [".git", "Package.swift", "README.md"]
        
        while depth < maxDepth {
            // Check for any marker
            var foundMarker = false
            for marker in markers {
                let markerPath = currentDir.appendingPathComponent(marker)
                if FileManager.default.fileExists(atPath: markerPath.path) {
                    foundMarker = true
                    break
                }
            }
            
            if foundMarker {
                return currentDir
            }
            
            let parent = currentDir.deletingLastPathComponent()
            
            // Prevent infinite loop (reached filesystem root)
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
}


