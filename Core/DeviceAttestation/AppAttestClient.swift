//
// AppAttestClient.swift
// Aether3D
//
// Apple App Attest Client - DeviceCheck.DCAppAttestService implementation
// 符合 Phase 3: Device Attestation (Apple App Attest)
//

import Foundation

#if canImport(DeviceCheck)
import DeviceCheck

/// Apple App Attest Client
///
/// Implements Apple App Attest using DeviceCheck.DCAppAttestService.
/// 符合 Phase 3: Device Attestation (Apple App Attest)
public actor AppAttestClient: DeviceAttestationProvider {
    
    // MARK: - Properties
    
    public let attestationType: AttestationType = .appleAppAttest
    
    private let service: DCAppAttestService
    
    // MARK: - Initialization
    
    /// Initialize App Attest Client
    public init() {
        self.service = DCAppAttestService.shared
    }
    
    // MARK: - Device Attestation Provider
    
    /// Check if App Attest is supported
    /// 
    /// - Returns: True if supported
    public func isSupported() async -> Bool {
        return service.isSupported
    }
    
    /// Generate attestation key
    /// 
    /// - Returns: Key identifier
    /// - Throws: DeviceAttestationError if generation fails
    public func generateKey() async throws -> String {
        guard await isSupported() else {
            throw DeviceAttestationError.notSupported
        }
        
        return try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<String, Error>) in
            service.generateKey { keyId, error in
                if let error = error {
                    continuation.resume(throwing: DeviceAttestationError.keyGenerationFailed(error.localizedDescription))
                } else if let keyId = keyId {
                    continuation.resume(returning: keyId)
                } else {
                    continuation.resume(throwing: DeviceAttestationError.unknownError("No key ID returned"))
                }
            }
        }
    }
    
    /// Attest key with client data hash
    /// 
    /// - Parameters:
    ///   - keyId: Key identifier
    ///   - clientDataHash: Client data hash (32 bytes SHA-256)
    /// - Returns: Attestation object
    /// - Throws: DeviceAttestationError if attestation fails
    public func attest(keyId: String, clientDataHash: Data) async throws -> AttestationObject {
        guard clientDataHash.count == 32 else {
            throw DeviceAttestationError.invalidClientDataHash(expected: 32, actual: clientDataHash.count)
        }
        
        guard await isSupported() else {
            throw DeviceAttestationError.notSupported
        }
        
        let attestationData = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Data, Error>) in
            service.attestKey(keyId, clientDataHash: clientDataHash) { attestationObject, error in
                if let error = error {
                    continuation.resume(throwing: DeviceAttestationError.attestationFailed(error.localizedDescription))
                } else if let attestationObject = attestationObject {
                    continuation.resume(returning: attestationObject)
                } else {
                    continuation.resume(throwing: DeviceAttestationError.unknownError("No attestation object returned"))
                }
            }
        }
        
        return AttestationObject(
            keyId: keyId,
            attestationData: attestationData,
            attestationType: .appleAppAttest
        )
    }
    
    /// Generate assertion
    /// 
    /// - Parameters:
    ///   - keyId: Key identifier
    ///   - clientDataHash: Client data hash (32 bytes SHA-256)
    /// - Returns: Assertion object
    /// - Throws: DeviceAttestationError if assertion fails
    public func assert(keyId: String, clientDataHash: Data) async throws -> AssertionObject {
        guard clientDataHash.count == 32 else {
            throw DeviceAttestationError.invalidClientDataHash(expected: 32, actual: clientDataHash.count)
        }
        
        guard await isSupported() else {
            throw DeviceAttestationError.notSupported
        }
        
        let assertionData = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Data, Error>) in
            service.generateAssertion(keyId, clientDataHash: clientDataHash) { assertionObject, error in
                if let error = error {
                    continuation.resume(throwing: DeviceAttestationError.assertionFailed(error.localizedDescription))
                } else if let assertionObject = assertionObject {
                    continuation.resume(returning: assertionObject)
                } else {
                    continuation.resume(throwing: DeviceAttestationError.unknownError("No assertion object returned"))
                }
            }
        }
        
        // Get counter from Secure Enclave Key Manager
        let counter = try await SecureEnclaveKeyManager().getAppAttestCounter()
        
        return AssertionObject(
            keyId: keyId,
            assertionData: assertionData,
            counter: counter
        )
    }
}

#else

/// Apple App Attest Client (stub for non-iOS platforms)
public actor AppAttestClient: DeviceAttestationProvider {
    public let attestationType: AttestationType = .appleAppAttest
    
    public func isSupported() async -> Bool {
        return false
    }
    
    public func generateKey() async throws -> String {
        throw DeviceAttestationError.notSupported
    }
    
    public func attest(keyId: String, clientDataHash: Data) async throws -> AttestationObject {
        throw DeviceAttestationError.notSupported
    }
    
    public func assert(keyId: String, clientDataHash: Data) async throws -> AssertionObject {
        throw DeviceAttestationError.notSupported
    }
}

#endif
