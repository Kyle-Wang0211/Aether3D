//
//  QualityLogger.swift
//  Aether3D
//
//  PR#5 Quality Pre-check - Milestone 8
//  QualityLogger - two-layer logging system (Compact + Full, PART 9)
//

import Foundation

/// QualityLogger - two-layer logging system
public class QualityLogger {
    private var compactSnapshots: [CompactSnapshot] = []
    private var fullLogs: [String] = []  // Optional, debug mode only
    
    public init() {}
    
    /// Log compact snapshot (only on state changes)
    public func logCompactSnapshot(_ snapshot: CompactSnapshot) {
        compactSnapshots.append(snapshot)
    }
    
    /// Log full log entry (optional, debug mode)
    public func logFull(_ entry: String) {
        // Only in debug mode
        #if DEBUG
        fullLogs.append(entry)
        #endif
    }
    
    /// Get all compact snapshots
    public func getCompactSnapshots() -> [CompactSnapshot] {
        return compactSnapshots
    }
}

