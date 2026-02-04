//
// MemoryPressureHandler.swift
// PR5Capture
//
// PR5 v1.8.1 - PART L: 性能预算
// 内存压力处理，低内存响应策略
//

import Foundation

/// Memory pressure handler
///
/// Handles memory pressure with low-memory response strategies.
/// Implements memory pressure monitoring and response.
public actor MemoryPressureHandler {
    
    // MARK: - Configuration
    
    private let config: ExtremeProfile
    
    // MARK: - Pressure Levels
    
    public enum PressureLevel: String, Sendable {
        case normal
        case warning
        case critical
    }
    
    // MARK: - State
    
    /// Current pressure level
    private var currentLevel: PressureLevel = .normal
    
    /// Pressure history
    private var pressureHistory: [(timestamp: Date, level: PressureLevel)] = []
    
    // MARK: - Initialization
    
    public init(config: ExtremeProfile) {
        self.config = config
    }
    
    // MARK: - Pressure Handling
    
    /// Handle memory pressure
    public func handlePressure(_ level: PressureLevel) -> HandlingResult {
        currentLevel = level
        
        // Record pressure event
        pressureHistory.append((timestamp: Date(), level: level))
        
        // Keep only recent history (last 100)
        if pressureHistory.count > 100 {
            pressureHistory.removeFirst()
        }
        
        // Determine response strategy
        let strategy: ResponseStrategy
        switch level {
        case .normal:
            strategy = .none
        case .warning:
            strategy = .reduceCache
        case .critical:
            strategy = .aggressiveCleanup
        }
        
        return HandlingResult(
            level: level,
            strategy: strategy,
            timestamp: Date()
        )
    }
    
    /// Get current pressure level
    public func getCurrentLevel() -> PressureLevel {
        return currentLevel
    }
    
    // MARK: - Result Types
    
    /// Response strategy
    public enum ResponseStrategy: String, Sendable {
        case none
        case reduceCache
        case aggressiveCleanup
    }
    
    /// Handling result
    public struct HandlingResult: Sendable {
        public let level: PressureLevel
        public let strategy: ResponseStrategy
        public let timestamp: Date
    }
}
