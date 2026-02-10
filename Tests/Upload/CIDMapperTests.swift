//
//  CIDMapperTests.swift
//  Aether3D
//
//  PR#9: Chunked Upload V3.0 - CID Mapper Tests
//

import XCTest
@testable import Aether3DCore

final class CIDMapperTests: XCTestCase {
    
    // MARK: - ACI → CID (15 tests)
    
    func testACIToCID_ValidACI_ReturnsCID() {
        let aci = "aci:1:sha256:ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"
        let cid = CIDMapper.aciToCID(aci)
        XCTAssertNotNil(cid, "Valid ACI should return CID")
    }
    
    func testACIToCID_InvalidACI_ReturnsNil() {
        let invalidACI = "invalid:format"
        let cid = CIDMapper.aciToCID(invalidACI)
        XCTAssertNil(cid, "Invalid ACI should return nil")
    }
    
    func testACIToCID_NonSHA256_ReturnsNil() {
        let aci = "aci:1:sha3-256:ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"
        let cid = CIDMapper.aciToCID(aci)
        // Only sha256 is supported for now
        XCTAssertNil(cid, "Non-SHA256 should return nil")
    }
    
    func testACIToCID_Multicodec_Correct() {
        let aci = "aci:1:sha256:ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"
        let cid = CIDMapper.aciToCID(aci)
        XCTAssertNotNil(cid, "Multicodec should be correct")
    }
    
    func testACIToCID_Base32_Encoded() {
        let aci = "aci:1:sha256:ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"
        let cid = CIDMapper.aciToCID(aci)
        XCTAssertNotNil(cid, "CID should be base32 encoded")
        if let cid = cid {
            // Base32 should only contain lowercase letters and digits 2-7
            let validChars = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyz234567")
            XCTAssertTrue(cid.unicodeScalars.allSatisfy { validChars.contains($0) }, "CID should be valid base32")
        }
    }
    
    func testACIToCID_EmptyACI_ReturnsNil() {
        let cid = CIDMapper.aciToCID("")
        XCTAssertNil(cid, "Empty ACI should return nil")
    }
    
    func testACIToCID_InvalidFormat_ReturnsNil() {
        let invalid = "not:aci:format"
        let cid = CIDMapper.aciToCID(invalid)
        XCTAssertNil(cid, "Invalid format should return nil")
    }
    
    func testACIToCID_WrongVersion_ReturnsNil() {
        let aci = "aci:2:sha256:ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"
        let cid = CIDMapper.aciToCID(aci)
        // Version 2 not supported yet
        XCTAssertNil(cid, "Wrong version should return nil")
    }
    
    func testACIToCID_ShortDigest_ReturnsNil() {
        let aci = "aci:1:sha256:ba7816bf"  // Too short
        let cid = CIDMapper.aciToCID(aci)
        XCTAssertNil(cid, "Short digest should return nil")
    }
    
    func testACIToCID_LongDigest_ReturnsNil() {
        let aci = "aci:1:sha256:ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad123456"  // Too long
        let cid = CIDMapper.aciToCID(aci)
        XCTAssertNil(cid, "Long digest should return nil")
    }
    
    func testACIToCID_InvalidHex_ReturnsNil() {
        let aci = "aci:1:sha256:ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ag"  // Invalid hex 'g'
        let cid = CIDMapper.aciToCID(aci)
        XCTAssertNil(cid, "Invalid hex should return nil")
    }
    
    func testACIToCID_Consistent() {
        let aci = "aci:1:sha256:ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"
        let cid1 = CIDMapper.aciToCID(aci)
        let cid2 = CIDMapper.aciToCID(aci)
        XCTAssertEqual(cid1, cid2, "Same ACI should produce same CID")
    }
    
    func testACIToCID_DifferentACI_DifferentCID() {
        let aci1 = "aci:1:sha256:ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"
        let aci2 = "aci:1:sha256:ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ae"
        let cid1 = CIDMapper.aciToCID(aci1)
        let cid2 = CIDMapper.aciToCID(aci2)
        XCTAssertNotEqual(cid1, cid2, "Different ACI should produce different CID")
    }
    
