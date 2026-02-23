# PR#3 — API Contract v2.0
# Stage: WHITEBOX | Camera-only
# Endpoints: 12 | HTTP Codes: 10 (3 success + 7 error) | Business Errors: 7

"""API合约Schema定义（Pydantic v2）"""

from datetime import datetime
from enum import Enum
from typing import Generic, List, Optional, TypeVar, Union

from pydantic import BaseModel, ConfigDict, Field

# GATE-1: Pydantic v2配置
PydanticConfig = ConfigDict(extra="forbid")  # 禁止未知字段

# PATCH-2: DetailValue类型
DetailValue = Union[str, int, List[int]]

T = TypeVar('T')


# MARK: - Business Error Codes

from app.api.error_registry import ERROR_CODE_REGISTRY

class APIErrorCode(str, Enum):
    """业务错误码（闭集：7个，必须与ERROR_CODE_REGISTRY一致）"""
    INVALID_REQUEST = "INVALID_REQUEST"
    AUTH_FAILED = "AUTH_FAILED"
    RESOURCE_NOT_FOUND = "RESOURCE_NOT_FOUND"
    STATE_CONFLICT = "STATE_CONFLICT"
    PAYLOAD_TOO_LARGE = "PAYLOAD_TOO_LARGE"
    RATE_LIMITED = "RATE_LIMITED"
    INTERNAL_ERROR = "INTERNAL_ERROR"

# PR1E: 验证枚举值与注册表一致
_registry_set = set(ERROR_CODE_REGISTRY)
_enum_set = {e.value for e in APIErrorCode}
assert _registry_set == _enum_set, f"Error code mismatch: registry={_registry_set}, enum={_enum_set}"


# MARK: - Response Format

class APIError(BaseModel):
    """API错误结构"""
    code: APIErrorCode
    message: str
    details: Optional[dict[str, DetailValue]] = None
    
    model_config = PydanticConfig


class APIResponse(BaseModel, Generic[T]):
    """API统一响应格式"""
    success: bool
    data: Optional[T] = None
    error: Optional[APIError] = None
    
    model_config = PydanticConfig


# MARK: - Device Info

class DeviceInfo(BaseModel):
    """设备信息"""
    model: str = Field(..., max_length=64)
    os_version: str = Field(..., max_length=32)
    app_version: str = Field(..., max_length=32)
    
    model_config = PydanticConfig


# MARK: - Uploads API

class CreateUploadRequest(BaseModel):
    """创建上传会话请求"""
    capture_source: str
    capture_session_id: str
    bundle_hash: str = Field(..., pattern=r'^[0-9a-f]{64}$')  # SHA256格式
    bundle_size: int
    chunk_count: int
    idempotency_key: str
    device_info: DeviceInfo
    
    model_config = PydanticConfig


class CreateUploadResponse(BaseModel):
    """创建上传会话响应"""
    upload_id: str
    upload_url: str
    chunk_size: int
    expires_at: str  # RFC3339 UTC
    
    model_config = PydanticConfig


class UploadChunkResponse(BaseModel):
    """上传分片响应"""
    chunk_index: int
    chunk_status: str  # "stored" | "already_present"
    received_size: int
    total_received: int
    total_chunks: int
    
    model_config = PydanticConfig


class GetChunksResponse(BaseModel):
    """查询已上传分片响应"""
    upload_id: str
    received_chunks: List[int]
    missing_chunks: List[int]
    total_chunks: int
    status: str  # "in_progress" | "completed" | "expired"
    expires_at: str  # RFC3339 UTC
    
    model_config = PydanticConfig


class CompleteUploadRequest(BaseModel):
    """完成上传请求"""
    bundle_hash: str = Field(..., pattern=r'^[0-9a-f]{64}$')
    
    model_config = PydanticConfig


class CompleteUploadResponse(BaseModel):
    """完成上传响应"""
    upload_id: str
    bundle_hash: str
    status: str
    job_id: str
    
    model_config = PydanticConfig


# MARK: - Jobs API

