// SPDX-License-Identifier: LicenseRef-Aether3D-Proprietary
// CONSTITUTIONAL CONTRACT - DO NOT EDIT WITHOUT RFC
// Contract Version: PR9-NETWORK-1.0
// Module: Upload Infrastructure - Network Path Observer
// Cross-Platform: macOS + Linux (pure Foundation, optional Network framework)

import Foundation

#if canImport(Network)
import Network
#endif

/// Network path change event.
public struct NetworkPathEvent: Sendable {
    public let timestamp: Date
    public let interfaceType: InterfaceType
    public let isConstrained: Bool   // Low Data Mode
    public let isExpensive: Bool     // Cellular
    public let hasIPv4: Bool
    public let hasIPv6: Bool
    public let changeType: ChangeType
}

/// Type of network path change.
public enum ChangeType: Sendable {
    case initial
    case interfaceChanged(from: InterfaceType, to: InterfaceType)
    case constraintChanged
    case pathUnavailable
    case pathRestored
}

/// Network interface type.
public enum InterfaceType: String, Sendable {
    case wifi
    case cellular
    case wiredEthernet
    case loopback
    case other
    case unknown
}

/// Monitor network path changes using NWPathMonitor (Apple) or polling (Linux).
///
/// **Purpose**: Detect network interface changes and feed events to KalmanBandwidthPredictor
/// for process noise adaptation. Publishes events via AsyncStream for all consumers.
///
/// **Key Features**:
/// 1. Detects WiFi → Cellular handover (triggers Kalman Q 10x increase)
/// 2. Detects Cellular → WiFi upgrade (triggers connection prewarming)
/// 3. Monitors `isConstrained` (Low Data Mode) and `isExpensive` (cellular) flags
/// 4. Tracks interface type changes
/// 5. Publishes events via AsyncStream
public actor NetworkPathObserver {
    
    #if canImport(Network)
    private let monitor: NWPathMonitor
    private var currentPath: NWPath?
    private let pathStream: AsyncStream<NetworkPathEvent>
    private let pathContinuation: AsyncStream<NetworkPathEvent>.Continuation
    private var isMonitoring = false
    
    public init() {
        monitor = NWPathMonitor()
        currentPath = nil
        
        var continuation: AsyncStream<NetworkPathEvent>.Continuation!
        pathStream = AsyncStream { continuation = $0 }
        pathContinuation = continuation
    }
    
    /// Start monitoring network path changes.
    public func startMonitoring() {
        guard !isMonitoring else { return }
        isMonitoring = true
        
        let queue = DispatchQueue(label: "com.aether3d.networkpath", qos: .utility)
        
        monitor.pathUpdateHandler = { [weak self] path in
            Task { [weak self] in
                await self?.handlePathUpdate(path)
            }
        }
        
        monitor.start(queue: queue)
        
        // Send initial path
        let initialPath = monitor.currentPath
        Task {
            await handlePathUpdate(initialPath)
        }
    }
    
    /// Stop monitoring network path changes.
    public func stopMonitoring() {
        guard isMonitoring else { return }
        isMonitoring = false
        monitor.cancel()
    }
    
    /// Get AsyncStream of network path events.
    public var events: AsyncStream<NetworkPathEvent> {
        return pathStream
    }
    
    private func handlePathUpdate(_ path: NWPath) {
        let previousPath = currentPath
        currentPath = path
        
        let previousType = previousPath.map { interfaceType(from: $0) }
        let currentType = interfaceType(from: path)
        
        let changeType: ChangeType
        if previousPath == nil {
            changeType = .initial
        } else if previousType != currentType {
            changeType = .interfaceChanged(from: previousType ?? .unknown, to: currentType)
        } else if previousPath?.isConstrained != path.isConstrained || previousPath?.isExpensive != path.isExpensive {
            changeType = .constraintChanged
        } else if path.status != .satisfied && previousPath?.status == .satisfied {
            changeType = .pathUnavailable
        } else if path.status == .satisfied && previousPath?.status != .satisfied {
            changeType = .pathRestored
        } else {
            // No significant change
            return
        }
        
        let event = NetworkPathEvent(
            timestamp: Date(),
            interfaceType: currentType,
            isConstrained: path.isConstrained,
            isExpensive: path.isExpensive,
            hasIPv4: path.supportsIPv4,
            hasIPv6: path.supportsIPv6,
            changeType: changeType
        )
        
        pathContinuation.yield(event)
    }
    
    private func interfaceType(from path: NWPath) -> InterfaceType {
        if path.usesInterfaceType(.wifi) {
            return .wifi
        } else if path.usesInterfaceType(.cellular) {
            return .cellular
        } else if path.usesInterfaceType(.wiredEthernet) {
            return .wiredEthernet
        } else if path.usesInterfaceType(.loopback) {
            return .loopback
        } else if path.usesInterfaceType(.other) {
            return .other
        } else {
            return .unknown
        }
    }
    
    #else
    // Linux fallback: periodic polling
    private let pathStream: AsyncStream<NetworkPathEvent>
    private let pathContinuation: AsyncStream<NetworkPathEvent>.Continuation
    private var isMonitoring = false
    private var pollingTask: Task<Void, Never>?
    
    public init() {
        var continuation: AsyncStream<NetworkPathEvent>.Continuation!
        pathStream = AsyncStream { continuation = $0 }
        pathContinuation = continuation
    }
    
    /// Start monitoring network path changes (Linux: polling /proc/net/dev).
    public func startMonitoring() {
        guard !isMonitoring else { return }
        isMonitoring = true
        
        pollingTask = Task {
            var previousInterfaces: Set<String> = []
            
            while !Task.isCancelled {
                let currentInterfaces = await pollNetworkInterfaces()
                
                if currentInterfaces != previousInterfaces {
                    let changeType: ChangeType
                    if previousInterfaces.isEmpty {
                        changeType = .initial
                    } else if currentInterfaces.isEmpty {
                        changeType = .pathUnavailable
                    } else if previousInterfaces.isEmpty {
                        changeType = .pathRestored
                    } else {
                        changeType = .interfaceChanged(from: .unknown, to: .unknown)
                    }
                    
                    let event = NetworkPathEvent(
                        timestamp: Date(),
                        interfaceType: .unknown,  // Linux: cannot determine interface type
                        isConstrained: false,      // Linux: not available
                        isExpensive: false,        // Linux: not available
                        hasIPv4: true,             // Assume IPv4 available
                        hasIPv6: true,             // Assume IPv6 available
                        changeType: changeType
                    )
                    
                    pathContinuation.yield(event)
                    previousInterfaces = currentInterfaces
                }
                
                try? await Task.sleep(nanoseconds: 5_000_000_000)  // Poll every 5 seconds
            }
        }
    }
    
    /// Stop monitoring network path changes.
    public func stopMonitoring() {
        guard isMonitoring else { return }
        isMonitoring = false
        pollingTask?.cancel()
        pollingTask = nil
    }
    
    /// Get AsyncStream of network path events.
    public var events: AsyncStream<NetworkPathEvent> {
        return pathStream
    }
    
    /// Poll /proc/net/dev for interface changes (Linux only).
    private func pollNetworkInterfaces() async -> Set<String> {
        // Read /proc/net/dev and extract interface names
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: "/proc/net/dev")),
              let content = String(data: data, encoding: .utf8) else {
            return []
        }
        
        var interfaces = Set<String>()
        let lines = content.components(separatedBy: .newlines)
        
        for line in lines {
            let parts = line.split(separator: ":", maxSplits: 1)
            if parts.count == 2 {
                let interfaceName = parts[0].trimmingCharacters(in: .whitespaces)
                if !interfaceName.isEmpty && interfaceName != "lo" {
                    interfaces.insert(interfaceName)
                }
            }
        }
        
        return interfaces
    }
    #endif
}