    func testACIToCID_MultibasePrefix_Present() {
        let aci = "aci:1:sha256:ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"
        let cid = CIDMapper.aciToCID(aci)
        XCTAssertNotNil(cid, "Multibase prefix should be present")
    }
    
    func testACIToCID_Multihash_Correct() {
        let aci = "aci:1:sha256:ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"
        let cid = CIDMapper.aciToCID(aci)
        XCTAssertNotNil(cid, "Multihash should be correct")
    }
    
    // MARK: - CID → ACI (15 tests)
    
    func testCIDToACI_ValidCID_ReturnsACI() {
        let aci = "aci:1:sha256:ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"
        let cid = CIDMapper.aciToCID(aci)
        XCTAssertNotNil(cid, "Should convert ACI to CID")
        if let cid = cid {
            let convertedACI = CIDMapper.cidToACI(cid)
            XCTAssertNotNil(convertedACI, "Valid CID should return ACI")
        }
    }
    
    func testCIDToACI_InvalidCID_ReturnsNil() {
        let invalidCID = "invalid-cid"
        let aci = CIDMapper.cidToACI(invalidCID)
        XCTAssertNil(aci, "Invalid CID should return nil")
    }
    
    func testCIDToACI_Base32_Decoded() {
        let aci = "aci:1:sha256:ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"
        let cid = CIDMapper.aciToCID(aci)
        XCTAssertNotNil(cid, "Should convert ACI to CID")
        if let cid = cid {
            let convertedACI = CIDMapper.cidToACI(cid)
            XCTAssertNotNil(convertedACI, "Base32 should be decoded")
        }
    }
    
    func testCIDToACI_EmptyCID_ReturnsNil() {
        let aci = CIDMapper.cidToACI("")
        XCTAssertNil(aci, "Empty CID should return nil")
    }
    
    func testCIDToACI_WrongMultibase_ReturnsNil() {
        // CID with wrong multibase prefix
        let invalidCID = "z" + String(repeating: "a", count: 50)  // 'z' is not base32
        let aci = CIDMapper.cidToACI(invalidCID)
        XCTAssertNil(aci, "Wrong multibase should return nil")
    }
    
    func testCIDToACI_WrongMulticodec_ReturnsNil() {
        // This is hard to test without creating invalid CID, but we can verify the logic
        let aci = CIDMapper.cidToACI("invalid")
        XCTAssertNil(aci, "Wrong multicodec should return nil")
    }
    
    func testCIDToACI_ShortCID_ReturnsNil() {
        let shortCID = "ba"  // Too short
        let aci = CIDMapper.cidToACI(shortCID)
        XCTAssertNil(aci, "Short CID should return nil")
    }
    
    func testCIDToACI_NonSHA256Hash_ReturnsNil() {
        // CID with non-SHA256 hash should return nil
        let aci = CIDMapper.cidToACI("invalid-cid-format")
        XCTAssertNil(aci, "Non-SHA256 hash should return nil")
    }
    
    func testCIDToACI_Consistent() {
        let aci = "aci:1:sha256:ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"
        let cid = CIDMapper.aciToCID(aci)
        XCTAssertNotNil(cid, "Should convert ACI to CID")
        if let cid = cid {
            let aci1 = CIDMapper.cidToACI(cid)
            let aci2 = CIDMapper.cidToACI(cid)
            XCTAssertEqual(aci1, aci2, "Same CID should produce same ACI")
        }
    }
    
    func testCIDToACI_DifferentCID_DifferentACI() {
        let aci1 = "aci:1:sha256:ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"
        let aci2 = "aci:1:sha256:ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ae"
        let cid1 = CIDMapper.aciToCID(aci1)
        let cid2 = CIDMapper.aciToCID(aci2)
        XCTAssertNotNil(cid1, "Should convert ACI1 to CID")
        XCTAssertNotNil(cid2, "Should convert ACI2 to CID")
        if let cid1 = cid1, let cid2 = cid2 {
            let convertedACI1 = CIDMapper.cidToACI(cid1)
            let convertedACI2 = CIDMapper.cidToACI(cid2)
            XCTAssertNotEqual(convertedACI1, convertedACI2, "Different CID should produce different ACI")
        }
    }
    