class CreateJobRequest(BaseModel):
    """创建任务请求"""
    bundle_hash: str = Field(..., pattern=r'^[0-9a-f]{64}$')
    parent_job_id: Optional[str] = None  # 白盒阶段必须为null
    idempotency_key: str
    
    model_config = PydanticConfig


class CreateJobResponse(BaseModel):
    """创建任务响应"""
    job_id: str
    state: str  # "queued" (PATCH-4)
    created_at: str  # RFC3339 UTC
    
    model_config = PydanticConfig


class JobProgress(BaseModel):
    """任务进度"""
    stage: str  # "queued" | "sfm" | "gs_training" | "packaging"
    percentage: int = Field(..., ge=0, le=100)
    message: str
    
    model_config = PydanticConfig


class GetJobResponse(BaseModel):
    """查询任务状态响应"""
    job_id: str
    state: str
    progress: Optional[JobProgress] = None
    failure_reason: Optional[str] = None
    cancel_reason: Optional[str] = None
    created_at: str  # RFC3339 UTC
    updated_at: str  # RFC3339 UTC
    processing_started_at: Optional[str] = None  # RFC3339 UTC
    artifact_id: Optional[str] = None
    
    model_config = PydanticConfig


class JobListItem(BaseModel):
    """任务列表项"""
    job_id: str
    state: str
    created_at: str  # RFC3339 UTC
    artifact_id: Optional[str] = None
    
    model_config = PydanticConfig


class ListJobsResponse(BaseModel):
    """查询任务列表响应"""
    jobs: List[JobListItem]
    total: int
    limit: int
    offset: int
    
    model_config = PydanticConfig


class CancelJobRequest(BaseModel):
    """取消任务请求"""
    reason: str  # "user_requested" | "app_terminated"
    
    model_config = PydanticConfig


class CancelJobResponse(BaseModel):
    """取消任务响应"""
    job_id: str
    state: str  # "cancelled"
    cancel_reason: str
    cancelled_at: str  # RFC3339 UTC
    
    model_config = PydanticConfig


class TimelineEvent(BaseModel):
    """时间线事件"""
    timestamp: str  # RFC3339 UTC
    from_state: Optional[str] = None
    to_state: str
    trigger: str
    
    model_config = PydanticConfig


class GetTimelineResponse(BaseModel):
    """查询任务时间线响应"""
    job_id: str
    events: List[TimelineEvent]
    
    model_config = PydanticConfig


# MARK: - Artifacts API

class GetArtifactResponse(BaseModel):
    """获取产物元信息响应"""
    artifact_id: str
    job_id: str
    format: str  # "splat"
    size: int
    hash: str
    created_at: str  # RFC3339 UTC
    expires_at: str  # RFC3339 UTC
    download_url: str
    
    model_config = PydanticConfig


# Note: DownloadArtifactResponse不存在（PATCH-3：二进制响应）


# MARK: - Health API

class HealthResponse(BaseModel):
    """健康检查响应"""
    status: str
    version: str
    contract_version: str
    timestamp: str  # RFC3339 UTC
    
    model_config = PydanticConfig


# MARK: - Canonical JSON Hash (PATCH-7)

def compute_payload_hash(payload: dict) -> str:
    """
    计算payload的canonical JSON hash（PATCH-7：与Swift完全一致）
    
    Python canonicalization:
    json.dumps(payload, sort_keys=True, separators=(',', ':'), ensure_ascii=False)
    sha256(utf8_bytes)
    """
    import hashlib
    import json
    
    canonical = json.dumps(
        payload,
        sort_keys=True,
        separators=(',', ':'),
        ensure_ascii=False
    )
    return hashlib.sha256(canonical.encode('utf-8')).hexdigest()


# MARK: - Timestamp Format (GATE-4)

def format_rfc3339_utc(dt: datetime) -> str:
    """
    格式化时间为RFC3339 UTC格式（GATE-4）
    
    格式: YYYY-MM-DDTHH:MM:SSZ
    无毫秒，无微秒
    """
    # 移除微秒
    dt = dt.replace(microsecond=0)
    return dt.strftime("%Y-%m-%dT%H:%M:%SZ")

