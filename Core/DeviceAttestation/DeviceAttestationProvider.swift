//
// DeviceAttestationProvider.swift
// Aether3D
//
// Device Attestation Provider Protocol - Cross-platform attestation abstraction
// 符合 Phase 3: Device Attestation
//

import Foundation

/// Attestation Type
///
/// Type of device attestation.
public enum AttestationType: String, Sendable {
    case appleAppAttest
    case webauthnPacked
    case androidKey
    case tpm
    case none
}

/// Attestation Object
///
/// Attestation object from device attestation provider.
public struct AttestationObject: Sendable {
    public let keyId: String
    public let attestationData: Data // CBOR-encoded
    public let attestationType: AttestationType
    
    public init(keyId: String, attestationData: Data, attestationType: AttestationType) {
        self.keyId = keyId
        self.attestationData = attestationData
        self.attestationType = attestationType
    }
}

/// Assertion Object
///
/// Assertion object for authenticated requests.
public struct AssertionObject: Sendable {
    public let keyId: String
    public let assertionData: Data // CBOR-encoded
    public let counter: UInt64
    
    public init(keyId: String, assertionData: Data, counter: UInt64) {
        self.keyId = keyId
        self.assertionData = assertionData
        self.counter = counter
    }
}

/// Device Attestation Provider Protocol
///
/// Protocol for device attestation providers (Apple App Attest, WebAuthn, etc.).
/// 符合 Phase 3: Device Attestation with protocol abstraction
public protocol DeviceAttestationProvider: Sendable {
    /// Attestation type
    var attestationType: AttestationType { get }
    
    /// Check if attestation is supported
    /// 
    /// - Returns: True if supported
    func isSupported() async -> Bool
    
    /// Generate attestation key
    /// 
    /// - Returns: Key identifier
    /// - Throws: DeviceAttestationError if generation fails
    func generateKey() async throws -> String
    
    /// Attest key with client data hash
    /// 
    /// - Parameters:
    ///   - keyId: Key identifier
    ///   - clientDataHash: Client data hash (32 bytes SHA-256)
    /// - Returns: Attestation object
    /// - Throws: DeviceAttestationError if attestation fails
    func attest(keyId: String, clientDataHash: Data) async throws -> AttestationObject
    
    /// Generate assertion
    /// 
    /// - Parameters:
    ///   - keyId: Key identifier
    ///   - clientDataHash: Client data hash (32 bytes SHA-256)
    /// - Returns: Assertion object
    /// - Throws: DeviceAttestationError if assertion fails
    func assert(keyId: String, clientDataHash: Data) async throws -> AssertionObject
}

/// Device Attestation Errors
public enum DeviceAttestationError: Error, Sendable {
    case notSupported
    case keyGenerationFailed(String)
    case attestationFailed(String)
    case assertionFailed(String)
    case invalidClientDataHash(expected: Int, actual: Int)
    case unknownError(String)
    
    public var localizedDescription: String {
        switch self {
        case .notSupported:
            return "Device attestation is not supported on this platform"
        case .keyGenerationFailed(let reason):
            return "Key generation failed: \(reason)"
        case .attestationFailed(let reason):
            return "Attestation failed: \(reason)"
        case .assertionFailed(let reason):
            return "Assertion failed: \(reason)"
        case .invalidClientDataHash(let expected, let actual):
            return "Invalid client data hash length: expected \(expected), got \(actual)"
        case .unknownError(let reason):
            return "Unknown error: \(reason)"
        }
    }
}
