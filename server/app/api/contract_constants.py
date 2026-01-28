# PR#3 — API Contract v2.0
# Stage: WHITEBOX | Camera-only
# Endpoints: 12 | HTTP Codes: 10 (3 success + 7 error) | Business Errors: 7

"""API合约常量（SSOT）"""


class APIContractConstants:
    # Version
    CONTRACT_VERSION = "PR3-API-2.0"
    API_VERSION = "v1"
    
    # Counts (SSOT)
    ENDPOINT_COUNT = 12
    SUCCESS_CODE_COUNT = 3
    ERROR_CODE_COUNT = 7
    HTTP_CODE_COUNT = 10  # 3 + 7
    BUSINESS_ERROR_CODE_COUNT = 7
    
    # Upload Limits
    MAX_BUNDLE_SIZE_BYTES = 500 * 1024 * 1024  # 500MB
    MAX_CHUNK_COUNT = 200
    CHUNK_SIZE_BYTES = 5 * 1024 * 1024  # 5MB（服务端权威值，GATE-6）
    MAX_CHUNK_SIZE_BYTES = 5 * 1024 * 1024  # 5MB（硬上限，用于413判断）
    UPLOAD_EXPIRY_HOURS = 24
    
    # Concurrency Limits
    MAX_ACTIVE_UPLOADS_PER_USER = 1
    MAX_ACTIVE_JOBS_PER_USER = 1
    
    # Request Limits (PATCH-8)
    MAX_HEADER_SIZE_BYTES = 8 * 1024  # 8KB → 400 INVALID_REQUEST
    MAX_JSON_BODY_SIZE_BYTES = 64 * 1024  # 64KB → 413 PAYLOAD_TOO_LARGE
    
    # Idempotency
    IDEMPOTENCY_KEY_TTL_HOURS = 24
    
    # Polling
    POLLING_INTERVAL_QUEUED = 5.0
    POLLING_INTERVAL_PROCESSING = 3.0
    
    # Rate Limits (whitebox: relaxed)
    RATE_LIMIT_UPLOADS_PER_MINUTE = 10
    RATE_LIMIT_CHUNKS_PER_MINUTE = 100
    RATE_LIMIT_JOBS_PER_MINUTE = 10
    RATE_LIMIT_QUERIES_PER_MINUTE = 60
    
    # Pagination
    DEFAULT_PAGE_SIZE = 20
    MAX_PAGE_SIZE = 100
    
    # Cancel Window (from PR#2)
    CANCEL_WINDOW_SECONDS = 30

