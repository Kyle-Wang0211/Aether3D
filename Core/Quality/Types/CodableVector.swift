//
//  CodableVector.swift
//  Aether3D
//
//  PR#5 Quality Pre-check - Milestone 0
//  CodableVector - Codable replacement for CGVector (PART 9.2)
//

import Foundation
#if canImport(CoreGraphics)
import CoreGraphics
#endif

/// CodableVector - Codable replacement for CGVector
/// Used in audit records and serialization
/// Cross-platform: CGVector conversion available only on Apple platforms
public struct CodableVector: Codable, Equatable {
    public let dx: Double
    public let dy: Double
    
    public init(dx: Double, dy: Double) {
        self.dx = dx
        self.dy = dy
    }
    
    #if canImport(CoreGraphics)
    /// Initialize from CGVector (Apple platforms only)
    public init(from cgVector: CGVector) {
        self.dx = Double(cgVector.dx)
        self.dy = Double(cgVector.dy)
    }
    
    /// Convert to CGVector (Apple platforms only)
    public func toCGVector() -> CGVector {
        return CGVector(dx: CGFloat(dx), dy: CGFloat(dy))
    }
    #endif
}

