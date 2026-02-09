// SPDX-License-Identifier: LicenseRef-Aether3D-Proprietary
// Copyright (c) 2024-2026 Aether3D. All rights reserved.

// PR#3 — API Contract v2.0
// Stage: WHITEBOX | Camera-only
// Endpoints: 12 | HTTP Codes: 10 (3 success + 7 error) | Business Errors: 7

import Foundation
import Crypto

// MARK: - Response Format

/// API统一响应格式
public struct APIResponse<T: Codable>: Codable {
    public let success: Bool
    public let data: T?
    public let error: APIError?
    
    public init(success: Bool, data: T? = nil, error: APIError? = nil) {
        self.success = success
        self.data = data
        self.error = error
    }
}

// MARK: - Device Info

/// 设备信息
public struct DeviceInfo: Codable, Equatable {
    public let model: String
    public let osVersion: String
    public let appVersion: String
    
    public init(model: String, osVersion: String, appVersion: String) {
        self.model = model
        self.osVersion = osVersion
        self.appVersion = appVersion
    }
    
    private enum CodingKeys: String, CodingKey {
        case model
        case osVersion = "os_version"
        case appVersion = "app_version"
    }
}

// MARK: - Uploads API

/// 创建上传会话请求
public struct CreateUploadRequest: Codable, Equatable {
    public let captureSource: String
    public let captureSessionId: String
    public let bundleHash: String
    public let bundleSize: Int
    public let chunkCount: Int
    public let idempotencyKey: String
    public let deviceInfo: DeviceInfo
    
    public init(
        captureSource: String,
        captureSessionId: String,
        bundleHash: String,
        bundleSize: Int,
        chunkCount: Int,
        idempotencyKey: String,
        deviceInfo: DeviceInfo
    ) {
        self.captureSource = captureSource
        self.captureSessionId = captureSessionId
        self.bundleHash = bundleHash
        self.bundleSize = bundleSize
        self.chunkCount = chunkCount
        self.idempotencyKey = idempotencyKey
        self.deviceInfo = deviceInfo
    }
    
    private enum CodingKeys: String, CodingKey {
        case captureSource = "capture_source"
        case captureSessionId = "capture_session_id"
        case bundleHash = "bundle_hash"
        case bundleSize = "bundle_size"
        case chunkCount = "chunk_count"
        case idempotencyKey = "idempotency_key"
        case deviceInfo = "device_info"
    }
}

/// 创建上传会话响应
public struct CreateUploadResponse: Codable, Equatable {
    public let uploadId: String
    public let uploadUrl: String
    public let chunkSize: Int
    public let expiresAt: String  // RFC3339 UTC
    
    private enum CodingKeys: String, CodingKey {
        case uploadId = "upload_id"
        case uploadUrl = "upload_url"
        case chunkSize = "chunk_size"
        case expiresAt = "expires_at"
    }
}

/// 上传分片响应
public struct UploadChunkResponse: Codable, Equatable {
    public let chunkIndex: Int
    public let chunkStatus: String  // "stored" | "already_present"
    public let receivedSize: Int
    public let totalReceived: Int
    public let totalChunks: Int
    
    private enum CodingKeys: String, CodingKey {
        case chunkIndex = "chunk_index"
        case chunkStatus = "chunk_status"
        case receivedSize = "received_size"
        case totalReceived = "total_received"
        case totalChunks = "total_chunks"
    }
}

/// 查询已上传分片响应
public struct GetChunksResponse: Codable, Equatable {
    public let uploadId: String
    public let receivedChunks: [Int]
    public let missingChunks: [Int]
    public let totalChunks: Int
    public let status: String  // "in_progress" | "completed" | "expired"
    public let expiresAt: String  // RFC3339 UTC
    
    private enum CodingKeys: String, CodingKey {
        case uploadId = "upload_id"
        case receivedChunks = "received_chunks"
        case missingChunks = "missing_chunks"
        case totalChunks = "total_chunks"
        case status
        case expiresAt = "expires_at"
    }
}

/// 完成上传请求
public struct CompleteUploadRequest: Codable, Equatable {
    public let bundleHash: String
    
    private enum CodingKeys: String, CodingKey {
        case bundleHash = "bundle_hash"
    }
}

/// 完成上传响应
public struct CompleteUploadResponse: Codable, Equatable {
    public let uploadId: String
    public let bundleHash: String
    public let status: String
    public let jobId: String
    
    private enum CodingKeys: String, CodingKey {
        case uploadId = "upload_id"
        case bundleHash = "bundle_hash"
        case status
        case jobId = "job_id"
    }
}

// MARK: - Jobs API

/// 创建任务请求
public struct CreateJobRequest: Codable, Equatable {
    public let bundleHash: String
    public let parentJobId: String?  // 白盒阶段必须为null
    public let idempotencyKey: String
    
    private enum CodingKeys: String, CodingKey {
        case bundleHash = "bundle_hash"
        case parentJobId = "parent_job_id"
        case idempotencyKey = "idempotency_key"
    }
}

