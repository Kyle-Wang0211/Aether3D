// PR#3 — API Contract v2.0
// Stage: WHITEBOX | Camera-only
// Endpoints: 12 | HTTP Codes: 10 (3 success + 7 error) | Business Errors: 7

import Foundation

/// API合约常量（SSOT）
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
}

