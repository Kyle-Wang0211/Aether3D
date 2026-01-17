//
//  CodableVector.swift
//  Aether3D
//
//  PR#5 Quality Pre-check - Milestone 0
//  CodableVector - Codable replacement for CGVector (PART 9.2)
//

import Foundation

/// CodableVector - Codable replacement for CGVector
/// Used in audit records and serialization
public struct CodableVector: Codable, Equatable {
    public let dx: Double
    public let dy: Double
    
    public init(dx: Double, dy: Double) {
        self.dx = dx
        self.dy = dy
    }
    
    public init(from cgVector: CGVector) {
        self.dx = Double(cgVector.dx)
        self.dy = Double(cgVector.dy)
    }
    
    public func toCGVector() -> CGVector {
        return CGVector(dx: CGFloat(dx), dy: CGFloat(dy))
    }
}

