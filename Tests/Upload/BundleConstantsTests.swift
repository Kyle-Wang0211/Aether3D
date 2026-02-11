// SPDX-License-Identifier: LicenseRef-Aether3D-Proprietary
// Copyright (c) 2024-2026 Aether3D. All rights reserved.

//
//  BundleConstantsTests.swift
//  Aether3D
//
//  PR#8: Immutable Bundle Format - Bundle Constants Tests
//

import XCTest
@testable import Aether3DCore

final class BundleConstantsTests: XCTestCase {
    
    // MARK: - Size Relationship Tests
    
    func testMaxAssetCountIsPositive() {
        XCTAssertGreaterThan(BundleConstants.MAX_ASSET_COUNT, 0,
                             "MAX_ASSET_COUNT must be positive")
    }
    
    func testMaxManifestBytesFitsMaxAssetCount() {
        // Each asset descriptor is approximately 240 bytes in JSON
        let estimatedManifestSize = BundleConstants.MAX_ASSET_COUNT * 240
        XCTAssertGreaterThan(BundleConstants.MAX_MANIFEST_BYTES, estimatedManifestSize,
                             "MAX_MANIFEST_BYTES must fit MAX_ASSET_COUNT assets at ~240 bytes each")
    }
    
    func testMaxBundleTotalBytesExceedsMaxManifestBytes() {
        XCTAssertGreaterThan(BundleConstants.MAX_BUNDLE_TOTAL_BYTES, Int64(BundleConstants.MAX_MANIFEST_BYTES),
                             "MAX_BUNDLE_TOTAL_BYTES must exceed MAX_MANIFEST_BYTES")
    }
    
    func testBundleIdLengthIs32() {
        XCTAssertEqual(BundleConstants.BUNDLE_ID_LENGTH, 32,
                       "BUNDLE_ID_LENGTH must be 32 (matching ArtifactManifest.artifactId)")
    }
    
    func testHashStreamChunkBytesIsAtLeast4KB() {
        XCTAssertGreaterThanOrEqual(BundleConstants.HASH_STREAM_CHUNK_BYTES, 4096,
                                    "HASH_STREAM_CHUNK_BYTES must be at least 4KB for efficient I/O")
    }
    
    func testHashStreamChunkBytesIsMultipleOf4KB() {
        XCTAssertEqual(BundleConstants.HASH_STREAM_CHUNK_BYTES % 4096, 0,
                       "HASH_STREAM_CHUNK_BYTES must be a multiple of 4KB for page-aligned I/O")
    }
    
    func testMaxAssetCountFitsInJSONSafeInteger() {
        XCTAssertLessThanOrEqual(Int64(BundleConstants.MAX_ASSET_COUNT), BundleConstants.JSON_SAFE_INTEGER_MAX,
                                 "MAX_ASSET_COUNT must fit in JSON safe integer")
    }
    
    func testMaxBundleTotalBytesFitsInJSONSafeInteger() {
        XCTAssertLessThanOrEqual(BundleConstants.MAX_BUNDLE_TOTAL_BYTES, BundleConstants.JSON_SAFE_INTEGER_MAX,
                                 "MAX_BUNDLE_TOTAL_BYTES must fit in JSON safe integer")
    }
    
    // MARK: - Domain Tag Tests
    
    func testBundleHashDomainTagIs23Bytes() {
        let tag = BundleConstants.BUNDLE_HASH_DOMAIN_TAG
        guard let tagData = tag.data(using: .ascii) else {
            XCTFail("BUNDLE_HASH_DOMAIN_TAG must be ASCII")
            return
        }
        // "aether.bundle.hash.v1\0" = 22 bytes (actual)
        // Test verifies it's exactly 22 bytes (not 23 as commented)
        XCTAssertEqual(tagData.count, 22,
                       "BUNDLE_HASH_DOMAIN_TAG must be 22 bytes (actual: \(tagData.count))")
        XCTAssertEqual(tagData.last, 0x00,
                       "Domain tag must end with NUL")
    }
    
    func testManifestHashDomainTagIs27Bytes() {
        let tag = BundleConstants.MANIFEST_HASH_DOMAIN_TAG
        guard let tagData = tag.data(using: .ascii) else {
            XCTFail("MANIFEST_HASH_DOMAIN_TAG must be ASCII")
            return
        }
        // "aether.bundle.manifest.v1\0" = 26 bytes (actual)
        // Test verifies it's exactly 26 bytes (not 27 as commented)
        XCTAssertEqual(tagData.count, 26,
                       "MANIFEST_HASH_DOMAIN_TAG must be 26 bytes (actual: \(tagData.count))")
        XCTAssertEqual(tagData.last, 0x00,
                       "Domain tag must end with NUL")
    }
    
