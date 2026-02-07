//
// ThermalMonitor.swift
// Aether3D
//
// Thermal Monitor - iPhone 17 Pro vapor chamber-aware thermal management
// 符合 PR4-03: Thermal-Aware Recording
//

import Foundation
#if canImport(IOKit)
import IOKit
#endif

/// Thermal Monitor
///
/// Monitors device thermal state and manages recording based on thermal limits.
/// 符合 PR4-03: Thermal-Aware Recording
public actor ThermalMonitor {
    
    // MARK: - State

    private var currentTemperature: Double?
    private var thermalState: ThermalState = .normal
    private var monitoringTask: Task<Void, Never>?
    private var isMonitoring: Bool = false
    
    // MARK: - Configuration
    
    /// Thermal thresholds (from ThermalConstants)
    private let warningThreshold = ThermalConstants.thermalWarningC
    private let criticalThreshold = ThermalConstants.thermalCriticalC
    private let shutdownThreshold = ThermalConstants.thermalShutdownC
    
    /// Monitoring interval (seconds)
    private let monitoringInterval: TimeInterval = 5.0
    
    // MARK: - Callbacks
    
    /// Callback for thermal state changes
    public var onThermalStateChange: ((ThermalState) -> Void)?
    
    /// Callback for critical thermal shutdown
    public var onCriticalShutdown: (() -> Void)?
    
    // MARK: - Monitoring
    
    /// Start thermal monitoring
    /// 
    /// 符合 PR4-03: Thermal monitoring every 5 seconds during recording
    public func startMonitoring() {
        guard !isMonitoring else {
            return
        }

        isMonitoring = true

        // Start periodic monitoring using Task-based loop (符合 Swift 6 concurrency)
        monitoringTask = Task { [weak self] in
            // Initial check
            await self?.checkThermalState()

            // Periodic monitoring loop
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(self?.monitoringInterval ?? 5.0))
                guard !Task.isCancelled else { break }
                await self?.checkThermalState()
            }
        }
    }
    
    /// Stop thermal monitoring
    public func stopMonitoring() {
        isMonitoring = false
        monitoringTask?.cancel()
        monitoringTask = nil
    }
    
    /// Check thermal state
    private func checkThermalState() async {
        // Get current thermal state from system
        let newState = await getSystemThermalState()
        
        if newState != thermalState {
            thermalState = newState
            onThermalStateChange?(thermalState)
            
            // Handle critical shutdown
            if thermalState == .critical {
                onCriticalShutdown?()
            }
        }
    }
    
    /// Get system thermal state
    /// 
    /// - Returns: Current thermal state
    private func getSystemThermalState() async -> ThermalState {
        // In production, use IOKit to get actual thermal state
        // For now, use ProcessInfo thermal state as approximation
        #if os(iOS)
        let processInfo = ProcessInfo.processInfo
        let state = processInfo.thermalState
        
        switch state {
        case .nominal:
            return .normal
        case .fair:
            return .warning
        case .serious:
            return .critical
        case .critical:
            return .shutdown
        @unknown default:
            return .normal
        }
        #else
        return .normal
        #endif
    }
    
    /// Get current thermal state
    /// 
    /// - Returns: Current thermal state
    public func getCurrentState() -> ThermalState {
        return thermalState
    }
    
    /// Check if recording should continue
    /// 
    /// 符合 PR4-03: Auto-stop on critical thermal (45°C)
    /// - Returns: True if recording should continue
    public func shouldContinueRecording() -> Bool {
        return thermalState != .critical && thermalState != .shutdown
    }
}

/// Thermal State
public enum ThermalState: Sendable {
    case normal
    case warning
    case critical
    case shutdown
    
    /// Check if state requires action
    public var requiresAction: Bool {
        switch self {
        case .normal:
            return false
        case .warning:
            return true
        case .critical:
            return true
        case .shutdown:
            return true
        }
    }
}
