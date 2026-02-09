// SPDX-License-Identifier: LicenseRef-Aether3D-Proprietary
// Copyright (c) 2024-2026 Aether3D. All rights reserved.

//
//  RingBuffer.swift
//  Aether3D
//
//  PR#5 Quality Pre-check - Milestone 0
//  O(1) sliding window implementation (PART 2.4)
//  H2: Explicit maximum capacity limits, OOM protection
//

import Foundation

/// RingBuffer - O(1) sliding window with fixed capacity
/// H2: Maximum capacity enforced, FIFO replacement when full (no new memory allocation)
public struct RingBuffer<T> {
    private var buffer: [T?]
    private var writeIndex: Int = 0
    private var count: Int = 0
    private let maxCapacity: Int
    
    /// Initialize RingBuffer with maximum capacity
    /// - Parameter maxCapacity: Maximum number of elements (must be > 0)
    public init(maxCapacity: Int) {
        precondition(maxCapacity > 0, "RingBuffer maxCapacity must be > 0")
        self.maxCapacity = maxCapacity
        self.buffer = Array(repeating: nil, count: maxCapacity)
    }
    
    /// Add element to buffer
    /// H2: If buffer is full, replaces oldest element (FIFO), does not allocate new memory
    public mutating func append(_ element: T) {
        buffer[writeIndex] = element
        writeIndex = (writeIndex + 1) % maxCapacity
        
        if count < maxCapacity {
            count += 1
        }
        // If count == maxCapacity, oldest element is overwritten (FIFO)
    }
    
    /// Get all elements in order (oldest first)
    public func getAll() -> [T] {
        guard count > 0 else { return [] }
        
        var result: [T] = []
        result.reserveCapacity(count)
        
        let startIndex = count < maxCapacity ? 0 : writeIndex
        for i in 0..<count {
            let index = (startIndex + i) % maxCapacity
            if let element = buffer[index] {
                result.append(element)
            }
        }
        
        return result
    }
    
    /// Get current count
    public var currentCount: Int {
        return count
    }
    
    /// Check if buffer is full
    public var isFull: Bool {
        return count >= maxCapacity
    }
    
    /// Clear buffer
    public mutating func clear() {
        buffer = Array(repeating: nil, count: maxCapacity)
        writeIndex = 0
        count = 0
    }
}

