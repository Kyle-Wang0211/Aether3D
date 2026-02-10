// SPDX-License-Identifier: LicenseRef-Aether3D-Proprietary
// CONSTITUTIONAL CONTRACT - DO NOT EDIT WITHOUT RFC
// Contract Version: PR9-RESOURCE-1.0
// Module: Upload Infrastructure - Unified Resource Manager
// Cross-Platform: macOS + Linux (pure Foundation)

import Foundation

/// Resource manager protocol.
public protocol ResourceManager: Sendable {
    func getThermalBudget() async -> ThermalBudget
    func getMemoryAvailable() async -> UInt64
    func getBatteryLevel() async -> Double?
    func shouldPauseUpload() async -> Bool
}

/// Thermal budget.
public enum ThermalBudget: Sendable {
    case unrestricted
    case reduced(Double)  // 0.0-1.0
}

/// Memory strategy.
public enum MemoryStrategy: Sendable {
    case full(buffers: Int)
    case reduced(buffers: Int)
    case minimal(buffers: Int)
    case emergency(buffers: Int)
}

/// Unified resource manager with NO throttling.
///
/// **CORE PRINCIPLE**: Upload speed is SACRED. We NEVER throttle.
///
/// **Key Features**:
/// - Upload budget: ALWAYS 100%. No exceptions.
/// - No thermal throttling. No battery throttling. No power throttling.
/// - User has charger and cooling. Our job: fastest possible upload.
/// - Memory management: reduce buffers but keep uploading.
/// - Minimum 2 buffers always available.
public actor UnifiedResourceManager: ResourceManager {
    
    // MARK: - ResourceManager Protocol
    
    /// Get thermal budget: ALWAYS unrestricted.
    public func getThermalBudget() -> ThermalBudget {
        return .unrestricted
    }
    
    /// Get available memory.
    public func getMemoryAvailable() -> UInt64 {
        #if canImport(Darwin)
        #if os(iOS) || os(tvOS) || os(watchOS)
        if #available(iOS 13.0, tvOS 13.0, watchOS 6.0, *) {
            return UInt64(os_proc_available_memory())
        }
        #endif
        // macOS: return conservative estimate
        return 200_000_000  // Assume 200MB available on macOS
        #endif
        return 100_000_000  // Linux fallback
    }
    
    /// Get battery level: Returns nil (we don't care).
    public func getBatteryLevel() -> Double? {
        return nil  // We don't care about battery
    }
    
    /// Should pause upload: ALWAYS false.
    public func shouldPauseUpload() -> Bool {
        return false  // NEVER pause
    }
    
    // MARK: - Upload Budget
    
    /// Get upload budget: ALWAYS 100%.
    ///
    /// No thermal throttling. No battery throttling. No power throttling.
    /// User has charger and cooling. Our job: fastest possible upload.
    public func getUploadBudget() -> Double {
        return 1.0  // ALWAYS 100%
    }
    
    // MARK: - Memory Management
    
    /// Get memory strategy: reduce buffers but keep uploading.
    ///
    /// Minimum 2 buffers always available.
    public func getMemoryStrategy() -> MemoryStrategy {
        let available = getMemoryAvailable()
        
        switch available {
        case 200_000_000...:    // ≥200MB
            return .full(buffers: 12)
        case 100_000_000...:    // 100-200MB
            return .reduced(buffers: 8)
        case 50_000_000...:     // 50-100MB
            return .minimal(buffers: 4)
        default:                // <50MB
            return .emergency(buffers: 2)  // NEVER below 2
        }
    }
}
