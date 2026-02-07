//
// FaultInjector.swift
// Aether3D
//
// Fault Injector - Deterministic fault injection for testing
// 符合 Phase 4: Deterministic Replay Engine
//

import Foundation

/// Fault Type
///
/// Type of fault to inject.
public enum FaultType: Sendable {
    case networkError
    case timeout
    case diskFull
    case permissionDenied
    case corruption
}

/// Fault Injector
///
/// Injects deterministic faults for testing.
/// 符合 Phase 4: Deterministic Replay Engine
public actor FaultInjector {
    
    // MARK: - State
    
    private var enabledFaults: Set<FaultType> = []
    private let scheduler: DeterministicScheduler
    
    // MARK: - Initialization
    
    /// Initialize Fault Injector
    /// 
    /// - Parameter scheduler: Deterministic scheduler
    public init(scheduler: DeterministicScheduler) {
        self.scheduler = scheduler
    }
    
    // MARK: - Fault Injection
    
    /// Enable fault type
    /// 
    /// - Parameter faultType: Fault type to enable
    public func enableFault(_ faultType: FaultType) {
        enabledFaults.insert(faultType)
    }
    
    /// Disable fault type
    /// 
    /// - Parameter faultType: Fault type to disable
    public func disableFault(_ faultType: FaultType) {
        enabledFaults.remove(faultType)
    }
    
    /// Check if fault should be injected
    /// 
    /// - Parameter faultType: Fault type to check
    /// - Returns: True if fault should be injected
    public func shouldInject(_ faultType: FaultType) async -> Bool {
        guard enabledFaults.contains(faultType) else {
            return false
        }
        
        // Use deterministic randomness to decide
        let random = await scheduler.random()
        return (random % 100) < 10 // 10% chance
    }
    
    /// Inject fault if enabled
    /// 
    /// - Parameter faultType: Fault type
    /// - Throws: Error if fault is injected
    public func injectIfEnabled(_ faultType: FaultType) async throws {
        if await shouldInject(faultType) {
            throw FaultInjectionError.faultInjected(faultType)
        }
    }
}

/// Fault Injection Error
public enum FaultInjectionError: Error, Sendable {
    case faultInjected(FaultType)
    
    public var localizedDescription: String {
        switch self {
        case .faultInjected(let type):
            return "Fault injected: \(type)"
        }
    }
}