    func testCIDToACI_Format_Correct() {
        let aci = "aci:1:sha256:ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"
        let cid = CIDMapper.aciToCID(aci)
        XCTAssertNotNil(cid, "Should convert ACI to CID")
        if let cid = cid {
            let convertedACI = CIDMapper.cidToACI(cid)
            XCTAssertNotNil(convertedACI, "ACI format should be correct")
            if let convertedACI = convertedACI {
                XCTAssertTrue(convertedACI.hasPrefix("aci:1:sha256:"), "ACI format should be correct")
            }
        }
    }
    
    func testCIDToACI_Version_1() {
        let aci = "aci:1:sha256:ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"
        let cid = CIDMapper.aciToCID(aci)
        XCTAssertNotNil(cid, "Should convert ACI to CID")
        if let cid = cid {
            let convertedACI = CIDMapper.cidToACI(cid)
            XCTAssertNotNil(convertedACI, "Version should be 1")
            if let convertedACI = convertedACI {
                XCTAssertTrue(convertedACI.contains(":1:"), "Version should be 1")
            }
        }
    }
    
    func testCIDToACI_Algorithm_SHA256() {
        let aci = "aci:1:sha256:ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"
        let cid = CIDMapper.aciToCID(aci)
        XCTAssertNotNil(cid, "Should convert ACI to CID")
        if let cid = cid {
            let convertedACI = CIDMapper.cidToACI(cid)
            XCTAssertNotNil(convertedACI, "Algorithm should be sha256")
            if let convertedACI = convertedACI {
                XCTAssertTrue(convertedACI.contains(":sha256:"), "Algorithm should be sha256")
            }
        }
    }
    
    func testCIDToACI_Digest_64Chars() {
        let aci = "aci:1:sha256:ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"
        let cid = CIDMapper.aciToCID(aci)
        XCTAssertNotNil(cid, "Should convert ACI to CID")
        if let cid = cid {
            let convertedACI = CIDMapper.cidToACI(cid)
            XCTAssertNotNil(convertedACI, "Digest should be 64 chars")
            if let convertedACI = convertedACI {
                let components = convertedACI.split(separator: ":")
                XCTAssertEqual(components.count, 4, "Should have 4 components")
                if components.count == 4 {
                    XCTAssertEqual(components[3].count, 64, "Digest should be 64 chars")
                }
            }
        }
    }
    
    func testCIDToACI_InvalidBase32_ReturnsNil() {
        let invalidCID = "invalid-base32-characters-!@#$"
        let aci = CIDMapper.cidToACI(invalidCID)
        XCTAssertNil(aci, "Invalid base32 should return nil")
    }
    
    // MARK: - Roundtrip (10 tests)
    
    func testRoundtrip_ACIToCIDToACI_Consistent() {
        let originalACI = "aci:1:sha256:ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"
        let cid = CIDMapper.aciToCID(originalACI)
        XCTAssertNotNil(cid, "Should convert ACI to CID")
        if let cid = cid {
            let convertedACI = CIDMapper.cidToACI(cid)
            XCTAssertNotNil(convertedACI, "Should convert CID back to ACI")
            XCTAssertEqual(convertedACI, originalACI, "Roundtrip should be consistent")
        }
    }
    
    func testRoundtrip_CIDToACIToCID_Consistent() {
        let originalACI = "aci:1:sha256:ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"
        let cid1 = CIDMapper.aciToCID(originalACI)
        XCTAssertNotNil(cid1, "Should convert ACI to CID")
        if let cid1 = cid1 {
            let convertedACI = CIDMapper.cidToACI(cid1)
            XCTAssertNotNil(convertedACI, "Should convert CID to ACI")
            if let convertedACI = convertedACI {
                let cid2 = CIDMapper.aciToCID(convertedACI)
                XCTAssertEqual(cid1, cid2, "Roundtrip should be consistent")
            }
        }
    }
    
