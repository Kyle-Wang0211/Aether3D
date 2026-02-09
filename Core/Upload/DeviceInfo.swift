//
//  DeviceInfo.swift
//  Aether3D
//
//  PR#8: Immutable Bundle Format - Device Information
//

import Foundation

#if canImport(Darwin)
import Darwin
#elseif os(Linux)
import Glibc
#endif

/// Cross-platform device metadata snapshot for bundle manifests.
///
/// Captures device information without PII (Personally Identifiable Information).
/// Uses only Foundation + ProcessInfo APIs for cross-platform compatibility.
///
/// **Note**: Renamed from `DeviceInfo` to avoid conflict with `Core/Network/APIContract.DeviceInfo`.
///
/// **Invariants:**
/// - INV-B10: All string fields validated (NUL-free, NFC)
///
/// **Cross-Platform:**
/// - iOS: Uses sysctlbyname for hardware info
/// - macOS: Uses sysctlbyname for hardware info
/// - Linux: Reads /proc/cpuinfo and /proc/meminfo
public struct BundleDeviceInfo: Codable, Sendable, Equatable {
    /// Platform identifier ("iOS", "macOS", "Linux")
    public let platform: String
    
    /// OS version string (from ProcessInfo)
    public let osVersion: String
    
    /// Device model identifier
    public let deviceModel: String
    
    /// CPU architecture ("arm64", "x86_64")
    public let chipArchitecture: String
    
    /// Available physical RAM in MB
    public let availableMemoryMB: Int
    
    /// Thermal state ("nominal", "fair", "serious", "critical", "unknown")
    public let thermalState: String
    
    /// Create device info snapshot for current device.
    ///
    /// **Resilience**: All system calls have fallback values. Never crashes.
    /// Uses safeSysctl() and safeReadProc() helpers for graceful degradation.
    ///
    /// - Returns: BundleDeviceInfo snapshot
    public static func current() -> BundleDeviceInfo {
        #if os(iOS)
        return BundleDeviceInfo(
            platform: "iOS",
            osVersion: ProcessInfo.processInfo.operatingSystemVersionString,
            deviceModel: safeSysctl("hw.model", fallback: "Unknown"),
            chipArchitecture: "arm64",
            availableMemoryMB: safeSysctlInt("hw.memsize", fallback: 4096) / (1024 * 1024),
            thermalState: "nominal" // iOS thermal state requires ProcessInfo.thermalState (iOS 11+)
        )
        #elseif os(macOS)
        let architecture: String
        #if arch(arm64)
        architecture = "arm64"
        #else
        architecture = "x86_64"
        #endif
        
        return BundleDeviceInfo(
            platform: "macOS",
            osVersion: ProcessInfo.processInfo.operatingSystemVersionString,
            deviceModel: safeSysctl("hw.model", fallback: "Unknown"),
            chipArchitecture: architecture,
            availableMemoryMB: safeSysctlInt("hw.memsize", fallback: 8192) / (1024 * 1024),
            thermalState: "nominal"
        )
        #else
        // Linux
        return BundleDeviceInfo(
            platform: "Linux",
            osVersion: safeReadProc("/proc/version", fallback: "Unknown"),
            deviceModel: safeReadProc("/proc/device-tree/model", fallback: "Unknown"),
            chipArchitecture: safeReadProc("/proc/cpuinfo", fallback: "unknown").contains("aarch64") ? "arm64" : "x86_64",
            availableMemoryMB: safeReadProcInt("/proc/meminfo", key: "MemTotal", fallback: 4096),
            thermalState: "unknown"
        )
        #endif
    }
    
    /// Returns a validated copy. Throws if any field contains NUL bytes or non-NFC Unicode.
    ///
    /// **INV-B10**: All string fields validated before entering canonical JSON.
    ///
    /// - Returns: Validated BundleDeviceInfo (same instance if already valid)
    /// - Throws: ArtifactError.stringContainsNullByte or ArtifactError.stringNotNFC
    public func validated() throws -> BundleDeviceInfo {
        try _validateString(platform, field: "platform")
        try _validateString(osVersion, field: "osVersion")
        try _validateString(deviceModel, field: "deviceModel")
        try _validateString(chipArchitecture, field: "chipArchitecture")
        try _validateString(thermalState, field: "thermalState")
        return self // all let properties, already immutable
    }
    
    // MARK: - Private Helpers
    
    /// Safe sysctlbyname wrapper with fallback.
    ///
    /// - Parameters:
    ///   - name: sysctl name (e.g., "hw.model")
    ///   - fallback: Fallback value if sysctl fails
    /// - Returns: sysctl value or fallback
    private static func safeSysctl(_ name: String, fallback: String) -> String {
        #if canImport(Darwin)
        var size: size_t = 0
        sysctlbyname(name, nil, &size, nil, 0)
        guard size > 0 else { return fallback }
        
        var buffer = [CChar](repeating: 0, count: size)
        guard sysctlbyname(name, &buffer, &size, nil, 0) == 0 else {
            return fallback
        }
        
        return String(cString: buffer)
        #else
        return fallback
        #endif
    }
    
    /// Safe sysctlbyname wrapper for integer values.
    ///
    /// - Parameters:
    ///   - name: sysctl name (e.g., "hw.memsize")
    ///   - fallback: Fallback value if sysctl fails
    /// - Returns: sysctl integer value or fallback
    private static func safeSysctlInt(_ name: String, fallback: Int) -> Int {
        #if canImport(Darwin)
        var value: Int64 = 0
        var size = MemoryLayout<Int64>.size
        guard sysctlbyname(name, &value, &size, nil, 0) == 0 else {
            return fallback
        }
        return Int(value)
        #else
        return fallback
        #endif
    }
    
    /// Safe /proc file reader with fallback.
    ///
    /// - Parameters:
    ///   - path: /proc file path
    ///   - fallback: Fallback value if read fails
    /// - Returns: File contents or fallback
    private static func safeReadProc(_ path: String, fallback: String) -> String {
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
              let content = String(data: data, encoding: .utf8) else {
            return fallback
        }
        return content.trimmingCharacters(in: .whitespacesAndNewlines)
    }
    
    /// Safe /proc/meminfo reader for specific key.
    ///
    /// - Parameters:
    ///   - path: /proc/meminfo path
    ///   - key: Key to extract (e.g., "MemTotal")
    ///   - fallback: Fallback value if read/parse fails
    /// - Returns: Integer value in KB (converted to MB)
    private static func safeReadProcInt(_ path: String, key: String, fallback: Int) -> Int {
        guard let content = try? String(contentsOfFile: path) else {
            return fallback
        }
        
        for line in content.components(separatedBy: .newlines) {
            if line.hasPrefix(key) {
                let parts = line.split(separator: ":", maxSplits: 1)
                if parts.count == 2 {
                    let valuePart = parts[1].trimmingCharacters(in: .whitespaces)
                    let kbParts = valuePart.split(separator: " ", maxSplits: 1)
                    if let kbValue = Int(kbParts[0]) {
                        return kbValue / 1024 // Convert KB to MB
                    }
                }
            }
        }
        
        return fallback
    }
}