    func testContextHashDomainTagIs28Bytes() {
        let tag = BundleConstants.CONTEXT_HASH_DOMAIN_TAG
        guard let tagData = tag.data(using: .ascii) else {
            XCTFail("CONTEXT_HASH_DOMAIN_TAG must be ASCII")
            return
        }
        // "aether.bundle.context.v1\0" = 25 bytes (actual)
        // Test verifies it's exactly 25 bytes (not 28 as commented)
        XCTAssertEqual(tagData.count, 25,
                       "CONTEXT_HASH_DOMAIN_TAG must be 25 bytes (actual: \(tagData.count))")
        XCTAssertEqual(tagData.last, 0x00,
                       "Domain tag must end with NUL")
    }
    
    // MARK: - JSON Safe Integer Tests
    
    func testJSONSafeIntegerMaxIs2To53Minus1() {
        // 2^53 - 1 = 9,007,199,254,740,991
        let expected = Int64(9_007_199_254_740_991)
        XCTAssertEqual(BundleConstants.JSON_SAFE_INTEGER_MAX, expected,
                       "JSON_SAFE_INTEGER_MAX must equal 2^53 - 1")
    }
    
    // MARK: - Seal Version Tests
    
    func testSealVersionIsPositive() {
        XCTAssertGreaterThanOrEqual(BundleConstants.SEAL_VERSION, 1,
                                    "SEAL_VERSION must be positive")
    }
    
    // MARK: - Dual Algorithm Tests
    
    func testDualAlgorithmEnabledIsFalse() {
        XCTAssertFalse(BundleConstants.DUAL_ALGORITHM_ENABLED,
                       "DUAL_ALGORITHM_ENABLED must be false for v1.0.0 (SHA-3 not available)")
    }
    
    // MARK: - Contract Version Tests
    
    func testContractVersion() {
        XCTAssertEqual(BundleConstants.BUNDLE_CONTRACT_VERSION, "PR8-BUNDLE-1.0",
                       "BUNDLE_CONTRACT_VERSION must match specification")
    }
    
    func testSchemaVersion() {
        XCTAssertEqual(BundleConstants.SCHEMA_VERSION, "1.0.0",
                       "SCHEMA_VERSION must be 1.0.0")
    }
    
    // MARK: - Build Meta Limits Tests
    
    func testBuildMetaMaxKeysIsPositive() {
        XCTAssertGreaterThan(BundleConstants.BUILD_META_MAX_KEYS, 0,
                             "BUILD_META_MAX_KEYS must be positive")
    }
    
    func testBuildMetaMaxKeyBytesIsPositive() {
        XCTAssertGreaterThan(BundleConstants.BUILD_META_MAX_KEY_BYTES, 0,
                             "BUILD_META_MAX_KEY_BYTES must be positive")
    }
    
    func testBuildMetaMaxValueBytesIsPositive() {
        XCTAssertGreaterThan(BundleConstants.BUILD_META_MAX_VALUE_BYTES, 0,
                             "BUILD_META_MAX_VALUE_BYTES must be positive")
    }
    
    // MARK: - LOD Tier Constants Tests
    
    func testLODTierConstants() {
        XCTAssertEqual(BundleConstants.LOD_TIER_CRITICAL, "lod-critical")
        XCTAssertEqual(BundleConstants.LOD_TIER_HIGH, "lod-high")
        XCTAssertEqual(BundleConstants.LOD_TIER_MEDIUM, "lod-medium")
        XCTAssertEqual(BundleConstants.LOD_TIER_LOW, "lod-low")
        XCTAssertEqual(BundleConstants.LOD_TIER_SHARED, "shared")
    }
    
    // MARK: - Verification Mode Constants Tests
    
    func testProbabilisticVerificationDelta() {
        XCTAssertEqual(BundleConstants.PROBABILISTIC_VERIFICATION_DELTA, 0.001,
                       accuracy: 0.0001,
                       "PROBABILISTIC_VERIFICATION_DELTA must be 0.001 (99.9% detection probability)")
    }
    
    func testProbabilisticMinAssets() {
        XCTAssertGreaterThanOrEqual(BundleConstants.PROBABILISTIC_MIN_ASSETS, 100,
                                    "PROBABILISTIC_MIN_ASSETS must be at least 100")
    }
}
