//
// SmartAntiBoostSmoother.swift
// Aether3D
//
// PR3 - Smart Anti-Boost Dual Channel Smoother
// Conditional anti-boost, not punishment
//

import Foundation

/// Smart Anti-Boost Dual Channel Smoother
///
/// DESIGN:
/// - Anti-boost ONLY when jump exceeds jitterBand (suspicious)
/// - Normal improvement: faster recovery (configurable)
/// - K consecutive invalid: force worst-case fallback
/// - Hysteresis: prevent oscillation at boundaries
public final class SmartAntiBoostSmoother: @unchecked Sendable {

    // ═══════════════════════════════════════════════════════════════════════
    // MARK: - State
    // ═══════════════════════════════════════════════════════════════════════

    private let config: SmootherConfig
    private let windowSize: Int

    /// History buffer (pre-allocated)
    private var history: ContiguousArray<Double>
    private var historyCount: Int = 0

    /// Last valid value (for trend detection)
    private var lastValid: Double?

    /// Previous smoothed value (for change detection)
    private var previousSmoothed: Double?

    /// Consecutive invalid frame counter
    private var consecutiveInvalidCount: Int = 0

    // ═══════════════════════════════════════════════════════════════════════
    // MARK: - Initialization
    // ═══════════════════════════════════════════════════════════════════════

    /// Initialize smoother
    ///
    /// - Parameters:
    ///   - windowSize: Window size for median computation
    ///   - config: Configuration (default if not specified)
    public init(windowSize: Int = 5, config: SmootherConfig = .default) {
        self.windowSize = windowSize
        self.config = config
        self.history = ContiguousArray(repeating: 0.0, count: windowSize)
    }

    // ═══════════════════════════════════════════════════════════════════════
    // MARK: - Core API
    // ═══════════════════════════════════════════════════════════════════════

    /// Add value and return smoothed result
    ///
    /// BEHAVIOR:
    /// 1. If invalid (NaN/Inf): increment invalidCount, return previous or fallback
    /// 2. If valid: reset invalidCount, add to history, compute smoothed
    /// 3. If consecutiveInvalidCount >= maxConsecutiveInvalid: return worst-case
    ///
    /// - Parameter value: Input value
    /// - Returns: Smoothed value
    public func addAndSmooth(_ value: Double) -> Double {
        // Check validity
        guard value.isFinite else {
            return handleInvalidInput()
        }

        // Reset invalid counter on valid input
        consecutiveInvalidCount = 0

        // Update last valid
        lastValid = value

        // Update history (circular buffer style)
        if historyCount < windowSize {
            history[historyCount] = value
            historyCount += 1
        } else {
            // Shift and add (could optimize with ring buffer index)
            for i in 0..<(windowSize - 1) {
                history[i] = history[i + 1]
            }
            history[windowSize - 1] = value
        }

        // Compute smoothed value
        let smoothed = computeSmoothed(newValue: value)

        // Update previous for next iteration
        previousSmoothed = smoothed

        return smoothed
    }

    // ═══════════════════════════════════════════════════════════════════════
    // MARK: - Internal Logic
    // ═══════════════════════════════════════════════════════════════════════

    private func handleInvalidInput() -> Double {
        consecutiveInvalidCount += 1

        // If too many consecutive invalid, force worst-case
        if consecutiveInvalidCount >= config.maxConsecutiveInvalid {
            previousSmoothed = config.worstCaseFallback
            return config.worstCaseFallback
        }

        // Otherwise return previous smoothed (or worst-case if none)
        return previousSmoothed ?? config.worstCaseFallback
    }

    private func computeSmoothed(newValue: Double) -> Double {
        guard historyCount > 0 else { return newValue }

        // Compute median
        let median = computeMedian()

        // Get previous smoothed (or median if first time)
        let previous = previousSmoothed ?? median

        // Compute change
        let change = newValue - previous

        // Determine response based on change characteristics
        if abs(change) < config.jitterBand {
            // Within jitter band: use median (stable)
            return median
        } else if change > 0 {
            // Improving: check if suspicious jump
            if change > config.jitterBand * 3 {
                // Suspicious jump (> 3x jitter band): use anti-boost
                return previous + change * config.antiBoostFactor
            } else {
                // Normal improvement: use normal factor
                return previous + change * config.normalImproveFactor
            }
        } else {
            // Degrading: use degradation factor (usually 1.0 = immediate)
            return previous + change * config.degradeFactor
        }
    }

    private func computeMedian() -> Double {
        guard historyCount > 0 else { return 0.0 }

        // Copy valid portion and sort
        var sorted = Array(history[0..<historyCount])
        sorted.sort()

        // Compute median
        if historyCount % 2 == 0 {
            return (sorted[historyCount / 2 - 1] + sorted[historyCount / 2]) / 2.0
        } else {
            return sorted[historyCount / 2]
        }
    }

    /// Reset all state
    public func reset() {
        historyCount = 0
        lastValid = nil
        previousSmoothed = nil
        consecutiveInvalidCount = 0
    }
}
