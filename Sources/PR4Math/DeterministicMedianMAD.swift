//
// DeterministicMedianMAD.swift
// PR4Math
//
// PR4 V10 - Pillar 34: Deterministic median and MAD computation
//

import Foundation

/// Deterministic median and MAD computation
///
/// V8 RULE: No stdlib sort (platform-dependent)
/// Uses sorting network for small N, deterministic quickselect for large N
public enum DeterministicMedianMAD {
    
    /// Sorting network threshold
    private static let sortingNetworkThreshold = 32
    
    // ═══════════════════════════════════════════════════════════════════════
    // MARK: - Median
    // ═══════════════════════════════════════════════════════════════════════
    
    /// Compute median deterministically
    public static func median(_ values: [Double]) -> Double {
        guard !values.isEmpty else { return 0 }
        guard values.count > 1 else { return values[0] }
        
        var copy = values
        
        if copy.count <= sortingNetworkThreshold {
            // Use sorting network
            sortingNetworkSort(&copy)
        } else {
            // Use deterministic quickselect
            deterministicSort(&copy)
        }
        
        let mid = copy.count / 2
        if copy.count % 2 == 1 {
            return copy[mid]
        } else {
            return (copy[mid - 1] + copy[mid]) / 2.0
        }
    }
    
    /// Compute median of Int64 array
    public static func medianQ16(_ values: [Int64]) -> Int64 {
        guard !values.isEmpty else { return 0 }
        guard values.count > 1 else { return values[0] }
        
        var copy = values
        
        if copy.count <= sortingNetworkThreshold {
            sortingNetworkSortQ16(&copy)
        } else {
            deterministicSortQ16(&copy)
        }
        
        let mid = copy.count / 2
        if copy.count % 2 == 1 {
            return copy[mid]
        } else {
            return (copy[mid - 1] + copy[mid]) / 2
        }
    }
    
    // ═══════════════════════════════════════════════════════════════════════
    // MARK: - MAD (Median Absolute Deviation)
    // ═══════════════════════════════════════════════════════════════════════
    
    /// Compute MAD deterministically
    public static func mad(_ values: [Double]) -> Double {
        guard values.count >= 3 else { return 0 }
        
        let med = median(values)
        let deviations = values.map { abs($0 - med) }
        return median(deviations)
    }
    
    /// Compute MAD of Int64 array
    public static func madQ16(_ values: [Int64]) -> Int64 {
        guard values.count >= 3 else { return 0 }
        
        let med = medianQ16(values)
        let deviations = values.map { abs($0 - med) }
        return medianQ16(deviations)
    }
    
    // ═══════════════════════════════════════════════════════════════════════
    // MARK: - Sorting Network (Small Arrays)
    // ═══════════════════════════════════════════════════════════════════════
    
    /// Sorting network for small arrays
    private static func sortingNetworkSort(_ array: inout [Double]) {
        let n = array.count
        
        // Simple insertion sort with deterministic comparison
        for i in 1..<n {
            var j = i
            while j > 0 && TotalOrderComparator.totalOrder(array[j-1], array[j]) > 0 {
                array.swapAt(j-1, j)
                j -= 1
            }
        }
    }
    
    private static func sortingNetworkSortQ16(_ array: inout [Int64]) {
        let n = array.count
        
        for i in 1..<n {
            var j = i
            while j > 0 && array[j-1] > array[j] {
                array.swapAt(j-1, j)
                j -= 1
            }
        }
    }
    
    // ═══════════════════════════════════════════════════════════════════════
    // MARK: - Deterministic Quicksort (Large Arrays)
    // ═══════════════════════════════════════════════════════════════════════
    
    /// Deterministic quicksort with median-of-three pivot
    private static func deterministicSort(_ array: inout [Double]) {
        deterministicQuicksort(&array, low: 0, high: array.count - 1)
    }
    
    private static func deterministicQuicksort(_ array: inout [Double], low: Int, high: Int) {
        guard low < high else { return }
        
        if high - low < 16 {
            // Insertion sort for small subarrays
            for i in (low + 1)...high {
                var j = i
                while j > low && TotalOrderComparator.totalOrder(array[j-1], array[j]) > 0 {
                    array.swapAt(j-1, j)
                    j -= 1
                }
            }
            return
        }
        
        // Median-of-three pivot selection (deterministic)
        let mid = low + (high - low) / 2
        if TotalOrderComparator.totalOrder(array[mid], array[low]) < 0 {
            array.swapAt(low, mid)
        }
        if TotalOrderComparator.totalOrder(array[high], array[low]) < 0 {
            array.swapAt(low, high)
        }
        if TotalOrderComparator.totalOrder(array[mid], array[high]) < 0 {
            array.swapAt(mid, high)
        }
        let pivot = array[high]
        
        // Partition
        var i = low
        for j in low..<high {
            if TotalOrderComparator.totalOrder(array[j], pivot) < 0 {
                array.swapAt(i, j)
                i += 1
            }
        }
        array.swapAt(i, high)
        
        // Recurse
        deterministicQuicksort(&array, low: low, high: i - 1)
        deterministicQuicksort(&array, low: i + 1, high: high)
    }
    
    private static func deterministicSortQ16(_ array: inout [Int64]) {
        array.sort()  // Int64 comparison is deterministic
    }
}