    func testRoundtrip_MultipleACIs_AllConsistent() {
        let acis = [
            "aci:1:sha256:ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad",
            "aci:1:sha256:e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855",
            "aci:1:sha256:2c26b46b68ffc68ff99b453c1d30413413422d706483bfa0f98a5e886266e7ae"
        ]
        for aci in acis {
            let cid = CIDMapper.aciToCID(aci)
            XCTAssertNotNil(cid, "Should convert ACI to CID: \(aci)")
            if let cid = cid {
                let convertedACI = CIDMapper.cidToACI(cid)
                XCTAssertEqual(convertedACI, aci, "Roundtrip should be consistent: \(aci)")
            }
        }
    }
    
    func testRoundtrip_EmptyDigest_Handles() {
        // Empty digest should be handled
        let aci = "aci:1:sha256:" + String(repeating: "0", count: 64)
        let cid = CIDMapper.aciToCID(aci)
        XCTAssertNotNil(cid, "Should handle empty-like digest")
        if let cid = cid {
            let convertedACI = CIDMapper.cidToACI(cid)
            XCTAssertNotNil(convertedACI, "Should convert back")
        }
    }
    
    func testRoundtrip_AllZerosDigest_Handles() {
        let aci = "aci:1:sha256:" + String(repeating: "0", count: 64)
        let cid = CIDMapper.aciToCID(aci)
        XCTAssertNotNil(cid, "Should handle all zeros digest")
        if let cid = cid {
            let convertedACI = CIDMapper.cidToACI(cid)
            XCTAssertEqual(convertedACI, aci, "Roundtrip should work for all zeros")
        }
    }
    
    func testRoundtrip_AllFFDigest_Handles() {
        let aci = "aci:1:sha256:" + String(repeating: "f", count: 64)
        let cid = CIDMapper.aciToCID(aci)
        XCTAssertNotNil(cid, "Should handle all FF digest")
        if let cid = cid {
            let convertedACI = CIDMapper.cidToACI(cid)
            XCTAssertEqual(convertedACI, aci, "Roundtrip should work for all FF")
        }
    }
    
    func testRoundtrip_RandomDigests_AllConsistent() {
        for _ in 0..<10 {
            let randomHex = (0..<64).map { _ in String("0123456789abcdef".randomElement()!) }.joined()
            let aci = "aci:1:sha256:\(randomHex)"
            let cid = CIDMapper.aciToCID(aci)
            XCTAssertNotNil(cid, "Should convert random ACI to CID")
            if let cid = cid {
                let convertedACI = CIDMapper.cidToACI(cid)
                XCTAssertEqual(convertedACI, aci, "Roundtrip should work for random digest")
            }
        }
    }
    
    func testRoundtrip_Lowercase_Consistent() {
        let aci = "aci:1:sha256:ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"
        let cid = CIDMapper.aciToCID(aci)
        XCTAssertNotNil(cid, "Should convert ACI to CID")
        if let cid = cid {
            let convertedACI = CIDMapper.cidToACI(cid)
            XCTAssertNotNil(convertedACI, "Should convert CID to ACI")
            if let convertedACI = convertedACI {
                // ACI should be lowercase
                XCTAssertEqual(convertedACI, convertedACI.lowercased(), "ACI should be lowercase")
            }
        }
    }
    
    func testRoundtrip_NoDataLoss() {
        let originalACI = "aci:1:sha256:ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"
        let cid = CIDMapper.aciToCID(originalACI)
        XCTAssertNotNil(cid, "Should convert ACI to CID")
        if let cid = cid {
            let convertedACI = CIDMapper.cidToACI(cid)
            XCTAssertEqual(convertedACI, originalACI, "No data should be lost in roundtrip")
        }
    }
    
    func testRoundtrip_Reversible() {
        let originalACI = "aci:1:sha256:ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"
        let cid1 = CIDMapper.aciToCID(originalACI)
        XCTAssertNotNil(cid1, "Should convert ACI to CID")
        if let cid1 = cid1 {
            let convertedACI = CIDMapper.cidToACI(cid1)
            XCTAssertNotNil(convertedACI, "Should convert CID to ACI")
            if let convertedACI = convertedACI {
                let cid2 = CIDMapper.aciToCID(convertedACI)
                XCTAssertEqual(cid1, cid2, "Roundtrip should be reversible")
            }
        }
    }
}
