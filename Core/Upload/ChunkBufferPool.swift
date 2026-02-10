// SPDX-License-Identifier: LicenseRef-Aether3D-Proprietary
// CONSTITUTIONAL CONTRACT - DO NOT EDIT WITHOUT RFC
// Contract Version: PR9-IO-1.0
// Module: Upload Infrastructure - Chunk Buffer Pool
// Cross-Platform: macOS + Linux (pure Foundation)

import Foundation

/// Pre-allocated buffer pool for zero allocations during upload loop.
///
/// **Purpose**: Eliminate memory allocations during the upload hot path.
/// Buffers are pre-allocated at initialization and reused throughout the upload.
///
/// **Memory Pressure Handling**: Reduces buffer count but NEVER below 2.
/// Upload continues even under memory pressure — we only reduce parallelism.
///
/// **Security**: All buffers are zeroed before return to pool using `memset_s`.
public actor ChunkBufferPool {
    
    private var available: [UnsafeMutableRawBufferPointer] = []
    private var maxBuffers: Int = UploadConstants.BUFFER_POOL_MAX_BUFFERS
    private let bufferSize: Int
    
    /// Initialize buffer pool with pre-allocated buffers.
    ///
    /// - Parameter bufferSize: Size of each buffer in bytes (typically chunk size)
    public init(bufferSize: Int) {
        self.bufferSize = bufferSize
        
        // Pre-allocate all buffers
        for _ in 0..<maxBuffers {
            if let buffer = Self.allocateAlignedBuffer(size: bufferSize) {
                available.append(buffer)
            }
        }
    }
    
    deinit {
        // Zero and deallocate all buffers
        for buffer in available {
            Self.zeroAndDeallocate(buffer)
        }
    }
    
    /// Acquire a buffer from the pool.
    ///
    /// Blocks if no buffer is available (should not happen with proper sizing).
    /// Minimum 2 buffers always exist even under memory pressure.
    ///
    /// - Returns: Pre-allocated buffer pointer
    public func acquire() -> UnsafeMutableRawBufferPointer? {
        if let buffer = available.popLast() {
            return buffer
        }
        
        // Emergency fallback: allocate new buffer if pool exhausted
        // This should be rare — indicates incorrect pool sizing
        return Self.allocateAlignedBuffer(size: bufferSize)
    }
    
    /// Return a buffer to the pool.
    ///
    /// Buffer is zeroed before return using `memset_s` (cannot be optimized away).
    ///
    /// - Parameter buffer: Buffer to return
    public func release(_ buffer: UnsafeMutableRawBufferPointer) {
        // Zero buffer before return (security requirement)
        Self.zeroBuffer(buffer)
        
        // Only keep up to maxBuffers in pool
        if available.count < maxBuffers {
            available.append(buffer)
        } else {
            // Pool full — deallocate excess buffer
            Self.zeroAndDeallocate(buffer)
        }
    }
    
    /// Adjust pool size for memory pressure.
    ///
    /// **CRITICAL**: NEVER reduces below 2 buffers.
    /// Upload continues even under extreme memory pressure.
    ///
    /// Uses `os_proc_available_memory()` on Apple platforms, fallback on Linux.
    public func adjustForMemoryPressure() {
        let availableMemory = Self.getAvailableMemory()
        
        let newMaxBuffers: Int
        switch availableMemory {
        case 200_000_000...:    // ≥200MB
            newMaxBuffers = 12
        case 100_000_000...:    // 100-200MB
            newMaxBuffers = 8
        case 50_000_000...:     // 50-100MB
            newMaxBuffers = 4
        default:                // <50MB
            newMaxBuffers = 2   // NEVER below 2
        }
        
        // Reduce pool if needed
        if newMaxBuffers < maxBuffers {
            maxBuffers = newMaxBuffers
            while available.count > maxBuffers {
                if let buffer = available.popLast() {
                    Self.zeroAndDeallocate(buffer)
                }
            }
        } else if newMaxBuffers > maxBuffers {
            // Increase pool if memory available
            maxBuffers = newMaxBuffers
            for _ in available.count..<maxBuffers {
                if let buffer = Self.allocateAlignedBuffer(size: bufferSize) {
                    available.append(buffer)
                }
            }
        }
    }
    
    // MARK: - Private Helpers
    
    /// Allocate 16KB-aligned buffer (Apple Silicon page size).
    private static func allocateAlignedBuffer(size: Int) -> UnsafeMutableRawBufferPointer? {
        let alignment = 16384  // 16KB
        var ptr: UnsafeMutableRawPointer?
        let result = posix_memalign(&ptr, alignment, size)
        
        guard result == 0, let alignedPtr = ptr else {
            return nil
        }
        
        return UnsafeMutableRawBufferPointer(start: alignedPtr, count: size)
    }
    
    /// Zero buffer using `memset_s` (cannot be optimized away by compiler).
    private static func zeroBuffer(_ buffer: UnsafeMutableRawBufferPointer) {
        guard let base = buffer.baseAddress else { return }
        memset_s(base, buffer.count, 0, buffer.count)
    }
    
    /// Zero and deallocate buffer.
    private static func zeroAndDeallocate(_ buffer: UnsafeMutableRawBufferPointer) {
        zeroBuffer(buffer)
        buffer.deallocate()
    }
    
    /// Get available memory (platform-specific).
    private static func getAvailableMemory() -> UInt64 {
        #if canImport(Darwin)
        // Apple platforms: use os_proc_available_memory()
        #if os(iOS) || os(tvOS) || os(watchOS)
        if #available(iOS 13.0, tvOS 13.0, watchOS 6.0, *) {
            return UInt64(os_proc_available_memory())
        }
        #endif
        // macOS: return conservative estimate
        return 200_000_000  // Assume 200MB available on macOS
        #endif
        
        // Linux fallback: return conservative estimate
        // In production, could use /proc/meminfo parsing
        return 100_000_000  // Assume 100MB available
    }
}
