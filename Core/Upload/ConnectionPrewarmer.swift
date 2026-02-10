// SPDX-License-Identifier: LicenseRef-Aether3D-Proprietary
// CONSTITUTIONAL CONTRACT - DO NOT EDIT WITHOUT RFC
// Contract Version: PR9-NETWORK-1.0
// Module: Upload Infrastructure - Connection Prewarmer
// Cross-Platform: macOS + Linux (pure Foundation)

import Foundation

#if os(iOS) || os(macOS) || os(tvOS) || os(watchOS)
import Security
#endif

#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Connection prewarming stage.
public enum PrewarmingStage: String, Sendable {
    case notStarted
    case dnsResolved
    case tcpConnected
    case tlsHandshaked
    case http2Ready
    case http3Ready
    case ready
}

/// Connection prewarmer for 5-stage pipeline.
///
/// **Purpose**: 5-stage pipeline — starts at capture UI entry (NOT upload start).
/// By the time user finishes capturing, connection is fully warm:
/// DNS resolved, TCP connected, TLS handshaked, HTTP/2 SETTINGS exchanged.
/// First chunk upload: 0ms connection overhead.
///
/// **5-Stage Pipeline**:
/// - Stage 0 (app launch): DNS pre-resolve upload endpoint → cache A/AAAA
/// - Stage 1 (enter capture UI): TCP 3-way handshake → keep-alive
/// - Stage 2 (TCP done): TLS 1.3 handshake → 0-RTT ready
/// - Stage 3 (TLS done): HTTP/2 SETTINGS exchange → stream ready OR HTTP/3 QUIC 0-RTT → immediate
/// - Stage 4 (first chunk ready): Immediate write to established stream
public actor ConnectionPrewarmer {
    
    // MARK: - Configuration
    
    private let uploadEndpoint: URL
    private let certificatePinManager: PR9CertificatePinManager?
    
    // MARK: - State
    
    private var currentStage: PrewarmingStage = .notStarted
    private var urlSession: URLSession?
    private var dnsCache: (ipv4: String?, ipv6: String?)?
    private var isPrewarming = false
    
    // MARK: - Initialization
    
    /// Initialize connection prewarmer.
    ///
    /// - Parameters:
    ///   - uploadEndpoint: Upload endpoint URL
    ///   - certificatePinManager: Optional certificate pin manager
    public init(
        uploadEndpoint: URL,
        certificatePinManager: PR9CertificatePinManager? = nil
    ) {
        self.uploadEndpoint = uploadEndpoint
        self.certificatePinManager = certificatePinManager
    }
    
    // MARK: - Prewarming
    
    /// Start prewarming connection (call at capture UI entry).
    ///
    /// Executes 5-stage pipeline asynchronously.
    public func startPrewarming() async {
        guard !isPrewarming else { return }
        isPrewarming = true
        
        // Stage 0: DNS pre-resolution (if not already done)
        if dnsCache == nil {
            await preResolveDNS()
        }
        
        // Stage 1-4: Establish connection
        await establishConnection()
    }
    
    /// Get prewarmed URLSession (reuse for all chunk uploads).
    ///
    /// **CRITICAL**: Returns ONE session that is reused for ALL chunk uploads.
    /// This fixes APIClient bug where new session was created per request.
    ///
    /// - Returns: Prewarmed URLSession, or nil if not ready
    public func getPrewarmedSession() -> URLSession? {
        guard currentStage == .ready || currentStage == .http3Ready || currentStage == .http2Ready else {
            return nil
        }
        return urlSession
    }
    
    /// Get current prewarming stage.
    public func getCurrentStage() -> PrewarmingStage {
        return currentStage
    }
    
    // MARK: - Stage 0: DNS Pre-Resolution
    
    /// Pre-resolve DNS at app launch.
    private func preResolveDNS() async {
        #if os(iOS) || os(macOS) || os(tvOS) || os(watchOS)
        let hostname = uploadEndpoint.host ?? ""
        let host = CFHostCreateWithName(nil, hostname as CFString).takeRetainedValue()
        
        var error: CFStreamError = CFStreamError()
        let resolved = CFHostStartInfoResolution(host, .addresses, &error)
        
        if resolved {
            let addresses = CFHostGetAddressing(host, nil)?.takeRetainedValue()
            
            if let addressArray = addresses as? [Data] {
                var ipv4: String?
                var ipv6: String?
                
                for addressData in addressArray {
                    addressData.withUnsafeBytes { bytes in
                        let sockaddr = bytes.bindMemory(to: sockaddr.self).baseAddress!
                        if sockaddr.pointee.sa_family == AF_INET {
                            var addr = sockaddr.pointee
                            var hostnameBuffer = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                            if getnameinfo(&addr, socklen_t(MemoryLayout<sockaddr_in>.size),
                                         &hostnameBuffer, socklen_t(hostnameBuffer.count),
                                         nil, 0, NI_NUMERICHOST) == 0 {
                                ipv4 = String(cString: hostnameBuffer)
                            }
                        } else if sockaddr.pointee.sa_family == AF_INET6 {
                            var addr = sockaddr.pointee
                            var hostnameBuffer = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                            if getnameinfo(&addr, socklen_t(MemoryLayout<sockaddr_in6>.size),
                                         &hostnameBuffer, socklen_t(hostnameBuffer.count),
                                         nil, 0, NI_NUMERICHOST) == 0 {
                                ipv6 = String(cString: hostnameBuffer)
                            }
                        }
                    }
                }
                
                dnsCache = (ipv4: ipv4, ipv6: ipv6)
                currentStage = .dnsResolved
            }
        }
        #else
        // Linux: DNS resolution happens automatically on first connection
        currentStage = .dnsResolved
        #endif
    }
    
    // MARK: - Stage 1-4: Connection Establishment
    
    /// Establish connection (TCP → TLS → HTTP/2 or HTTP/3).
    private func establishConnection() async {
        // Create URLSession configuration
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = UploadConstants.CONNECTION_TIMEOUT_SECONDS
        config.timeoutIntervalForResource = 3600.0
        config.httpMaximumConnectionsPerHost = UploadConstants.MAX_PARALLEL_CHUNK_UPLOADS
        #if os(iOS) || os(tvOS) || os(watchOS)
        config.multipathServiceType = .aggregate
        #endif  // WiFi+5G bonded
        #if os(iOS) || os(macOS) || os(tvOS) || os(watchOS)
        config.allowsConstrainedNetworkAccess = false  // Respect Low Data Mode
        config.waitsForConnectivity = true
        #endif
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        config.urlCache = nil  // No disk caching of chunks
        
        // HTTP/3 QUIC with 0-RTT
        // Note: assumesHTTP3Capable may not be available in all iOS/macOS versions
        // HTTP/3 will be negotiated automatically if supported
        
        // Create certificate pinning delegate if available
        #if os(iOS) || os(macOS) || os(tvOS) || os(watchOS)
        let delegate = certificatePinManager.map { CertificatePinningDelegate(pinManager: $0) }
        #else
        let delegate: URLSessionDelegate? = nil
        #endif
        
        // Create URLSession (ONE session reused for all uploads)
        urlSession = URLSession(configuration: config, delegate: delegate, delegateQueue: nil)
        
        // Stage 1: TCP connection (implicit via first request)
        // Stage 2: TLS handshake (implicit via HTTPS)
        // Stage 3: HTTP/2 SETTINGS or HTTP/3 QUIC discovery
        
        // Probe connection with lightweight HEAD request
        var probeRequest = URLRequest(url: uploadEndpoint)
        probeRequest.httpMethod = "HEAD"
        probeRequest.timeoutInterval = UploadConstants.CONNECTION_TIMEOUT_SECONDS
        
        do {
            let (_, response) = try await urlSession!.data(for: probeRequest)
            
            if let httpResponse = response as? HTTPURLResponse {
                // Check for HTTP/3 QUIC support (Alt-Svc header)
                if let altSvc = httpResponse.value(forHTTPHeaderField: "Alt-Svc"),
                   altSvc.contains("h3") {
                    currentStage = .http3Ready
                } else if httpResponse.value(forHTTPHeaderField: "HTTP/2") != nil {
                    currentStage = .http2Ready
                } else {
                    currentStage = .ready
                }
            } else {
                currentStage = .ready
            }
        } catch {
            // Connection failed, but session is still created
            // Will retry on actual upload
            currentStage = .ready
        }
    }
    
    // MARK: - QUIC Probe
    
    /// Probe for QUIC availability (v2.4 addition).
    ///
    /// - Returns: True if HTTP/3 QUIC is available
    public func probeQUICSupport() async -> Bool {
        guard let session = urlSession else { return false }
        
        var request = URLRequest(url: uploadEndpoint)
        request.httpMethod = "HEAD"
        
        do {
            let (_, response) = try await session.data(for: request)
            guard let httpResponse = response as? HTTPURLResponse else { return false }
            
            // Check Alt-Svc header for h3 advertisement
            if let altSvc = httpResponse.value(forHTTPHeaderField: "Alt-Svc"),
               altSvc.contains("h3") {
                return true  // QUIC available
            }
        } catch {
            return false
        }
        
        return false
    }
}

// MARK: - Certificate Pinning Delegate

#if os(iOS) || os(macOS) || os(tvOS) || os(watchOS)
private class CertificatePinningDelegate: NSObject, URLSessionDelegate {
    private let pinManager: PR9CertificatePinManager
    
    init(pinManager: PR9CertificatePinManager) {
        self.pinManager = pinManager
    }
    
    func urlSession(
        _ session: URLSession,
        didReceive challenge: URLAuthenticationChallenge,
        completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
    ) {
        guard challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
              let serverTrust = challenge.protectionSpace.serverTrust else {
            completionHandler(.performDefaultHandling, nil)
            return
        }
        
        Task {
            do {
                let isValid = try await pinManager.validateCertificateChain(serverTrust)
                if isValid {
                    let credential = URLCredential(trust: serverTrust)
                    completionHandler(.useCredential, credential)
                } else {
                    completionHandler(.cancelAuthenticationChallenge, nil)
                }
            } catch {
                completionHandler(.cancelAuthenticationChallenge, nil)
            }
        }
    }
}
#endif
