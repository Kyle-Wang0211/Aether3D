//
// RequestSigner.swift
// Aether3D
//
// Request Signer - HMAC-based request signing with nonce
// 符合 INV-SEC-038 到 INV-SEC-040
//

import Foundation
#if canImport(CryptoKit)
import CryptoKit
#elseif canImport(Crypto)
import Crypto
#endif
import SharedSecurity

/// Request Signer
///
/// Signs API requests with HMAC-SHA256 and includes nonce for replay prevention.
/// 符合 INV-SEC-038: ALL requests MUST be signed
/// 符合 INV-SEC-039: Nonce reuse MUST be rejected
public actor RequestSigner {
    
    // MARK: - Configuration
    
    private let secretKey: SymmetricKey
    private let timestampTolerance: TimeInterval = 300 // 5 minutes
    
    // MARK: - State
    
    /// Track seen nonces (in production, use Redis or similar)
    private var seenNonces: Set<UUID> = []
    private var nonceTimestamps: [UUID: Date] = [:]
    
    // MARK: - Initialization
    
    /// Initialize Request Signer
    /// 
    /// - Parameter secretKey: HMAC secret key (derived from Secure Enclave)
    public init(secretKey: SymmetricKey) {
        self.secretKey = secretKey
    }
    
    // MARK: - Request Signing
    
    /// Sign HTTP request
    /// 
    /// 符合 INV-SEC-038: ALL requests MUST be signed
    /// - Parameters:
    ///   - method: HTTP method (GET, POST, etc.)
    ///   - path: Request path
    ///   - timestamp: Request timestamp
    ///   - body: Request body data
    ///   - nonce: Unique nonce (UUID v4)
    /// - Returns: Signature string
    public func signRequest(method: String, path: String, timestamp: Date, body: Data?, nonce: UUID) -> String {
        // Build signature payload
        // Signature = HMAC-SHA256(method || path || timestamp || nonce || body)
        var payload = Data()
        payload.append(method.data(using: .utf8) ?? Data())
        payload.append(path.data(using: .utf8) ?? Data())
        payload.append(String(timestamp.timeIntervalSince1970).data(using: .utf8) ?? Data())
        payload.append(nonce.uuidString.data(using: .utf8) ?? Data())
        if let body = body {
            payload.append(body)
        }
        
        // Compute HMAC-SHA256
        return CryptoHasher.hmacSHA256(data: payload, key: secretKey)
    }
    
    /// Create signed request headers
    /// 
    /// - Parameters:
    ///   - method: HTTP method
    ///   - path: Request path
    ///   - body: Request body
    /// - Returns: Dictionary of headers including signature, timestamp, and nonce
    public func createSignedHeaders(method: String, path: String, body: Data?) -> [String: String] {
        let timestamp = Date()
        let nonce = UUID()
        
        // Sign request
        let signature = signRequest(method: method, path: path, timestamp: timestamp, body: body, nonce: nonce)
        
        // Create headers
        var headers: [String: String] = [:]
        headers["X-Signature"] = signature
        headers["X-Timestamp"] = String(Int(timestamp.timeIntervalSince1970))
        headers["X-Nonce"] = nonce.uuidString
        
        return headers
    }
    
    // MARK: - Request Verification
    
    /// Verify request signature
    /// 
    /// 符合 INV-SEC-039: Nonce reuse MUST be rejected
    /// - Parameters:
    ///   - method: HTTP method
    ///   - path: Request path
    ///   - timestamp: Request timestamp
    ///   - body: Request body
    ///   - nonce: Request nonce
    ///   - signature: Request signature
    /// - Returns: True if signature is valid
    /// - Throws: RequestSigningError if verification fails
    public func verifyRequest(method: String, path: String, timestamp: Date, body: Data?, nonce: UUID, signature: String) throws -> Bool {
        // Check timestamp freshness
        let now = Date()
        let drift = abs(now.timeIntervalSince(timestamp))
        if drift > timestampTolerance {
            throw RequestSigningError.timestampDriftTooLarge(drift)
        }
        
        // Check nonce reuse
        if seenNonces.contains(nonce) {
            throw RequestSigningError.nonceReused(nonce)
        }
        
        // Verify signature
        let expectedSignature = signRequest(method: method, path: path, timestamp: timestamp, body: body, nonce: nonce)
        guard expectedSignature == signature else {
            throw RequestSigningError.invalidSignature
        }
        
        // Record nonce
        seenNonces.insert(nonce)
        nonceTimestamps[nonce] = timestamp
        
        // Clean up old nonces (older than 10 minutes)
        cleanupOldNonces()
        
        return true
    }
    
    /// Clean up old nonces
    private func cleanupOldNonces() {
        let now = Date()
        let expirationTime: TimeInterval = 600 // 10 minutes
        
        nonceTimestamps = nonceTimestamps.filter { (nonce, timestamp) in
            let age = now.timeIntervalSince(timestamp)
            if age > expirationTime {
                seenNonces.remove(nonce)
                return false
            }
            return true
        }
    }
}

// MARK: - Errors

/// Request signing errors
public enum RequestSigningError: Error, Sendable {
    case timestampDriftTooLarge(TimeInterval)
    case nonceReused(UUID)
    case invalidSignature
    
    public var localizedDescription: String {
        switch self {
        case .timestampDriftTooLarge(let drift):
            return "Timestamp drift too large: \(drift) seconds"
        case .nonceReused(let nonce):
            return "Nonce reused: \(nonce)"
        case .invalidSignature:
            return "Invalid request signature"
        }
    }
}