/// 创建任务响应
public struct CreateJobResponse: Codable, Equatable {
    public let jobId: String
    public let state: String  // "queued" (PATCH-4)
    public let createdAt: String  // RFC3339 UTC
    
    private enum CodingKeys: String, CodingKey {
        case jobId = "job_id"
        case state
        case createdAt = "created_at"
    }
}

/// 任务进度
public struct JobProgress: Codable, Equatable {
    public let stage: String  // "queued" | "sfm" | "gs_training" | "packaging"
    public let percentage: Int  // 0-100
    public let message: String
    
    public init(stage: String, percentage: Int, message: String) {
        self.stage = stage
        self.percentage = percentage
        self.message = message
    }
}

/// 查询任务状态响应
public struct GetJobResponse: Codable, Equatable {
    public let jobId: String
    public let state: String
    public let progress: JobProgress?
    public let failureReason: String?
    public let cancelReason: String?
    public let createdAt: String  // RFC3339 UTC
    public let updatedAt: String  // RFC3339 UTC
    public let processingStartedAt: String?  // RFC3339 UTC
    public let artifactId: String?
    
    private enum CodingKeys: String, CodingKey {
        case jobId = "job_id"
        case state
        case progress
        case failureReason = "failure_reason"
        case cancelReason = "cancel_reason"
        case createdAt = "created_at"
        case updatedAt = "updated_at"
        case processingStartedAt = "processing_started_at"
        case artifactId = "artifact_id"
    }
}

/// 任务列表项
public struct JobListItem: Codable, Equatable {
    public let jobId: String
    public let state: String
    public let createdAt: String  // RFC3339 UTC
    public let artifactId: String?
    
    private enum CodingKeys: String, CodingKey {
        case jobId = "job_id"
        case state
        case createdAt = "created_at"
        case artifactId = "artifact_id"
    }
}

/// 查询任务列表响应
public struct ListJobsResponse: Codable, Equatable {
    public let jobs: [JobListItem]
    public let total: Int
    public let limit: Int
    public let offset: Int
}

/// 取消任务请求
public struct CancelJobRequest: Codable, Equatable {
    public let reason: String  // "user_requested" | "app_terminated"
}

/// 取消任务响应
public struct CancelJobResponse: Codable, Equatable {
    public let jobId: String
    public let state: String  // "cancelled"
    public let cancelReason: String
    public let cancelledAt: String  // RFC3339 UTC
    
    private enum CodingKeys: String, CodingKey {
        case jobId = "job_id"
        case state
        case cancelReason = "cancel_reason"
        case cancelledAt = "cancelled_at"
    }
}

/// 时间线事件
public struct TimelineEvent: Codable, Equatable {
    public let timestamp: String  // RFC3339 UTC
    public let fromState: String?
    public let toState: String
    public let trigger: String
    
    private enum CodingKeys: String, CodingKey {
        case timestamp
        case fromState = "from_state"
        case toState = "to_state"
        case trigger
    }
}

/// 查询任务时间线响应
public struct GetTimelineResponse: Codable, Equatable {
    public let jobId: String
    public let events: [TimelineEvent]
    
    private enum CodingKeys: String, CodingKey {
        case jobId = "job_id"
        case events
    }
}

// MARK: - Artifacts API

/// 获取产物元信息响应
public struct GetArtifactResponse: Codable, Equatable {
    public let artifactId: String
    public let jobId: String
    public let format: String  // "splat"
    public let size: Int
    public let hash: String
    public let createdAt: String  // RFC3339 UTC
    public let expiresAt: String  // RFC3339 UTC
    public let downloadUrl: String
    
    private enum CodingKeys: String, CodingKey {
        case artifactId = "artifact_id"
        case jobId = "job_id"
        case format
        case size
        case hash
        case createdAt = "created_at"
        case expiresAt = "expires_at"
        case downloadUrl = "download_url"
    }
}

// Note: DownloadArtifactResponse不存在（PATCH-3：二进制响应）

// MARK: - Health API

/// 健康检查响应
public struct HealthResponse: Codable, Equatable {
    public let status: String
    public let version: String
    public let contractVersion: String
    public let timestamp: String  // RFC3339 UTC
    
    private enum CodingKeys: String, CodingKey {
        case status
        case version
        case contractVersion = "contract_version"
        case timestamp
    }
}

// MARK: - Idempotency Manager (PATCH-7)

/// 幂等性管理器
public enum IdempotencyManager {
    /// 生成幂等键（推荐方式）
    public static func generateKey(bundleHash: String, captureSessionId: String) -> String {
        let secondsPerMinute = TimeInterval(APIContractConstants.secondsPerMinute)
        let timestamp = Int(Date().timeIntervalSince1970 / secondsPerMinute) * APIContractConstants.secondsPerMinute  // 截断到分钟
        let input = "\(bundleHash)\(captureSessionId)\(timestamp)"
        let data = Data(input.utf8)
        let hash = SHA256.hash(data: data)
        return hash.compactMap { String(format: APIContractConstants.hexByteFormat, $0) }.joined()
    }
    
