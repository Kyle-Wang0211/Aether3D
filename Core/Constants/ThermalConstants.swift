// SPDX-License-Identifier: LicenseRef-Aether3D-Proprietary
// Copyright (c) 2024-2026 Aether3D. All rights reserved.

//
// ThermalConstants.swift
// Aether3D
//
// Thermal Management Constants - iPhone 17 Pro vapor chamber specifications
// 符合 PR1-03: Thermal Management Constants
//

import Foundation

/// Thermal Management Constants
///
/// Based on iPhone 17 Pro vapor chamber research.
/// All temperatures in Celsius.
public enum ThermalConstants {
    
    // MARK: - Temperature Thresholds
    
    /// Safe ambient temperature maximum (Celsius)
    /// Unit: degrees Celsius
    /// Based on iPhone 17 Pro vapor chamber specifications
    public static let thermalSafeAmbientMaxC: Double = 35.0
    
    /// Thermal warning threshold (Celsius)
    /// Unit: degrees Celsius
    /// Device enters warning state above this temperature
    public static let thermalWarningC: Double = 40.0
    
    /// Thermal critical threshold (Celsius)
    /// Unit: degrees Celsius
    /// Device enters critical state above this temperature
    public static let thermalCriticalC: Double = 45.0
    
    /// Thermal shutdown threshold (Celsius)
    /// Unit: degrees Celsius
    /// Device shuts down above this temperature
    public static let thermalShutdownC: Double = 50.0
    
    // MARK: - Recording Limits
    
    /// Maximum continuous 4K60 recording duration (seconds)
    /// Unit: seconds
    /// Based on iPhone 17 Pro thermal limits
    public static let max4K60ContinuousSeconds: Int = 1800 // 30 minutes
    
    /// Maximum continuous ProRes recording duration (seconds)
    /// Unit: seconds
    /// Based on iPhone 17 Pro thermal limits
    public static let maxProResContinuousSeconds: Int = 900 // 15 minutes
    
    /// Thermal cooldown period (seconds)
    /// Unit: seconds
    /// Minimum time required for device to cool down after thermal warning
    public static let thermalCooldownSeconds: Int = 120 // 2 minutes
    
    // MARK: - Specifications
    
    /// Specification for thermalSafeAmbientMaxC
    private static let thermalSafeAmbientMaxCSpec = ThermalSpec(
        ssotId: "ThermalConstants.thermalSafeAmbientMaxC",
        name: "Thermal Safe Ambient Maximum",
        unit: SSOTUnit.celsius,
        value: thermalSafeAmbientMaxC,
        documentation: "Safe ambient temperature maximum based on iPhone 17 Pro vapor chamber specifications"
    )
    
    /// Specification for thermalWarningC
    private static let thermalWarningCSpec = ThermalSpec(
        ssotId: "ThermalConstants.thermalWarningC",
        name: "Thermal Warning Threshold",
        unit: SSOTUnit.celsius,
        value: thermalWarningC,
        documentation: "Thermal warning threshold - device enters warning state above this temperature"
    )
    
    /// Specification for thermalCriticalC
    private static let thermalCriticalCSpec = ThermalSpec(
        ssotId: "ThermalConstants.thermalCriticalC",
        name: "Thermal Critical Threshold",
        unit: SSOTUnit.celsius,
        value: thermalCriticalC,
        documentation: "Thermal critical threshold - device enters critical state above this temperature"
    )
    
    /// Specification for thermalShutdownC
    private static let thermalShutdownCSpec = ThermalSpec(
        ssotId: "ThermalConstants.thermalShutdownC",
        name: "Thermal Shutdown Threshold",
        unit: SSOTUnit.celsius,
        value: thermalShutdownC,
        documentation: "Thermal shutdown threshold - device shuts down above this temperature"
    )
    
    /// Specification for max4K60ContinuousSeconds
    private static let max4K60ContinuousSecondsSpec = ThermalSpec(
        ssotId: "ThermalConstants.max4K60ContinuousSeconds",
        name: "Maximum 4K60 Continuous Recording Duration",
        unit: .seconds,
        value: Double(max4K60ContinuousSeconds),
        documentation: "Maximum continuous 4K60 recording duration based on iPhone 17 Pro thermal limits"
    )
    
