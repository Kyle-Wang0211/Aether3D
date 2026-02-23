// SPDX-License-Identifier: LicenseRef-Aether3D-Proprietary
// Copyright (c) 2024-2026 Aether3D. All rights reserved.

//
// MetalBufferPool.swift
// Aether3D
//
// Triple-buffered per-frame data + semaphore management

import Metal
import Foundation

/// Triple-buffered Metal buffer pool for per-frame data
///
/// Manages triple-buffering pattern for Metal resources that are updated every frame:
/// - Parameter buffers (TSDFParams, camera matrices)
/// - Depth textures (via CVMetalTextureCache)
/// - Other per-frame GPU data
///
/// Uses DispatchSemaphore for CPU-GPU synchronization (industry standard pattern).
/// Guardrail #21: Semaphore deadlock protection via timeout.
public final class MetalBufferPool {
    private let device: MTLDevice
    private let inflightSemaphore: DispatchSemaphore
    private var bufferIndex: Int = 0
    
    /// Triple-buffered parameter buffers
    private var paramBuffers: [MTLBuffer]
    
    /// Buffer count (typically 3 for triple-buffering)
    public let bufferCount: Int
    
    /// Current buffer index (0, 1, or 2 for triple-buffering)
    public var currentIndex: Int { bufferIndex }
    
    /// Initialize with device and buffer count
    public init(device: MTLDevice, bufferCount: Int = MetalConstants.inflightBufferCount) throws {
        self.device = device
        self.bufferCount = bufferCount
        self.inflightSemaphore = DispatchSemaphore(value: bufferCount)
        
        // Allocate triple-buffered parameter buffers
        let paramBufferSize = MemoryLayout<TSDFParams>.stride
        var buffers: [MTLBuffer] = []
        for _ in 0..<bufferCount {
            guard let buffer = device.makeBuffer(length: paramBufferSize, options: [.storageModeShared]) else {
                throw MetalBufferPoolError.bufferAllocationFailed
            }
            buffers.append(buffer)
        }
        self.paramBuffers = buffers
    }
    
    /// Wait for available buffer slot (with timeout protection)
    /// Guardrail #21: Semaphore deadlock protection
    /// Returns true if buffer acquired, false if timeout
    public func waitForAvailableBuffer() -> Bool {
        let timeout = DispatchTime.now() + .milliseconds(Int(TSDFConstants.semaphoreWaitTimeoutMs))
        let result = inflightSemaphore.wait(timeout: timeout)
        return result == .success
    }
    
    /// Signal that buffer is released (called in command buffer completion handler)
    public func signalBufferRelease() {
        inflightSemaphore.signal()
    }
    
    /// Advance to next buffer index (round-robin)
    public func advanceBufferIndex() {
        bufferIndex = (bufferIndex + 1) % bufferCount
    }
    
    /// Get current parameter buffer
    public func getCurrentParamBuffer() -> MTLBuffer {
        return paramBuffers[bufferIndex]
    }
    
    /// Get parameter buffer at specific index
    public func getParamBuffer(at index: Int) -> MTLBuffer {
        return paramBuffers[index % bufferCount]
    }
}

/// Errors for MetalBufferPool
public enum MetalBufferPoolError: Error {
    case bufferAllocationFailed
}

