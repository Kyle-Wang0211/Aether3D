// ============================================================================
// CONSTITUTIONAL CONTRACT - DO NOT EDIT WITHOUT RFC
// Contract Version: PR2-JSM-3.0-merged
// States: 9 | Transitions: 15 | FailureReasons: 17 | CancelReasons: 3
// ============================================================================

import Foundation

/// Estimates remaining time based on historical data.
/// Reference: Nielsen Norman Group - Response Time Limits
public final class ProgressEstimator {
    
    /// Historical processing times by state (rolling average)
    private var stateAverages: [JobState: TimeInterval] = [:]
    
    /// Sample count per state
    private var sampleCounts: [JobState: Int] = [:]
    
    /// Maximum samples to keep (for rolling average)
    private static let MAX_SAMPLES = 100
    
    /// Alpha for exponential moving average
    private static func alpha(sampleCount: Int) -> Double {
        return 2.0 / Double(min(sampleCount + 1, MAX_SAMPLES) + 1)
    }
    
    public init() {}
    
    /// Estimate remaining time from current state.
    /// - Parameters:
    ///   - currentState: Current job state
    ///   - elapsedInCurrentState: Time already spent in current state
    /// - Returns: Estimated remaining time, or nil if no data available
    public func estimateRemainingTime(
        currentState: JobState,
        elapsedInCurrentState: TimeInterval
    ) -> TimeInterval? {
        guard let average = stateAverages[currentState] else {
            return ContractConstants.FALLBACK_ETA_SECONDS
        }
        
        let remainingInState = max(0, average - elapsedInCurrentState)
        
        // Add estimates for subsequent states
        var total = remainingInState
        var nextState = currentState
        
        while let next = nextNonTerminalState(after: nextState) {
            if let nextAverage = stateAverages[next] {
                total += nextAverage
            }
            nextState = next
        }
        
        return total
    }
    
    /// Record actual duration for a state transition.
    /// - Parameters:
    ///   - state: The state that was completed
    ///   - duration: How long the job spent in that state
    public func recordDuration(state: JobState, duration: TimeInterval) {
        guard !state.isTerminal else { return }
        
        let count = sampleCounts[state] ?? 0
        let currentAverage = stateAverages[state] ?? duration
        
        // Exponential moving average for smooth updates
        let a = Self.alpha(sampleCount: count)
        let newAverage = a * duration + (1 - a) * currentAverage
        
        stateAverages[state] = newAverage
        sampleCounts[state] = min(count + 1, Self.MAX_SAMPLES)
    }
    
    /// Get current estimate for a specific state.
    /// - Parameter state: The state to query
    /// - Returns: Average duration for that state, or nil if no data
    public func getStateEstimate(_ state: JobState) -> TimeInterval? {
        return stateAverages[state]
    }
    
    /// Get sample count for a specific state.
    /// - Parameter state: The state to query
    /// - Returns: Number of samples recorded
    public func getSampleCount(_ state: JobState) -> Int {
        return sampleCounts[state] ?? 0
    }
    
    /// Reset all historical data.
    public func reset() {
        stateAverages.removeAll()
        sampleCounts.removeAll()
    }
    
    /// Calculate display progress with psychological optimization.
    /// - Parameters:
    ///   - actualProgress: Real progress (0.0 - 1.0)
    ///   - isInitialPhase: Whether this is the first few seconds
    /// - Returns: Perceived progress for display
    public func calculatePerceivedProgress(actualProgress: Double, isInitialPhase: Bool) -> Double {
        var perceived = actualProgress * 100.0
        
        // Initial boost: Show immediate progress
        if isInitialPhase && perceived < ContractConstants.INITIAL_PROGRESS_BOOST_PERCENT {
            perceived = ContractConstants.INITIAL_PROGRESS_BOOST_PERCENT
        }
        
        // Slowdown near completion: Slow down progress above 90%
        if perceived > ContractConstants.PROGRESS_SLOWDOWN_THRESHOLD_PERCENT {
            let excess = perceived - ContractConstants.PROGRESS_SLOWDOWN_THRESHOLD_PERCENT
            perceived = ContractConstants.PROGRESS_SLOWDOWN_THRESHOLD_PERCENT + (excess * 0.5)
        }
        
        // Cap at 99% until actually complete
        if perceived >= 100.0 && actualProgress < 1.0 {
            perceived = 99.0
        }
        
        return min(100.0, max(0.0, perceived))
    }
    
    /// Check if progress update should be reported.
    /// - Parameters:
    ///   - previousProgress: Last reported progress
    ///   - currentProgress: Current progress
    /// - Returns: True if update should be reported
    public func shouldReportProgress(previousProgress: Double, currentProgress: Double) -> Bool {
        let diff = abs(currentProgress - previousProgress)
        return diff >= ContractConstants.MIN_PROGRESS_INCREMENT_PERCENT
    }
    
    // MARK: - Private Methods
    
    private func nextNonTerminalState(after state: JobState) -> JobState? {
        switch state {
        case .pending: return .uploading
        case .uploading: return .queued
        case .queued: return .processing
        case .processing: return .packaging
        case .packaging: return nil  // completed is terminal
        case .completed, .failed, .cancelled, .capacitySaturated: return nil
        }
    }
}