    /// Specification for maxProResContinuousSeconds
    private static let maxProResContinuousSecondsSpec = ThermalSpec(
        ssotId: "ThermalConstants.maxProResContinuousSeconds",
        name: "Maximum ProRes Continuous Recording Duration",
        unit: .seconds,
        value: Double(maxProResContinuousSeconds),
        documentation: "Maximum continuous ProRes recording duration based on iPhone 17 Pro thermal limits"
    )
    
    /// Specification for thermalCooldownSeconds
    private static let thermalCooldownSecondsSpec = ThermalSpec(
        ssotId: "ThermalConstants.thermalCooldownSeconds",
        name: "Thermal Cooldown Period",
        unit: .seconds,
        value: Double(thermalCooldownSeconds),
        documentation: "Minimum time required for device to cool down after thermal warning"
    )
    
    /// All thermal constant specs
    public static let allSpecs: [AnyConstantSpec] = [
        .systemConstant(SystemConstantSpec(
            ssotId: thermalSafeAmbientMaxCSpec.ssotId,
            name: thermalSafeAmbientMaxCSpec.name,
            unit: thermalSafeAmbientMaxCSpec.unit,
            value: Int(thermalSafeAmbientMaxCSpec.value),
            documentation: thermalSafeAmbientMaxCSpec.documentation
        )),
        .systemConstant(SystemConstantSpec(
            ssotId: thermalWarningCSpec.ssotId,
            name: thermalWarningCSpec.name,
            unit: thermalWarningCSpec.unit,
            value: Int(thermalWarningCSpec.value),
            documentation: thermalWarningCSpec.documentation
        )),
        .systemConstant(SystemConstantSpec(
            ssotId: thermalCriticalCSpec.ssotId,
            name: thermalCriticalCSpec.name,
            unit: thermalCriticalCSpec.unit,
            value: Int(thermalCriticalCSpec.value),
            documentation: thermalCriticalCSpec.documentation
        )),
        .systemConstant(SystemConstantSpec(
            ssotId: thermalShutdownCSpec.ssotId,
            name: thermalShutdownCSpec.name,
            unit: thermalShutdownCSpec.unit,
            value: Int(thermalShutdownCSpec.value),
            documentation: thermalShutdownCSpec.documentation
        )),
        .systemConstant(SystemConstantSpec(
            ssotId: max4K60ContinuousSecondsSpec.ssotId,
            name: max4K60ContinuousSecondsSpec.name,
            unit: max4K60ContinuousSecondsSpec.unit,
            value: max4K60ContinuousSeconds,
            documentation: max4K60ContinuousSecondsSpec.documentation
        )),
        .systemConstant(SystemConstantSpec(
            ssotId: maxProResContinuousSecondsSpec.ssotId,
            name: maxProResContinuousSecondsSpec.name,
            unit: maxProResContinuousSecondsSpec.unit,
            value: maxProResContinuousSeconds,
            documentation: maxProResContinuousSecondsSpec.documentation
        )),
        .systemConstant(SystemConstantSpec(
            ssotId: thermalCooldownSecondsSpec.ssotId,
            name: thermalCooldownSecondsSpec.name,
            unit: thermalCooldownSecondsSpec.unit,
            value: thermalCooldownSeconds,
            documentation: thermalCooldownSecondsSpec.documentation
        ))
    ]
    
    // MARK: - Validation
    
    /// Validate thermal constant relationships
    public static func validateRelationships() -> [String] {
        var errors: [String] = []
        
        if thermalSafeAmbientMaxC >= thermalWarningC {
            errors.append("thermalSafeAmbientMaxC (\(thermalSafeAmbientMaxC)) >= thermalWarningC (\(thermalWarningC))")
        }
        
        if thermalWarningC >= thermalCriticalC {
            errors.append("thermalWarningC (\(thermalWarningC)) >= thermalCriticalC (\(thermalCriticalC))")
        }
        
        if thermalCriticalC >= thermalShutdownC {
            errors.append("thermalCriticalC (\(thermalCriticalC)) >= thermalShutdownC (\(thermalShutdownC))")
        }
        
        return errors
    }
}

// Unit types are defined in SSOTTypes.swift (SSOTUnit)

// MARK: - Specification Types

/// Thermal specification (internal)
private struct ThermalSpec {
    let ssotId: String
    let name: String
    let unit: SSOTUnit
    let value: Double
    let documentation: String
}
