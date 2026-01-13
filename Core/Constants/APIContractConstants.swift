//
// APIContractConstants.swift
// Aether3D
//
// Constants for API Contract v2.0 (PR#3)
// Centralized constants to avoid scattered literals
//

import Foundation

/// Constants for API Contract v2.0 (PR#3) - SSOT
public enum APIContractConstants {
    // MARK: - Version
    
    /// 合约版本
    public static let CONTRACT_VERSION = "PR3-API-2.0"
    
    /// API版本
    public static let API_VERSION = "v1"
    
    // MARK: - Counts (SSOT)
    
    /// 端点数量
    public static let ENDPOINT_COUNT = 12
    
    /// 成功HTTP状态码数量
    public static let SUCCESS_CODE_COUNT = 3
    
    /// 错误HTTP状态码数量
    public static let ERROR_CODE_COUNT = 7
    
    /// HTTP状态码总数
    public static let HTTP_CODE_COUNT = 10  // 3 + 7
    
    /// 业务错误码数量
    public static let BUSINESS_ERROR_CODE_COUNT = 7
    
    // MARK: - Upload Limits
    
    /// Bundle最大大小（500MB）
    public static let MAX_BUNDLE_SIZE_BYTES = 500 * 1024 * 1024
    
    /// 最大分片数量
    public static let MAX_CHUNK_COUNT = 200
    
    /// 分片大小（5MB，服务端权威值，GATE-6）
    public static let CHUNK_SIZE_BYTES = 5 * 1024 * 1024
    
    /// 分片最大大小（5MB，硬上限，用于413判断）
    public static let MAX_CHUNK_SIZE_BYTES = 5 * 1024 * 1024
    
    /// 上传会话过期时间（小时）
    public static let UPLOAD_EXPIRY_HOURS = 24
    
    // MARK: - Concurrency Limits
    
    /// 每用户最大活跃上传数
    public static let MAX_ACTIVE_UPLOADS_PER_USER = 1
    
    /// 每用户最大活跃任务数
    public static let MAX_ACTIVE_JOBS_PER_USER = 1
    
    // MARK: - Request Limits (PATCH-8)
    
    /// Header最大大小（8KB）→ 400 INVALID_REQUEST
    public static let MAX_HEADER_SIZE_BYTES = 8 * 1024
    
    /// JSON body最大大小（64KB）→ 413 PAYLOAD_TOO_LARGE
    public static let MAX_JSON_BODY_SIZE_BYTES = 64 * 1024
    
    // MARK: - Idempotency
    
    /// 幂等键TTL（小时）
    public static let IDEMPOTENCY_KEY_TTL_HOURS = 24
    
    // MARK: - Polling
    
    /// 排队状态轮询间隔（秒）
    public static let POLLING_INTERVAL_QUEUED: TimeInterval = 5.0
    
    /// 处理中状态轮询间隔（秒）
    public static let POLLING_INTERVAL_PROCESSING: TimeInterval = 3.0
    
    // MARK: - Rate Limits (whitebox: relaxed)
    
    /// 上传端点限流（次/分钟）
    public static let RATE_LIMIT_UPLOADS_PER_MINUTE = 10
    
    /// 分片上传限流（次/分钟）
    public static let RATE_LIMIT_CHUNKS_PER_MINUTE = 100
    
    /// 任务端点限流（次/分钟）
    public static let RATE_LIMIT_JOBS_PER_MINUTE = 10
    
    /// 查询端点限流（次/分钟）
    public static let RATE_LIMIT_QUERIES_PER_MINUTE = 60
    
    // MARK: - Pagination
    
    /// 默认分页大小
    public static let DEFAULT_PAGE_SIZE = 20
    
    /// 最大分页大小
    public static let MAX_PAGE_SIZE = 100
    
    // MARK: - Cancel Window (from PR#2)
    
    /// 取消窗口（秒）
    public static let CANCEL_WINDOW_SECONDS = 30
    
    // MARK: - HTTP Status Code Ranges
    
    /// HTTP成功状态码起始值
    public static let httpSuccessCodeStart = 200
    
    /// HTTP成功状态码结束值（不包含）
    public static let httpSuccessCodeEnd = 300
    
    // MARK: - Canonical JSON Encoding Constants
    // MARK: - Time Constants
    
    /// Seconds per minute (for timestamp truncation in idempotency key generation)
    public static let secondsPerMinute = 60
    
    // MARK: - JSON Format Strings
    
    /// Format string for hexadecimal byte representation (lowercase, 2 digits)
    public static let hexByteFormat = "%02x"
    
    /// Format string for floating point number (15 significant digits)
    public static let floatFormat = "%.15g"
    
    /// Format string for Unicode escape sequence (4 hex digits)
    public static let unicodeEscapeFormat = "\\u%04X"
    
    // MARK: - JSON String Literals
    
    /// JSON boolean true value
    public static let jsonTrue = "true"
    
    /// JSON boolean false value
    public static let jsonFalse = "false"
    
    /// JSON null value
    public static let jsonNull = "null"
    
    // MARK: - JSON Structure Strings
    
    /// JSON object opening brace
    public static let jsonObjectOpen = "{"
    
    /// JSON object closing brace
    public static let jsonObjectClose = "}"
    
    /// JSON array opening bracket
    public static let jsonArrayOpen = "["
    
    /// JSON array closing bracket
    public static let jsonArrayClose = "]"
    
    /// JSON key-value separator (colon)
    public static let jsonKeyValueSeparator = ":"
    
    /// JSON element separator (comma)
    public static let jsonElementSeparator = ","
    
    /// JSON string quote character
    public static let jsonQuote = "\""
    
    /// JSON escaped quote
    public static let jsonEscapedQuote = "\\\""
    
    // MARK: - Unicode Scalar Values (for JSON escaping)
    
    /// Unicode scalar for double quote (")
    public static let unicodeDoubleQuote: UInt32 = 0x22
    
    /// Unicode scalar for backslash (\)
    public static let unicodeBackslash: UInt32 = 0x5C
    
    /// Unicode scalar for backspace (\b)
    public static let unicodeBackspace: UInt32 = 0x08
    
    /// Unicode scalar for form feed (\f)
    public static let unicodeFormFeed: UInt32 = 0x0C
    
    /// Unicode scalar for newline (\n)
    public static let unicodeNewline: UInt32 = 0x0A
    
    /// Unicode scalar for carriage return (\r)
    public static let unicodeCarriageReturn: UInt32 = 0x0D
    
    /// Unicode scalar for tab (\t)
    public static let unicodeTab: UInt32 = 0x09
    
    /// Unicode scalar threshold for control characters (below 0x20)
    public static let unicodeControlThreshold: UInt32 = 0x20
    
    // MARK: - NSNumber Type Checking
    
    /// Character type identifier for BOOL (objCType "c")
    public static let objCTypeChar = "c"
    
    /// Numeric value for boolean false
    public static let booleanFalseValue = 0
    
    /// Numeric value for boolean true
    public static let booleanTrueValue = 1
    
    /// Double value for boolean false
    public static let booleanFalseDouble: Double = 0.0
    
    /// Double value for boolean true
    public static let booleanTrueDouble: Double = 1.0
}

