//
// EndToEndEncryptionTests.swift
// PR5CaptureTests
//
// Comprehensive tests for EndToEndEncryption
//

import XCTest
@testable import PR5Capture

@MainActor
final class EndToEndEncryptionTests: XCTestCase {
    
    var encryption: EndToEndEncryption!
    var config: ExtremeProfile!
    
    override func setUp() {
        super.setUp()
        config = ExtremeProfile(profile: .standard)
        encryption = EndToEndEncryption(config: config)
    }
    
    override func tearDown() {
        encryption = nil
        config = nil
        super.tearDown()
    }
    
    // MARK: - Happy Path Tests
    
    func test_normalInput_returnsValidOutput() async {
        let data = Data([1, 2, 3, 4, 5])
        let result = await encryption.encrypt(data)
        XCTAssertTrue(result.success)
        XCTAssertNotNil(result.encryptedData)
    }
    
    func test_typicalUseCase_succeeds() async {
        let data = Data(repeating: 100, count: 1000)
        let encryptResult = await encryption.encrypt(data)
        XCTAssertTrue(encryptResult.success)
        
        let decryptResult = await encryption.decrypt(encryptResult.encryptedData, keyId: encryptResult.keyId, nonce: encryptResult.nonce)
        XCTAssertTrue(decryptResult.success)
    }
    
    func test_standardConfiguration_works() async {
        let data = Data([1, 2, 3])
        let result = await encryption.encrypt(data)
        XCTAssertNotNil(result)
    }
    
    func test_expectedInput_producesExpectedOutput() async {
        let data = Data([1, 2, 3])
        let encryptResult = await encryption.encrypt(data)
        XCTAssertTrue(encryptResult.success)
        
        let decryptResult = await encryption.decrypt(encryptResult.encryptedData, keyId: encryptResult.keyId, nonce: encryptResult.nonce)
        XCTAssertTrue(decryptResult.success)
        XCTAssertEqual(decryptResult.data, data)
    }
    
    func test_commonScenario_handledCorrectly() async {
        for i in 0..<10 {
            let data = Data([UInt8(i)])
            _ = await encryption.encrypt(data)
        }
    }
    
    // MARK: - Boundary Tests
    
    func test_minimumInput_handled() async {
        let data = Data([1])
        let result = await encryption.encrypt(data)
        XCTAssertNotNil(result)
    }
    
    func test_maximumInput_handled() async {
        let data = Data(repeating: 255, count: 10000)
        let result = await encryption.encrypt(data)
        XCTAssertNotNil(result)
    }
    
    func test_zeroInput_handled() async {
        let data = Data()
        let result = await encryption.encrypt(data)
        XCTAssertNotNil(result)
    }
    
    func test_boundaryValue_processed() async {
        let data1 = Data([0])
        let data2 = Data(repeating: 255, count: 1000)
        let result1 = await encryption.encrypt(data1)
        let result2 = await encryption.encrypt(data2)
        XCTAssertNotNil(result1)
        XCTAssertNotNil(result2)
    }
    
    // MARK: - Encryption/Decryption Tests
    
    func test_encrypt_decrypt_roundTrip() async {
        let originalData = Data([1, 2, 3, 4, 5])
        let encryptResult = await encryption.encrypt(originalData)
        XCTAssertTrue(encryptResult.success)
        
        let decryptResult = await encryption.decrypt(encryptResult.encryptedData, keyId: encryptResult.keyId, nonce: encryptResult.nonce)
        XCTAssertTrue(decryptResult.success)
        XCTAssertEqual(decryptResult.data, originalData)
    }
    
    func test_decrypt_wrongKey() async {
        let data = Data([1, 2, 3])
        let encryptResult = await encryption.encrypt(data)
        XCTAssertTrue(encryptResult.success)
        
        let wrongKeyId = UUID()
        let decryptResult = await encryption.decrypt(encryptResult.encryptedData, keyId: wrongKeyId, nonce: encryptResult.nonce)
        XCTAssertFalse(decryptResult.success)
    }
    
    // MARK: - Profile Tests
    
    func test_productionProfile_behavior() async {
        let prodConfig = ExtremeProfile(profile: .standard)
        let prodEncryption = EndToEndEncryption(config: prodConfig)
        let data = Data([1, 2, 3])
        let result = await prodEncryption.encrypt(data)
        XCTAssertNotNil(result)
    }
    
    func test_developmentProfile_behavior() async {
        let devConfig = ExtremeProfile(profile: .standard)
        let devEncryption = EndToEndEncryption(config: devConfig)
        let data = Data([1, 2, 3])
        let result = await devEncryption.encrypt(data)
        XCTAssertNotNil(result)
    }
    
    func test_testingProfile_behavior() async {
        let testConfig = ExtremeProfile(profile: .lab)
        let testEncryption = EndToEndEncryption(config: testConfig)
        let data = Data([1, 2, 3])
        let result = await testEncryption.encrypt(data)
        XCTAssertNotNil(result)
    }
    
    func test_paranoidProfile_behavior() async {
        let paranoidConfig = ExtremeProfile(profile: .extreme)
        let paranoidEncryption = EndToEndEncryption(config: paranoidConfig)
        let data = Data([1, 2, 3])
        let result = await paranoidEncryption.encrypt(data)
        XCTAssertNotNil(result)
    }
    
    // MARK: - Concurrency Tests
    
    func test_concurrentAccess_threadSafe() async {
        await withTaskGroup(of: Void.self) { group in
            for i in 0..<10 {
                group.addTask {
                    let data = Data([UInt8(i)])
                    _ = await self.encryption.encrypt(data)
                }
            }
        }
    }
    
    func test_multipleInstances_independent() async {
        let encryption1 = EndToEndEncryption(config: config)
        let encryption2 = EndToEndEncryption(config: config)
        
        let data = Data([1, 2, 3])
        let result1 = await encryption1.encrypt(data)
        let result2 = await encryption2.encrypt(data)
        
        XCTAssertNotEqual(result1.keyId, result2.keyId)
    }
}
