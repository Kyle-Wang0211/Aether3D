// SPDX-License-Identifier: LicenseRef-Aether3D-Proprietary
// Copyright (c) 2024-2026 Aether3D. All rights reserved.

//
// OverflowReporter.swift
// PR4Overflow
//
// PR4 V10 - Pillar 33: Rate-limited overflow logging
//

import Foundation

/// Overflow reporter for structured logging
///
/// V8 RULE: Rate-limited logging to prevent log spam.
final public class OverflowReporter {
    public static let shared = OverflowReporter()
    
    private var events: [OverflowDetectionFramework.OverflowEvent] = []
    private let lock = NSLock()
    private var tier0Count = 0
    private var tier1Count = 0
    private var lastLogTime: Date = Date()
    private let minLogInterval: TimeInterval = 1.0  // Minimum 1 second between logs
    
    private init() {}
    
    public func report(_ event: OverflowDetectionFramework.OverflowEvent) {
        lock.lock()
        defer { lock.unlock() }
        
        events.append(event)
        
        let now = Date()
        let timeSinceLastLog = now.timeIntervalSince(lastLogTime)
        
        switch event.tier {
        case .tier0:
            tier0Count += 1
            // Always log Tier0
            print("🛑 TIER0 OVERFLOW #\(tier0Count): \(event.field) (\(event.operation))")
            lastLogTime = now
            
        case .tier1:
            tier1Count += 1
            // Rate-limited logging
            if tier1Count <= 10 || (timeSinceLastLog >= minLogInterval && tier1Count % 100 == 0) {
                print("⚠️ TIER1 overflow #\(tier1Count): \(event.field)")
                lastLogTime = now
            }
            
        case .tier2:
            // Silent
            break
        }
    }
    
    /// Export all events for analysis
    public func exportEvents() -> [OverflowDetectionFramework.OverflowEvent] {
        lock.lock()
        defer { lock.unlock() }
        return events
    }
    
    /// Get summary statistics
    public func getSummary() -> (tier0: Int, tier1: Int, total: Int) {
        lock.lock()
        defer { lock.unlock() }
        return (tier0: tier0Count, tier1: tier1Count, total: events.count)
    }
    
    /// Reset counters
    public func reset() {
        lock.lock()
        defer { lock.unlock() }
        events.removeAll()
        tier0Count = 0
        tier1Count = 0
        lastLogTime = Date()
    }
}