    /// 计算payload的canonical JSON hash（PATCH-7：与Python完全一致）
    public static func computePayloadHash(_ payload: [String: Any]) -> String {
        let canonical = canonicalizeJSON(payload)
        let data = Data(canonical.utf8)
        let hash = SHA256.hash(data: data)
        return hash.compactMap { String(format: APIContractConstants.hexByteFormat, $0) }.joined()
    }
    
    /// Canonical JSON编码（递归排序keys，匹配Python json.dumps行为）
    private static func canonicalizeJSON(_ value: Any) -> String {
        switch value {
        case let dict as [String: Any]:
            let sortedKeys = dict.keys.sorted()
            let pairs = sortedKeys.map { key in
                let escapedKey = escapeJSONString(key)
                let valueStr = canonicalizeJSON(dict[key]!)
                return "\(APIContractConstants.jsonQuote)\(escapedKey)\(APIContractConstants.jsonQuote)\(APIContractConstants.jsonKeyValueSeparator)\(valueStr)"
            }
            return "\(APIContractConstants.jsonObjectOpen)\(pairs.joined(separator: APIContractConstants.jsonElementSeparator))\(APIContractConstants.jsonObjectClose)"
            
        case let array as [Any]:
            let elements = array.map { canonicalizeJSON($0) }
            return "\(APIContractConstants.jsonArrayOpen)\(elements.joined(separator: APIContractConstants.jsonElementSeparator))\(APIContractConstants.jsonArrayClose)"
            
        case let string as String:
            return "\(APIContractConstants.jsonQuote)\(escapeJSONString(string))\(APIContractConstants.jsonQuote)"
            
        case let number as NSNumber:
            // 保持整数/浮点数区分（便携式实现，不依赖CoreFoundation）
            if number.isBool {
                return number.boolValue ? APIContractConstants.jsonTrue : APIContractConstants.jsonFalse
            } else if number.isInteger {
                return "\(number.intValue)"
            } else {
                // 浮点数：确保格式稳定
                return String(format: APIContractConstants.floatFormat, number.doubleValue)
            }
            
        case let bool as Bool:
            return bool ? APIContractConstants.jsonTrue : APIContractConstants.jsonFalse
            
        case is NSNull:
            return APIContractConstants.jsonNull
            
        default:
            // 其他类型转为字符串
            return "\"\(escapeJSONString(String(describing: value)))\""
        }
    }
    
    /// 转义JSON字符串（匹配Python ensure_ascii=False行为）
    private static func escapeJSONString(_ string: String) -> String {
        var result = ""
        result.reserveCapacity(string.count)
        
        for char in string.unicodeScalars {
            switch char.value {
            case APIContractConstants.unicodeDoubleQuote:  // "
                result += APIContractConstants.jsonEscapedQuote
            case APIContractConstants.unicodeBackslash:  // \
                result += "\\\\"
            case APIContractConstants.unicodeBackspace:  // \b
                result += "\\b"
            case APIContractConstants.unicodeFormFeed:  // \f
                result += "\\f"
            case APIContractConstants.unicodeNewline:  // \n
                result += "\\n"
            case APIContractConstants.unicodeCarriageReturn:  // \r
                result += "\\r"
            case APIContractConstants.unicodeTab:  // \t
                result += "\\t"
            default:
                if char.value < APIContractConstants.unicodeControlThreshold {
                    // 控制字符：\u00XX
                    result += String(format: APIContractConstants.unicodeEscapeFormat, char.value)
                } else {
                    result.append(Character(char))
                }
            }
        }
        
        return result
    }
}

// MARK: - NSNumber Extension

private extension NSNumber {
    /// 检查是否为布尔值（便携式实现，不依赖CoreFoundation）
    var isBool: Bool {
        // objCType for BOOL is "c" (char) on Darwin
        // On Linux, we check if it's exactly 0 or 1
        let objCTypeStr = String(cString: objCType)
        if objCTypeStr == APIContractConstants.objCTypeChar {
            // Could be BOOL (char), check if value is 0 or 1
            return intValue == APIContractConstants.booleanFalseValue || intValue == APIContractConstants.booleanTrueValue
        }
        // For other types, check if it represents exactly 0 or 1
        return (doubleValue == APIContractConstants.booleanFalseDouble || doubleValue == APIContractConstants.booleanTrueDouble) && 
               (doubleValue.rounded() == doubleValue)
    }
    
    /// 检查是否为整数（便携式实现，不依赖CoreFoundation）
    var isInteger: Bool {
        // Check if it's a whole number and fits in Int range
        let doubleVal = doubleValue
        guard doubleVal.rounded() == doubleVal else {
            return false
        }
        // Check if it fits in Int range
        return doubleVal >= Double(Int.min) && doubleVal <= Double(Int.max)
    }
}

