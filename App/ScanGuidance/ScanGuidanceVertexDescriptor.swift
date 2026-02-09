//
// ScanGuidanceVertexDescriptor.swift
// Aether3D
//
// PR#7 Scan Guidance UI — Vertex Descriptor
// Metal vertex layout definition
// Apple-platform only (import Metal)
//

#if canImport(Metal)
import Metal
import simd

/// Vertex descriptor for scan guidance rendering
public struct ScanGuidanceVertexDescriptor {
    
    /// Create Metal vertex descriptor
    public static func create() -> MTLVertexDescriptor {
        let descriptor = MTLVertexDescriptor()
        
        // Attribute 0: position (float3)
        descriptor.attributes[0].format = .float3
        descriptor.attributes[0].offset = 0
        descriptor.attributes[0].bufferIndex = 0
        
        // Attribute 1: normal (float3)
        descriptor.attributes[1].format = .float3
        descriptor.attributes[1].offset = MemoryLayout<Float>.size * 3
        descriptor.attributes[1].bufferIndex = 0
        
        // Attribute 2: metallic (float)
        descriptor.attributes[2].format = .float
        descriptor.attributes[2].offset = MemoryLayout<Float>.size * 6
        descriptor.attributes[2].bufferIndex = 0
        
        // Attribute 3: roughness (float)
        descriptor.attributes[3].format = .float
        descriptor.attributes[3].offset = MemoryLayout<Float>.size * 7
        descriptor.attributes[3].bufferIndex = 0
        
        // Attribute 4: display (float)
        descriptor.attributes[4].format = .float
        descriptor.attributes[4].offset = MemoryLayout<Float>.size * 8
        descriptor.attributes[4].bufferIndex = 0
        
        // Attribute 5: thickness (float)
        descriptor.attributes[5].format = .float
        descriptor.attributes[5].offset = MemoryLayout<Float>.size * 9
        descriptor.attributes[5].bufferIndex = 0
        
        // Attribute 6: triangleId (uint)
        descriptor.attributes[6].format = .uint
        descriptor.attributes[6].offset = MemoryLayout<Float>.size * 10
        descriptor.attributes[6].bufferIndex = 0
        
        // Buffer 0: vertex data
        descriptor.layouts[0].stride = MemoryLayout<Float>.size * 10 + MemoryLayout<UInt32>.size
        descriptor.layouts[0].stepRate = 1
        descriptor.layouts[0].stepFunction = .perVertex
        
        return descriptor
    }
    
    /// Buffer indices
    public enum BufferIndex {
        public static let vertexData = 0
        public static let uniforms = 1
        public static let perTriangleData = 2
    }
}

#endif
