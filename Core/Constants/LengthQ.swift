//
// LengthQ.swift
// Aether3D
//
// PR#1 Ultra-Granular Capture - Fixed-point length type with multi-scale support
//
// P3: LengthQ must support multiple quantization scales
// All length-related SSOT values MUST use LengthQ (no Double/Float in identity)
//

import Foundation

// MARK: - Length Scale (Closed Set)

/// Length quantization scale (append-only closed set)
public enum LengthScale: UInt8, Codable, CaseIterable {
    case geomId = 1        // 1mm (cross-epoch stable)
    case patchId = 2       // 0.1mm (epoch-local precise)
    case systemMinimum = 3 // 0.05mm or 0.1mm (system minimum representable)
    
    /// Quantum in nanometers (for internal storage)
    /// Using nanometers as base unit to avoid floating point
    public var quantumInNanometers: Int64 {
        switch self {
        case .geomId:
            return 1_000_000  // 1mm = 1e6 nm
        case .patchId:
            return 100_000     // 0.1mm = 1e5 nm
        case .systemMinimum:
            return 50_000      // 0.05mm = 5e4 nm
        }
    }
    
    /// Human-readable description
    public var description: String {
        switch self {
        case .geomId:
            return "1mm (geomId scale)"
        case .patchId:
            return "0.1mm (patchId scale)"
        case .systemMinimum:
            return "0.05mm (system minimum)"
        }
    }
}

// MARK: - LengthQ (Fixed-Point Length)

/// Fixed-point length type backed by Int64
/// 
/// **Rule:** NO FLOATS IN IDENTITY
/// - All length-related SSOT values MUST use LengthQ
/// - Double/Float is FORBIDDEN in any identity/digest/key inputs
/// - If display needs Double, derive from LengthQ and NEVER use in hashing
public struct LengthQ: Codable, Hashable {
    /// Scale identifier (closed set)
    public let scaleId: LengthScale
    
    /// Number of quanta (Int64)
    public let quanta: Int64
    
    /// Initialize with scale and quanta
    public init(scaleId: LengthScale, quanta: Int64) {
        self.scaleId = scaleId
        self.quanta = quanta
    }
    
    /// Create from meters (quantizes to nearest quantum)
    /// **Note:** This is for input conversion only. Display conversion should use toMeters().
    public static func fromMeters(_ meters: Double, scale: LengthScale) -> LengthQ {
        let quantumInMeters = Double(scale.quantumInNanometers) / 1e9
        let quanta = Int64(round(meters / quantumInMeters))
        return LengthQ(scaleId: scale, quanta: quanta)
    }
    
    /// Convert to meters (for display only, never for identity/hashing)
    /// **Warning:** This returns Double. Use ONLY for UI display, never in digest/identity logic.
    public func toMeters() -> Double {
        let quantumInMeters = Double(scaleId.quantumInNanometers) / 1e9
        return Double(quanta) * quantumInMeters
    }
    
    /// Convert to millimeters (for display only)
    public func toMillimeters() -> Double {
        return toMeters() * 1000.0
    }
    
    // MARK: - Codable (for digest input)
    
    /// Digest input structure (scaleId + quanta, no floats)
    public struct DigestInput: Codable {
        public let scaleId: UInt8
        public let quanta: Int64
        
        public init(scaleId: UInt8, quanta: Int64) {
            self.scaleId = scaleId
            self.quanta = quanta
        }
    }
    
    /// Get digest input (for canonical digest computation)
    public func digestInput() -> DigestInput {
        return DigestInput(scaleId: scaleId.rawValue, quanta: quanta)
    }
}

// MARK: - LengthQ Constants

/// Predefined LengthQ values for common use cases
public enum LengthQConstants {
    /// 0.25mm in system minimum scale
    public static let quarterMillimeter = LengthQ(scaleId: .systemMinimum, quanta: 5)  // 5 * 0.05mm = 0.25mm
    
    /// 0.5mm in system minimum scale
    public static let halfMillimeter = LengthQ(scaleId: .systemMinimum, quanta: 10)  // 10 * 0.05mm = 0.5mm
    
    /// 1mm in geomId scale
    public static let oneMillimeter = LengthQ(scaleId: .geomId, quanta: 1)  // 1 * 1mm = 1mm
    
    /// 2mm in geomId scale
    public static let twoMillimeters = LengthQ(scaleId: .geomId, quanta: 2)
    
    /// 5mm in geomId scale
    public static let fiveMillimeters = LengthQ(scaleId: .geomId, quanta: 5)
    
    /// 1cm in geomId scale
    public static let oneCentimeter = LengthQ(scaleId: .geomId, quanta: 10)  // 10 * 1mm = 1cm
    
    /// 2cm in geomId scale
    public static let twoCentimeters = LengthQ(scaleId: .geomId, quanta: 20)
    
    /// 5cm in geomId scale
    public static let fiveCentimeters = LengthQ(scaleId: .geomId, quanta: 50)
}

// MARK: - Equatable

extension LengthQ: Equatable {
    public static func == (lhs: LengthQ, rhs: LengthQ) -> Bool {
        // Convert both to same scale (use finer scale) and compare quanta
        let finerScale = lhs.scaleId.quantumInNanometers < rhs.scaleId.quantumInNanometers ? lhs.scaleId : rhs.scaleId
        let lhsQuanta = convertQuanta(lhs.quanta, from: lhs.scaleId, to: finerScale)
        let rhsQuanta = convertQuanta(rhs.quanta, from: rhs.scaleId, to: finerScale)
        return lhsQuanta == rhsQuanta
    }
}

// MARK: - Comparison Operators

extension LengthQ: Comparable {
    public static func < (lhs: LengthQ, rhs: LengthQ) -> Bool {
        // Convert both to same scale (use finer scale)
        let finerScale = lhs.scaleId.quantumInNanometers < rhs.scaleId.quantumInNanometers ? lhs.scaleId : rhs.scaleId
        let lhsQuanta = convertQuanta(lhs.quanta, from: lhs.scaleId, to: finerScale)
        let rhsQuanta = convertQuanta(rhs.quanta, from: rhs.scaleId, to: finerScale)
        return lhsQuanta < rhsQuanta
    }
}

// MARK: - Arithmetic (for internal calculations only)

extension LengthQ {
    /// Add two LengthQ values (converts to finer scale)
    /// **Warning:** Use only for internal calculations, not for identity
    public static func + (lhs: LengthQ, rhs: LengthQ) -> LengthQ {
        let finerScale = lhs.scaleId.quantumInNanometers < rhs.scaleId.quantumInNanometers ? lhs.scaleId : rhs.scaleId
        let lhsQuanta = convertQuanta(lhs.quanta, from: lhs.scaleId, to: finerScale)
        let rhsQuanta = convertQuanta(rhs.quanta, from: rhs.scaleId, to: finerScale)
        return LengthQ(scaleId: finerScale, quanta: lhsQuanta + rhsQuanta)
    }
    
    /// Convert quanta from one scale to another
    private static func convertQuanta(_ quanta: Int64, from: LengthScale, to: LengthScale) -> Int64 {
        if from == to {
            return quanta
        }
        // Convert via nanometers
        let fromNanometers = quanta * from.quantumInNanometers
        return fromNanometers / to.quantumInNanometers
    }
}
