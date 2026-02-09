// SPDX-License-Identifier: LicenseRef-Aether3D-Proprietary
// Copyright (c) 2024-2026 Aether3D. All rights reserved.

// PR#3 — API Contract v2.0
// Stage: WHITEBOX | Camera-only
// Endpoints: 12 | HTTP Codes: 10 (3 success + 7 error) | Business Errors: 7

import Foundation

// MARK: - HTTP Status Codes (Closed Set · 10 Codes)

/// HTTP状态码枚举（闭集）
public enum HTTPStatusCode: Int, CaseIterable, Codable {
    // Success (3)
    case ok = 200
    case created = 201
    case partialContent = 206
    
    // Error (7)
    case badRequest = 400
    case unauthorized = 401
    case notFound = 404
    case conflict = 409
    case payloadTooLarge = 413
    case tooManyRequests = 429
    case internalServerError = 500
    
    public var isSuccess: Bool {
        return rawValue >= APIContractConstants.httpSuccessCodeStart && rawValue < APIContractConstants.httpSuccessCodeEnd
    }
}

/// HTTP状态码常量（已迁移到APIContractConstants，保留此枚举以保持向后兼容）
@available(*, deprecated, message: "Use APIContractConstants instead")
public enum HTTPStatusCodeConstants {
    public static let SUCCESS_CODE_COUNT = APIContractConstants.SUCCESS_CODE_COUNT
    public static let ERROR_CODE_COUNT = APIContractConstants.ERROR_CODE_COUNT
    public static let TOTAL_CODE_COUNT = APIContractConstants.HTTP_CODE_COUNT
}

// MARK: - Business Error Codes (Closed Set · 7 Codes)

/// 业务错误码枚举（闭集）
public enum APIErrorCode: String, Codable, CaseIterable {
    case invalidRequest = "INVALID_REQUEST"
    case authFailed = "AUTH_FAILED"
    case resourceNotFound = "RESOURCE_NOT_FOUND"
    case stateConflict = "STATE_CONFLICT"
    case payloadTooLarge = "PAYLOAD_TOO_LARGE"
    case rateLimited = "RATE_LIMITED"
    case internalError = "INTERNAL_ERROR"
}

// MARK: - Error Details Value (PATCH-2)

/// 错误details字段值类型（闭集：string | int | int_array）
public enum DetailValue: Codable, Equatable {
    case string(String)
    case int(Int)
    case intArray([Int])  // 用于missing chunks: [3,4,7]
    
    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let arr = try? container.decode([Int].self) {
            self = .intArray(arr)
        } else if let i = try? container.decode(Int.self) {
            self = .int(i)
        } else {
            self = .string(try container.decode(String.self))
        }
    }
    
    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .string(let s):
            try container.encode(s)
        case .int(let i):
            try container.encode(i)
        case .intArray(let a):
            try container.encode(a)
        }
    }
}

// MARK: - API Error

/// API错误结构体
public struct APIError: Codable, Equatable, Error {
    public let code: APIErrorCode
    public let message: String
    public let details: [String: DetailValue]?
    
    public init(code: APIErrorCode, message: String, details: [String: DetailValue]? = nil) {
        self.code = code
        self.message = message
        self.details = details
    }
}

