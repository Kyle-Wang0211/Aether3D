// SPDX-License-Identifier: LicenseRef-Aether3D-Proprietary
// CONSTITUTIONAL CONTRACT - DO NOT EDIT WITHOUT RFC
// Contract Version: PR9-NETWORK-1.0
// Module: Upload Infrastructure - Kalman Bandwidth Predictor
// Cross-Platform: macOS + Linux (pure Foundation)

import Foundation

/// Bandwidth prediction result.
public struct BandwidthPrediction: Sendable {
    public let predictedBps: Double
    public let confidenceInterval95: (low: Double, high: Double)
    public let trend: BandwidthTrend
    public let isReliable: Bool       // trace(P) convergence check
    public let source: PredictionSource
}

/// Bandwidth trend indicator.
public enum BandwidthTrend: String, Sendable {
    case rising
    case stable
    case falling
}

/// Prediction source.
public enum PredictionSource: String, Sendable {
    case kalman
    case ml
    case ensemble
}

/// Bandwidth estimator protocol.
public protocol BandwidthEstimator: Sendable {
    func addSample(bytesTransferred: Int64, durationSeconds: TimeInterval) async
    func predict() async -> BandwidthPrediction
    func reset() async
}

/// 4D Kalman filter for bandwidth prediction.
///
/// **State vector (4D):** `[bandwidth, d_bandwidth/dt, d2_bandwidth/dt2, variance]`
///
/// **Key parameters:**
/// - Process noise Q: adaptive (10x increase on NWPathMonitor network change events)
/// - Measurement noise R: dynamic based on last 10 samples' variance
/// - Initial covariance P0: `diag(100, 10, 1, 50)`
/// - Anomaly threshold: Mahalanobis distance > 2.5σ → reduce sample weight
/// - Convergence indicator: `trace(P) < 5.0` → mark "estimate reliable"
public actor KalmanBandwidthPredictor: BandwidthEstimator {
    
    // MARK: - State Vector (4D)
    
    /// State vector: [bandwidth, d_bandwidth/dt, d2_bandwidth/dt2, variance]
    private var x: [Double] = [0.0, 0.0, 0.0, 0.0]
    
    /// Covariance matrix P (4x4)
    private var P: [[Double]] = [
        [100.0, 0.0, 0.0, 0.0],
        [0.0, 10.0, 0.0, 0.0],
        [0.0, 0.0, 1.0, 0.0],
        [0.0, 0.0, 0.0, 50.0]
    ]
    
    /// Process noise Q (adaptive)
    private var Q: [[Double]] = [
        [UploadConstants.KALMAN_PROCESS_NOISE_BASE, 0.0, 0.0, 0.0],
        [0.0, UploadConstants.KALMAN_PROCESS_NOISE_BASE, 0.0, 0.0],
        [0.0, 0.0, UploadConstants.KALMAN_PROCESS_NOISE_BASE, 0.0],
        [0.0, 0.0, 0.0, UploadConstants.KALMAN_PROCESS_NOISE_BASE]
    ]
    
    /// Measurement noise R (dynamic)
    private var R: Double = UploadConstants.KALMAN_MEASUREMENT_NOISE_FLOOR
    
    /// Observation matrix H (1x4): [1, 0, 0, 0] - observe bandwidth only
    private let H: [Double] = [1.0, 0.0, 0.0, 0.0]
    
    /// State transition matrix F (4x4)
    private let F: [[Double]] = [
        [1.0, 1.0, 0.5, 0.0],  // x[k+1] = x[k] + dx[k] + 0.5*d2x[k]
        [0.0, 1.0, 1.0, 0.0],   // dx[k+1] = dx[k] + d2x[k]
        [0.0, 0.0, 1.0, 0.0],   // d2x[k+1] = d2x[k]
        [0.0, 0.0, 0.0, 1.0]    // variance[k+1] = variance[k]
    ]
    
    // MARK: - Sample History
    
    /// Recent samples for R adaptation
    private var recentSamples: [(bytesTransferred: Int64, durationSeconds: TimeInterval)] = []
    private let maxRecentSamples = UploadConstants.KALMAN_DYNAMIC_R_SAMPLE_COUNT
    
    /// Total samples processed
    private var totalSamples: Int = 0
    
    // MARK: - Network Path Observer Integration
    
    private var networkPathObserver: NetworkPathObserver?
    private var pathChangeTask: Task<Void, Never>?
    
    /// Initialize Kalman bandwidth predictor.
    ///
    /// - Parameter networkPathObserver: Optional network path observer for Q adaptation
    public init(networkPathObserver: NetworkPathObserver? = nil) {
        self.networkPathObserver = networkPathObserver
        
        // Subscribe to network path changes
        if let observer = networkPathObserver {
            pathChangeTask = Task {
                for await event in await observer.events {
                    if case .interfaceChanged = event.changeType {
                        await adaptProcessNoiseForNetworkChange()
                    }
                }
            }
        }
    }
    
    deinit {
        pathChangeTask?.cancel()
    }
    
    // MARK: - BandwidthEstimator Protocol
    
    /// Add bandwidth sample.
    ///
    /// - Parameters:
    ///   - bytesTransferred: Bytes transferred
    ///   - durationSeconds: Duration in seconds
    public func addSample(bytesTransferred: Int64, durationSeconds: TimeInterval) async {
        guard durationSeconds > 0 else { return }
        
        let measuredBps = Double(bytesTransferred * 8) / durationSeconds  // Convert to bits per second
        
        // Update recent samples for R adaptation
        recentSamples.append((bytesTransferred, durationSeconds))
        if recentSamples.count > maxRecentSamples {
            recentSamples.removeFirst()
        }
        
        // Adapt R based on recent variance
        adaptMeasurementNoise()
        
        // Predict step
        predictStep()
        
        // Update step (with anomaly detection)
        updateStep(measurement: measuredBps)
        
        totalSamples += 1
    }
    
    /// Predict bandwidth.
    ///
    /// - Returns: BandwidthPrediction with confidence interval and trend
    public func predict() async -> BandwidthPrediction {
        let predictedBps = x[0]
        let variance = P[0][0]
        let stdDev = sqrt(variance)
        
        // 95% confidence interval (±1.96σ)
        let confidence95 = 1.96 * stdDev
        let confidenceInterval95 = (
            low: max(0.0, predictedBps - confidence95),
            high: predictedBps + confidence95
        )
        
        // Trend based on first derivative
        let trend: BandwidthTrend
        if x[1] > 0.1 {
            trend = .rising
        } else if x[1] < -0.1 {
            trend = .falling
        } else {
            trend = .stable
        }
        
        // Reliability check: trace(P) < threshold
        let traceP = P[0][0] + P[1][1] + P[2][2] + P[3][3]
        let isReliable = traceP < UploadConstants.KALMAN_CONVERGENCE_THRESHOLD
        
        return BandwidthPrediction(
            predictedBps: predictedBps,
            confidenceInterval95: confidenceInterval95,
            trend: trend,
            isReliable: isReliable,
            source: .kalman
        )
    }
    
    /// Reset filter to initial state.
    public func reset() async {
        x = [0.0, 0.0, 0.0, 0.0]
        P = [
            [100.0, 0.0, 0.0, 0.0],
            [0.0, 10.0, 0.0, 0.0],
            [0.0, 0.0, 1.0, 0.0],
            [0.0, 0.0, 0.0, 50.0]
        ]
        recentSamples.removeAll()
        totalSamples = 0
    }
    
    // MARK: - Kalman Filter Steps
    
    /// Predict step: x = F*x, P = F*P*F' + Q
    private func predictStep() {
        // x = F * x
        let xNew = matrixVectorMultiply(F, x)
        x = xNew
        
        // P = F * P * F' + Q
        let FP = matrixMultiply(F, P)
        let FPFt = matrixMultiply(FP, transpose(F))
        P = matrixAdd(FPFt, Q)
    }
    
    /// Update step: K = P*H'/(H*P*H' + R), x = x + K*(z - H*x), P = (I - K*H)*P
    private func updateStep(measurement: Double) {
        // Innovation: y = z - H*x
        let y = measurement - dotProduct(H, x)
        
        // Innovation covariance: S = H*P*H' + R
        // H is a row vector [1, 0, 0, 0], P is 4x4 matrix
        // HP = H * P = [P[0][0], P[1][0], P[2][0], P[3][0]]
        let HP = [P[0][0], P[1][0], P[2][0], P[3][0]]
        let S = dotProduct(HP, H) + R
        
        // Kalman gain: K = P*H' / S
        let PHt = [P[0][0] * H[0], P[1][0] * H[0], P[2][0] * H[0], P[3][0] * H[0]]
        let K = PHt.map { $0 / S }
        
        // Anomaly detection: Mahalanobis distance
        let mahalanobisDistance = abs(y) / sqrt(S)
        if mahalanobisDistance > UploadConstants.KALMAN_ANOMALY_THRESHOLD_SIGMA {
            // Reduce sample weight (use smaller K)
            let reducedK = K.map { $0 * 0.5 }
            x = vectorAdd(x, vectorScale(reducedK, y))
        } else {
            // Normal update
            x = vectorAdd(x, vectorScale(K, y))
        }
        
        // P = (I - K*H) * P
        let KH = outerProduct(K, H)
        let I = identityMatrix(4)
        let IKH = matrixSubtract(I, KH)
        P = matrixMultiply(IKH, P)
    }
    
    // MARK: - Adaptive Noise
    
    /// Adapt process noise Q on network change (10x increase).
    private func adaptProcessNoiseForNetworkChange() {
        let baseNoise = UploadConstants.KALMAN_PROCESS_NOISE_BASE
        let increasedNoise = baseNoise * 10.0
        
        Q = [
            [increasedNoise, 0.0, 0.0, 0.0],
            [0.0, increasedNoise, 0.0, 0.0],
            [0.0, 0.0, increasedNoise, 0.0],
            [0.0, 0.0, 0.0, increasedNoise]
        ]
    }
    
    /// Adapt measurement noise R based on recent sample variance.
    private func adaptMeasurementNoise() {
        guard recentSamples.count >= 2 else { return }
        
        let bpsSamples = recentSamples.map { Double($0.bytesTransferred * 8) / $0.durationSeconds }
        let mean = bpsSamples.reduce(0, +) / Double(bpsSamples.count)
        let variance = bpsSamples.map { pow($0 - mean, 2) }.reduce(0, +) / Double(bpsSamples.count)
        
        R = max(UploadConstants.KALMAN_MEASUREMENT_NOISE_FLOOR, variance)
    }
    
    // MARK: - Matrix Operations
    
    private func matrixVectorMultiply(_ matrix: [[Double]], _ vector: [Double]) -> [Double] {
        return matrix.map { dotProduct($0, vector) }
    }
    
    private func matrixMultiply(_ a: [[Double]], _ b: [[Double]]) -> [[Double]] {
        let rows = a.count
        let cols = b[0].count
        var result = Array(repeating: Array(repeating: 0.0, count: cols), count: rows)
        
        for i in 0..<rows {
            for j in 0..<cols {
                for k in 0..<a[0].count {
                    result[i][j] += a[i][k] * b[k][j]
                }
            }
        }
        return result
    }
    
    private func transpose(_ matrix: [[Double]]) -> [[Double]] {
        let rows = matrix.count
        let cols = matrix[0].count
        var result = Array(repeating: Array(repeating: 0.0, count: rows), count: cols)
        
        for i in 0..<rows {
            for j in 0..<cols {
                result[j][i] = matrix[i][j]
            }
        }
        return result
    }
    
    private func matrixAdd(_ a: [[Double]], _ b: [[Double]]) -> [[Double]] {
        return zip(a, b).map { zip($0, $1).map(+) }
    }
    
    private func matrixSubtract(_ a: [[Double]], _ b: [[Double]]) -> [[Double]] {
        return zip(a, b).map { zip($0, $1).map(-) }
    }
    
    private func dotProduct(_ a: [Double], _ b: [Double]) -> Double {
        return zip(a, b).map(*).reduce(0, +)
    }
    
    private func vectorAdd(_ a: [Double], _ b: [Double]) -> [Double] {
        return zip(a, b).map(+)
    }
    
    private func vectorScale(_ vector: [Double], _ scalar: Double) -> [Double] {
        return vector.map { $0 * scalar }
    }
    
    private func outerProduct(_ a: [Double], _ b: [Double]) -> [[Double]] {
        return a.map { ai in b.map { ai * $0 } }
    }
    
    private func identityMatrix(_ size: Int) -> [[Double]] {
        var result = Array(repeating: Array(repeating: 0.0, count: size), count: size)
        for i in 0..<size {
            result[i][i] = 1.0
        }
        return result
    }
}
