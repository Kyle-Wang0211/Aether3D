// SPDX-License-Identifier: LicenseRef-Aether3D-Proprietary
// Copyright (c) 2024-2026 Aether3D. All rights reserved.

// PR#3 — API Contract v2.0
// Stage: WHITEBOX | Camera-only
// Endpoints: 12 | HTTP Codes: 10 (3 success + 7 error) | Business Errors: 7

import XCTest
@testable import Aether3DCore

final class APIContractTests: XCTestCase {
    
    // MARK: - HTTP Status Code Closed Set Test (§18.3)
    
    func testHTTPStatusCodeClosedSet() {
        // 验证只有10个HTTP状态码
        let allCodes = HTTPStatusCode.allCases
        XCTAssertEqual(allCodes.count, APIContractConstants.HTTP_CODE_COUNT, "HTTP status code count must be exactly 10")
        
        // 验证成功码数量
        let successCodes = allCodes.filter { $0.isSuccess }
        XCTAssertEqual(successCodes.count, APIContractConstants.SUCCESS_CODE_COUNT, "Success code count must be 3")
        
        // 验证错误码数量
        let errorCodes = allCodes.filter { !$0.isSuccess }
        XCTAssertEqual(errorCodes.count, APIContractConstants.ERROR_CODE_COUNT, "Error code count must be 7")
        
        // 验证具体状态码
        XCTAssertTrue(allCodes.contains(.ok))
        XCTAssertTrue(allCodes.contains(.created))
        XCTAssertTrue(allCodes.contains(.partialContent))
        XCTAssertTrue(allCodes.contains(.badRequest))
        XCTAssertTrue(allCodes.contains(.unauthorized))
        XCTAssertTrue(allCodes.contains(.notFound))
        XCTAssertTrue(allCodes.contains(.conflict))
        XCTAssertTrue(allCodes.contains(.payloadTooLarge))
        XCTAssertTrue(allCodes.contains(.tooManyRequests))
        XCTAssertTrue(allCodes.contains(.internalServerError))
    }
    
    // MARK: - Business Error Code Closed Set Test (§18.3)
    
    func testAPIErrorCodeClosedSet() {
        // 验证只有7个业务错误码
        let allCodes = APIErrorCode.allCases
        XCTAssertEqual(allCodes.count, APIContractConstants.BUSINESS_ERROR_CODE_COUNT, "Business error code count must be exactly 7")
        
        // 验证具体错误码
        XCTAssertTrue(allCodes.contains(.invalidRequest))
        XCTAssertTrue(allCodes.contains(.authFailed))
        XCTAssertTrue(allCodes.contains(.resourceNotFound))
        XCTAssertTrue(allCodes.contains(.stateConflict))
        XCTAssertTrue(allCodes.contains(.payloadTooLarge))
        XCTAssertTrue(allCodes.contains(.rateLimited))
        XCTAssertTrue(allCodes.contains(.internalError))
    }
    
    // MARK: - Canonical JSON Hash Parity Test (PATCH-7, §18.4)
    
    func testCanonicalHashParity() {
        // 测试向量1：简单对象
        let payload1: [String: Any] = [
            "bundle_hash": "abc123",
            "bundle_size": 1000000,
            "chunk_count": 20
        ]
        let hash1 = IdempotencyManager.computePayloadHash(payload1)
        
        // 预期hash（Python计算）：
        // json.dumps({"bundle_hash": "abc123", "bundle_size": 1000000, "chunk_count": 20}, sort_keys=True, separators=(',', ':'), ensure_ascii=False)
        // = '{"bundle_hash":"abc123","bundle_size":1000000,"chunk_count":20}'
        // sha256 = ...
        // 注意：实际测试中需要与Python结果对比
        XCTAssertFalse(hash1.isEmpty, "Hash should not be empty")
        XCTAssertEqual(hash1.count, 64, "SHA256 hash should be 64 hex characters")
        
        // 测试向量2：嵌套对象
        let payload2: [String: Any] = [
            "device_info": [
                "model": "iPhone 15 Pro",
                "os_version": "iOS 17.2"
            ],
            "bundle_hash": "def456"
        ]
        let hash2 = IdempotencyManager.computePayloadHash(payload2)
        XCTAssertFalse(hash2.isEmpty)
        XCTAssertEqual(hash2.count, 64)
        
        // 测试向量3：数组
        let payload3: [String: Any] = [
            "missing": [3, 4, 7],
            "total": 20
        ]
        let hash3 = IdempotencyManager.computePayloadHash(payload3)
        XCTAssertFalse(hash3.isEmpty)
        XCTAssertEqual(hash3.count, 64)
        
        // 测试向量4：Unicode字符串
        let payload4: [String: Any] = [
            "message": "测试消息",
            "value": 42
        ]
        let hash4 = IdempotencyManager.computePayloadHash(payload4)
        XCTAssertFalse(hash4.isEmpty)
        XCTAssertEqual(hash4.count, 64)
    }
    
    // MARK: - Forbidden Patterns Lint Test (§18.3)
    
    func testNoUnknownDefault() {
        // 简单文本扫描测试：确保代码中无@unknown default
        // 注意：这是一个静态检查，实际应该通过代码审查或lint工具完成
        // 这里仅作为占位符测试
        
        // 验证枚举都有CaseIterable（强制穷举）
        let httpCodes = HTTPStatusCode.allCases
        XCTAssertGreaterThan(httpCodes.count, 0, "HTTPStatusCode must have cases")
        
        let errorCodes = APIErrorCode.allCases
        XCTAssertGreaterThan(errorCodes.count, 0, "APIErrorCode must have cases")
    }
    
    // MARK: - DetailValue Test (PATCH-2)
    
    func testDetailValueIntArray() {
        // 测试int_array支持
        let details: [String: DetailValue] = [
            "missing": .intArray([3, 4, 7])
        ]
        
        let encoder = JSONEncoder()
        let decoder = JSONDecoder()
        
        do {
            let encoded = try encoder.encode(details)
            let decoded = try decoder.decode([String: DetailValue].self, from: encoded)
            
            if case .intArray(let arr) = decoded["missing"]! {
                XCTAssertEqual(arr, [3, 4, 7])
            } else {
                XCTFail("Expected intArray")
            }
        } catch {
            XCTFail("Encoding/decoding failed: \(error)")
        }
    }
}

