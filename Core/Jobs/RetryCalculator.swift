// ============================================================================
// CONSTITUTIONAL CONTRACT - DO NOT EDIT WITHOUT RFC
// Contract Version: PR2-JSM-3.0-merged
// States: 9 | Transitions: 15 | FailureReasons: 17 | CancelReasons: 3
// Purpose: Calculate retry delays with exponential backoff and jitter
// ============================================================================

import Foundation

/// Jitter strategy enumeration
public enum JitterStrategy: String, Codable {
    case full       // random(0, min(cap, base * 2^attempt))
    case equal      // temp/2 + random(0, temp/2)
    case decorrelated  // min(cap, random(base, previousDelay * 3)) - RECOMMENDED
}

/// Retry delay calculator with exponential backoff and jitter.
/// Based on AWS and Google Cloud best practices for distributed systems.
public enum RetryCalculator {
    
    /// Calculate the delay before the next retry attempt.
    /// - Parameters:
    ///   - attempt: Current attempt number (0-indexed, so first retry is attempt 0)
    ///   - baseInterval: Base interval in seconds (default: 2)
    ///   - maxDelay: Maximum delay cap in seconds (default: 60)
    ///   - jitterMaxMs: Maximum jitter in milliseconds (default: 1000)
    /// - Returns: Delay in seconds (Double for millisecond precision)
    public static func calculateDelay(
        attempt: Int,
        baseInterval: Int = ContractConstants.RETRY_BASE_INTERVAL_SECONDS,
        maxDelay: Int = ContractConstants.RETRY_MAX_DELAY_SECONDS,
        jitterMaxMs: Int = ContractConstants.RETRY_JITTER_MAX_MS
    ) -> Double {
        // Exponential component: baseInterval × 2^attempt
        let exponentialDelay = Double(baseInterval) * pow(2.0, Double(attempt))
        
        // Cap at maxDelay
        let cappedDelay = min(exponentialDelay, Double(maxDelay))
        
        // Add jitter (full jitter strategy)
        let jitterSeconds = Double.random(in: 0...(Double(jitterMaxMs) / 1000.0))
        
        // Final delay
        let finalDelay = cappedDelay + jitterSeconds
        
        return finalDelay
    }
    
    /// Calculate delay using decorrelated jitter (Netflix/AWS best practice)
    /// Formula: delay = min(maxDelay, random(baseDelay, previousDelay * 3))
    /// Reference: https://aws.amazon.com/blogs/architecture/exponential-backoff-and-jitter/
    /// - Parameters:
    ///   - previousDelay: Previous delay value (for decorrelated jitter)
    ///   - baseDelay: Base delay in seconds (default: 1.0)
    ///   - maxDelay: Maximum delay cap in seconds (default: 60.0)
    /// - Returns: Delay in seconds
    public static func calculateDecorrelatedDelay(
        previousDelay: TimeInterval,
        baseDelay: TimeInterval = 1.0,
        maxDelay: TimeInterval = Double(ContractConstants.RETRY_MAX_DELAY_SECONDS)
    ) -> TimeInterval {
        let minDelay = baseDelay
        let maxRange = min(maxDelay, previousDelay * ContractConstants.RETRY_DECORRELATED_MULTIPLIER)
        return Double.random(in: minDelay...max(minDelay, maxRange))
    }
    
    /// Check if retry should be attempted based on attempt count and failure reason.
    /// - Parameters:
    ///   - attempt: Current attempt number (0-indexed)
    ///   - failureReason: The failure reason from the last attempt
    /// - Returns: True if retry should be attempted
    public static func shouldRetry(
        attempt: Int,
        failureReason: FailureReason
    ) -> Bool {
        // Check attempt limit
        guard attempt < ContractConstants.MAX_AUTO_RETRY_COUNT else {
            return false
        }
        
        // Check if failure reason is retryable
        return failureReason.isRetryable
    }
    
    /// Get all retry delays for a full retry sequence (for preview/logging).
    /// - Parameters:
    ///   - maxAttempts: Maximum attempts (default from constants)
    /// - Returns: Array of delays in seconds
    public static func previewDelays(
        maxAttempts: Int = ContractConstants.MAX_AUTO_RETRY_COUNT
    ) -> [Double] {
        return (0..<maxAttempts).map { attempt in
            calculateDelay(attempt: attempt)
        }
    }
}

// MARK: - Retry Sequence Example
// Attempt 0: 2.0 + jitter(0~1.0) = 2.0~3.0 seconds
// Attempt 1: 4.0 + jitter(0~1.0) = 4.0~5.0 seconds
// Attempt 2: 8.0 + jitter(0~1.0) = 8.0~9.0 seconds
// Attempt 3: 16.0 + jitter(0~1.0) = 16.0~17.0 seconds
// Attempt 4: 32.0 + jitter(0~1.0) = 32.0~33.0 seconds
// Total max wait: ~68 seconds (reasonable for user experience)
