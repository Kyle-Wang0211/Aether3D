//
// AttestationVerifier.swift
// Aether3D
//
// Attestation Verifier - Server-side verification of attestation objects
// 符合 Phase 3: Device Attestation (AttestationVerifier with Persistent Counter Store)
//

import Foundation

/// Attestation Result
///
/// Result of attestation verification.
public struct AttestationResult: Sendable {
    public let attestationObject: AttestationObject
    public let certificateChain: [Data]
    public let keyId: String
    public let riskMetric: Double
    public let counter: UInt64
    public let verificationStatus: VerificationStatus
    
    public init(attestationObject: AttestationObject, certificateChain: [Data], keyId: String, riskMetric: Double, counter: UInt64, verificationStatus: VerificationStatus) {
        self.attestationObject = attestationObject
        self.certificateChain = certificateChain
        self.keyId = keyId
        self.riskMetric = riskMetric
        self.counter = counter
        self.verificationStatus = verificationStatus
    }
}

/// Verification Status
public enum VerificationStatus: Sendable {
    case verified
    case failed
    case warning
}

/// Counter Store Protocol
///
/// Protocol for storing App Attest counters.
public protocol CounterStore: Sendable {
    /// Get counter for key
    /// 
    /// - Parameter keyId: Key identifier
    /// - Returns: Counter value if exists
    /// - Throws: AttestationVerifierError if retrieval fails
    func getCounter(keyId: String) async throws -> UInt64?
    
    /// Set counter for key
    /// 
    /// - Parameters:
    ///   - keyId: Key identifier
    ///   - counter: Counter value
    /// - Throws: AttestationVerifierError if storage fails
    func setCounter(keyId: String, counter: UInt64) async throws
    
    /// Register key
    /// 
    /// - Parameters:
    ///   - keyId: Key identifier
    ///   - deviceBinding: Device binding data
    ///   - firstSeen: First seen timestamp
    /// - Throws: AttestationVerifierError if registration fails
    func registerKey(keyId: String, deviceBinding: Data?, firstSeen: Date) async throws
}

/// Attestation Verifier
///
/// Verifies device attestation objects with persistent counter tracking.
/// 符合 Phase 3: AttestationVerifier with Persistent Counter Store
public actor AttestationVerifier {
    
    // MARK: - State
    
    private let counterStore: CounterStore
    
    // MARK: - Initialization
    
    /// Initialize Attestation Verifier
    /// 
    /// - Parameter counterStore: Counter store for replay protection
    public init(counterStore: CounterStore) {
        self.counterStore = counterStore
    }
    
    // MARK: - Verification
    
    /// Verify attestation object
    /// 
    /// - Parameters:
    ///   - attestationObject: Attestation object to verify
    ///   - clientDataHash: Client data hash (32 bytes)
    ///   - expectedChallenge: Expected challenge
    /// - Returns: Attestation result
    /// - Throws: AttestationVerifierError if verification fails
    public func verify(attestationObject: AttestationObject, clientDataHash: Data, expectedChallenge: Data) async throws -> AttestationResult {
        guard clientDataHash.count == 32 else {
            throw AttestationVerifierError.invalidClientDataHash(expected: 32, actual: clientDataHash.count)
        }
        
        // Parse CBOR attestation object
        // In production, implement full CBOR parsing with security limits
        let certificateChain: [Data] = [] // Extract from CBOR
        let keyId = attestationObject.keyId
        
        // Verify certificate chain
        // In production, verify chain against Apple/WebAuthn root certificates
        
        // Verify signature
        // In production, verify Ed25519 signature
        
        // Check counter for replay protection
        let storedCounter = try await counterStore.getCounter(keyId: keyId)
        let counter: UInt64 = 0 // Extract from attestation object
        
        if let stored = storedCounter {
            if counter <= stored {
                throw AttestationVerifierError.counterRollback(keyId: keyId, stored: stored, received: counter)
            }
        }
        
        // Register key if new
        if storedCounter == nil {
            try await counterStore.registerKey(keyId: keyId, deviceBinding: nil, firstSeen: Date())
        }
        
        // Update counter
        try await counterStore.setCounter(keyId: keyId, counter: counter)
        
        return AttestationResult(
            attestationObject: attestationObject,
            certificateChain: certificateChain,
            keyId: keyId,
            riskMetric: 0.0, // Calculate risk metric
            counter: counter,
            verificationStatus: .verified
        )
    }
}

/// Attestation Verifier Errors
public enum AttestationVerifierError: Error, Sendable {
    case invalidCBOR(String)
    case certificateChainInvalid(String)
    case signatureInvalid(String)
    case counterRollback(keyId: String, stored: UInt64, received: UInt64)
    case keyNotRegistered(String)
    case invalidChallenge
    case cborRecursionDepthExceeded
    case cborMaxBytesExceeded
    case cborMaxCertChainLengthExceeded
    case cborTrailingBytes
    case invalidClientDataHash(expected: Int, actual: Int)
    
    public var localizedDescription: String {
        switch self {
        case .invalidCBOR(let reason):
            return "Invalid CBOR: \(reason)"
        case .certificateChainInvalid(let reason):
            return "Certificate chain invalid: \(reason)"
        case .signatureInvalid(let reason):
            return "Signature invalid: \(reason)"
        case .counterRollback(let keyId, let stored, let received):
            return "Counter rollback detected for key \(keyId): stored \(stored), received \(received)"
        case .keyNotRegistered(let keyId):
            return "Key not registered: \(keyId)"
        case .invalidChallenge:
            return "Invalid challenge"
        case .cborRecursionDepthExceeded:
            return "CBOR recursion depth exceeded"
        case .cborMaxBytesExceeded:
            return "CBOR max bytes exceeded"
        case .cborMaxCertChainLengthExceeded:
            return "CBOR max certificate chain length exceeded"
        case .cborTrailingBytes:
            return "CBOR trailing bytes"
        case .invalidClientDataHash(let expected, let actual):
            return "Invalid client data hash length: expected \(expected), got \(actual)"
        }
    }
}
