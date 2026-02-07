//
// APIClient.swift
// Aether3D
//
// API Client - HTTP client with request signing, certificate pinning, and rate limiting
// 符合 PR3: API Contract
//

import Foundation

// APIClient uses CertificatePinningManager which requires Security framework (Apple only)
#if os(iOS) || os(macOS) || os(tvOS) || os(watchOS)

#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import Security
import SharedSecurity

/// API Client
///
/// HTTP client with request signing, certificate pinning, and rate limiting.
public actor APIClient {
    
    // MARK: - Configuration
    
    private let baseURL: URL
    private let requestSigner: RequestSigner
    private let certificatePinningManager: CertificatePinningManager
    private let rateLimitManager: RateLimitManager
    private let idempotencyHandler: IdempotencyHandler
    
    // MARK: - Initialization
    
    /// Initialize API Client
    /// 
    /// - Parameters:
    ///   - baseURL: Base URL for API
    ///   - requestSigner: Request signer for HMAC signing
    ///   - certificatePinningManager: Certificate pinning manager
    ///   - rateLimitManager: Rate limit manager
    ///   - idempotencyHandler: Idempotency handler
    public init(
        baseURL: URL,
        requestSigner: RequestSigner,
        certificatePinningManager: CertificatePinningManager,
        rateLimitManager: RateLimitManager,
        idempotencyHandler: IdempotencyHandler
    ) {
        self.baseURL = baseURL
        self.requestSigner = requestSigner
        self.certificatePinningManager = certificatePinningManager
        self.rateLimitManager = rateLimitManager
        self.idempotencyHandler = idempotencyHandler
    }
    
    // MARK: - Request Execution
    
    /// Execute API request
    /// 
    /// - Parameters:
    ///   - endpoint: API endpoint
    ///   - method: HTTP method
    ///   - body: Request body
    ///   - idempotencyKey: Idempotency key (required for mutations)
    /// - Returns: Response data and status code
    /// - Throws: APIError if request fails
    public func executeRequest(
        endpoint: String,
        method: String,
        body: Data? = nil,
        idempotencyKey: String? = nil
    ) async throws -> (data: Data, statusCode: Int) {
        // Check idempotency for mutations
        if ["POST", "PUT", "PATCH", "DELETE"].contains(method.uppercased()),
           let key = idempotencyKey {
            if let cached = await idempotencyHandler.checkIdempotency(key: key) {
                return (data: cached.response, statusCode: cached.statusCode)
            }
        }
        
        // Check rate limit
        let (allowed, rateLimitHeaders) = await rateLimitManager.checkRateLimit(
            endpoint: endpoint,
            limit: RateLimitManager.DefaultLimits.jobsPerMinute
        )
        
        guard allowed else {
            throw APIError(
                code: .rateLimited,
                message: "Rate limit exceeded",
                details: ["retry_after": .int(rateLimitHeaders.retryAfter ?? 60)]
            )
        }
        
        // Create request
        let url = baseURL.appendingPathComponent(endpoint)
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.httpBody = body
        
        // Add signed headers
        let signedHeaders = await requestSigner.createSignedHeaders(method: method, path: endpoint, body: body)
        for (key, value) in signedHeaders {
            request.setValue(value, forHTTPHeaderField: key)
        }
        
        // Add idempotency key if provided
        if let idempotencyKey = idempotencyKey {
            request.setValue(idempotencyKey, forHTTPHeaderField: "Idempotency-Key")
        }
        
        // Execute request with certificate pinning
        let (data, response) = try await executeWithCertificatePinning(request: request)
        
        guard let httpResponse = response as? HTTPURLResponse else {
            throw APIError(code: .internalError, message: "Invalid response type")
        }
        
        // Store idempotency key if mutation
        if ["POST", "PUT", "PATCH", "DELETE"].contains(method.uppercased()),
           let idempotencyKey = idempotencyKey {
            await idempotencyHandler.storeIdempotency(key: idempotencyKey, response: data, statusCode: httpResponse.statusCode)
        }
        
        return (data: data, statusCode: httpResponse.statusCode)
    }
    
    /// Execute request with certificate pinning
    /// 
    /// - Parameter request: URL request
    /// - Returns: Response data and URL response
    /// - Throws: APIError if certificate pinning fails
    private func executeWithCertificatePinning(request: URLRequest) async throws -> (Data, URLResponse) {
        // Create URLSession with certificate pinning delegate
        let configuration = URLSessionConfiguration.default
        let session = URLSession(configuration: configuration, delegate: CertificatePinningDelegate(certificatePinningManager: certificatePinningManager), delegateQueue: nil)
        
        let (data, response) = try await session.data(for: request)
        
        return (data, response)
    }
}

/// Certificate Pinning Delegate
private class CertificatePinningDelegate: NSObject, URLSessionDelegate {
    private let certificatePinningManager: CertificatePinningManager

    init(certificatePinningManager: CertificatePinningManager) {
        self.certificatePinningManager = certificatePinningManager
    }

    func urlSession(_ session: URLSession, didReceive challenge: URLAuthenticationChallenge, completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        guard let serverTrust = challenge.protectionSpace.serverTrust else {
            completionHandler(.cancelAuthenticationChallenge, nil)
            return
        }

        Task {
            do {
                let isValid = try await certificatePinningManager.validateCertificateChain(serverTrust)
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

#endif // os(iOS) || os(macOS) || os(tvOS) || os(watchOS)
