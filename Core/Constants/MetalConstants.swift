//
// MetalConstants.swift
// Aether3D
//
// Metal GPU pipeline constants for TSDF integration and rendering.
//

import Foundation

/// Metal GPU Pipeline Constants
///
/// Constants for Metal compute and render pipeline configuration.
/// Referenced by TSDFConstants for GPU buffer management.
public enum MetalConstants {

    // MARK: - Buffer Management

    /// Number of inflight Metal command buffers for triple-buffering
    /// Unit: count
    /// Triple-buffering allows GPU and CPU to work in parallel
    public static let inflightBufferCount: Int = 3

    // MARK: - Compute Pipeline

    /// Default Metal threadgroup size for compute shaders
    /// Unit: threads per dimension
    /// 8×8×8 = 512 threads per threadgroup (within Metal limits)
    public static let defaultThreadgroupSize: Int = 8
}
