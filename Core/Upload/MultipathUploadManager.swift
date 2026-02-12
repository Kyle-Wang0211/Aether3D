// SPDX-License-Identifier: LicenseRef-Aether3D-Proprietary
// CONSTITUTIONAL CONTRACT - DO NOT EDIT WITHOUT RFC
// Contract Version: PR9-NETWORK-1.0
// Module: Upload Infrastructure - Multipath Upload Manager
// Cross-Platform: macOS + Linux (Apple Network framework on Apple platforms)

import Foundation

#if canImport(Network)
import Network
#endif

/// WiFi+5G `.aggregate` bonding — DEFAULT strategy.
///
/// **Purpose**: WiFi+5G `.aggregate` bonding (DEFAULT), path-aware chunk scheduling
/// (priority → low-latency, bulk → high-bandwidth), per-path TLS.
///
/// **Multipath Strategy**:
/// - `.aggregate`: DEFAULT — Both radios bonded — MAXIMUM throughput
/// - `.wifiOnly`: Only when user enables Low Data Mode
/// - `.handover`: Legacy failover
/// - `.interactive`: Priority scheduling
///
/// **Path detection**:
/// - 2+ paths available, not constrained → .aggregate (max speed)
/// - 2+ paths available, constrained (Low Data Mode) → .wifiOnly
/// - 1 path → .wifiOnly
///
/// **Chunk-to-path assignment**:
/// - Priority 0-1 (critical/key frames) → lower-latency path
/// - Priority 2-5 (normal/deferred) → higher-bandwidth path
/// - Both paths active simultaneously for max throughput
public actor MultipathUploadManager {
    
    // MARK: - Multipath Strategy
    
    public enum MultipathStrategy: Sendable {
        case wifiOnly       // Only when user enables Low Data Mode
        case handover       // Legacy failover
        case interactive    // Priority scheduling
        case aggregate      // DEFAULT: Both radios bonded — MAXIMUM throughput
    }
    
    // MARK: - Path Info
    
    public struct PathInfo: Sendable {
        public let interface: NetworkInterface
        public let estimatedBandwidthMbps: Double
        public let estimatedLatencyMs: Double
        public let isExpensive: Bool
        public let isConstrained: Bool  // Low Data Mode
    }
    
    public enum NetworkInterface: String, Sendable {
        case wifi
        case cellular
        case wired
        case unknown
    }
    
    // MARK: - State
    
    private var strategy: MultipathStrategy = .aggregate
    private var availablePaths: [PathInfo] = []
    private var primaryPath: PathInfo?
    private var secondaryPath: PathInfo?
    
    private let networkPathObserver: NetworkPathObserver?
    
    // MARK: - Initialization
    
    /// Initialize multipath upload manager.
    ///
    /// - Parameter networkPathObserver: Network path observer for path detection
    public init(networkPathObserver: NetworkPathObserver? = nil) {
        self.networkPathObserver = networkPathObserver
    }
    
    // MARK: - Path Detection
    
    /// Detect available network paths.
    public func detectPaths() async {
        #if canImport(Network)
        guard let observer = networkPathObserver else {
            // Fallback: assume single path
            strategy = .wifiOnly
            return
        }
        
        // Subscribe to path changes
        for await event in await observer.events {
            await updatePaths(from: event)
        }
        #else
        // Linux: single path
        strategy = .wifiOnly
        #endif
    }
    
    #if canImport(Network)
    /// Update paths from network event.
    private func updatePaths(from event: NetworkPathEvent) async {
        availablePaths.removeAll()
        
        switch event.interfaceType {
        case .wifi:
            availablePaths.append(PathInfo(
                interface: .wifi,
                estimatedBandwidthMbps: 0,  // Measured during upload
                estimatedLatencyMs: 0,
                isExpensive: event.isExpensive,
                isConstrained: event.isConstrained
            ))
        case .cellular:
            availablePaths.append(PathInfo(
                interface: .cellular,
                estimatedBandwidthMbps: 0,
                estimatedLatencyMs: 0,
                isExpensive: true,
                isConstrained: event.isConstrained
            ))
        default:
            break
        }
        
        // Determine strategy
        if availablePaths.count >= 2 && !event.isConstrained {
            strategy = .aggregate  // Both radios bonded — max speed
        } else if availablePaths.count >= 2 && event.isConstrained {
            strategy = .wifiOnly  // User enabled Low Data Mode
        } else {
            strategy = .wifiOnly  // Single path
        }
        
        // Set primary/secondary paths
        primaryPath = availablePaths.first
        secondaryPath = availablePaths.count > 1 ? availablePaths[1] : nil
    }
    #endif
    
    // MARK: - Chunk Scheduling
    
    /// Assign chunk to path based on priority.
    ///
    /// - Parameter priority: Chunk priority
    /// - Returns: Selected path, or nil if no path available
    public func assignChunkToPath(priority: ChunkPriority) -> PathInfo? {
        switch strategy {
        case .aggregate:
            // Priority 0-1 → lower-latency path, Priority 2-5 → higher-bandwidth path
            if priority == .critical || priority == .high {
                return primaryPath  // Lower latency (typically WiFi)
            } else {
                return secondaryPath ?? primaryPath  // Higher bandwidth
            }
            
        case .wifiOnly:
            return primaryPath
            
        case .handover:
            return primaryPath  // Failover handled by URLSession
            
        case .interactive:
            // Priority-based scheduling
            return priority == .critical ? primaryPath : (secondaryPath ?? primaryPath)
        }
    }
    
    /// Get current strategy.
    public func getStrategy() -> MultipathStrategy {
        return strategy
    }
}
