import XCTest
@testable import Aether3DCore
#if canImport(CryptoKit)
import CryptoKit
#endif
#if canImport(CommonCrypto)
import CommonCrypto
#endif

final class PolicyHashGateTests: XCTestCase {
    /// Golden Policy Hash (SHA256 of POLICY_SNAPSHOT.json)
    /// This hash must match the hash of InvariantPolicies.default
    /// Any change to policies requires RFC and hash update
    private let GOLDEN_POLICY_HASH = "ba253f1631a819f4f558c4c5994b8f170ac9c9cec0060f0da800b5f8656c4516"
    
    func testPolicyHashCalculation() throws {
        let policies = InvariantPolicies.default
        let calculatedHash = try PolicyHash.calculate(policies: policies)
        
        // Hash must be 64 characters (SHA256 hex)
        XCTAssertEqual(calculatedHash.count, 64, "Policy hash must be 64 hex characters")
        
        // Verify it's valid hex
        let hexCharacterSet = CharacterSet(charactersIn: "0123456789abcdef")
        XCTAssertTrue(
            calculatedHash.unicodeScalars.allSatisfy { hexCharacterSet.contains($0) },
            "Policy hash must be valid hex string"
        )
    }
    
    func testPolicyHashMatchesGolden() throws {
        let policies = InvariantPolicies.default
        let calculatedHash = try PolicyHash.calculate(policies: policies)
        
        // Calculate actual hash from snapshot file
        let snapshotPath = "docs/constitution/POLICY_SNAPSHOT.json"
        let fileManager = FileManager.default
        let currentDir = fileManager.currentDirectoryPath
        let fullPath = "\(currentDir)/\(snapshotPath)"
        
        guard let snapshotData = fileManager.contents(atPath: fullPath) else {
            XCTFail("Failed to read POLICY_SNAPSHOT.json")
            return
        }
        
        // Generate JSON from policies to compare
        let generatedJSON = try StableJSONEncoder.encode(policies)
        let generatedData = generatedJSON.data(using: .utf8)!
        let generatedHash = try calculateHashFromData(generatedData)
        
        let snapshotHash = try calculateHashFromData(snapshotData)
        
        
        // Both hashes should match
        XCTAssertEqual(generatedHash, snapshotHash, "Generated JSON hash must match snapshot hash")
        XCTAssertEqual(calculatedHash, snapshotHash, "Calculated hash must match snapshot hash")
        
        // Set GOLDEN_POLICY_HASH to the correct value
        XCTAssertEqual(calculatedHash, GOLDEN_POLICY_HASH, "Calculated hash must match GOLDEN_POLICY_HASH")
    }
    
    private func calculateHashFromData(_ data: Data) throws -> String {
        #if canImport(CryptoKit)
        let hash = SHA256.hash(data: data)
        return hash.compactMap { String(format: "%02x", $0) }.joined()
        #else
        // Fallback implementation
        var hash = [UInt8](repeating: 0, count: 32)
        #if canImport(CommonCrypto)
        data.withUnsafeBytes { bytes in
            _ = CC_SHA256(bytes.baseAddress, CC_LONG(data.count), &hash)
        }
        #else
        hash = Array(data.prefix(32))
        #endif
        return hash.map { String(format: "%02x", $0) }.joined()
        #endif
    }
}

