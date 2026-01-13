# PR#3 — API CONTRACT v2.0 (PATCHED)
## Constitutional Prompt · Closed World · Whitebox · Camera-Only · Industrial Hardened

**版本**: PR3-API-2.0  
**阶段**: WHITEBOX  
**作用域**: Aether3D REST API 合约（白盒主路径）  
**前置依赖**: PR#1, PR#2

**核心原则**:
- Camera-only input（只接受自带相机采集）
- Closed World（闭集世界）
- Hard boundaries（硬边界）
- Cost-predictable（成本可预测）

**数字摘要（SSOT）**:
- 3 资源组（uploads, jobs, artifacts）
- 12 端点（不可增减）
- 3 成功状态码 + 7 错误状态码 = **10 HTTP状态码**
- 7 业务错误码

---

## §0 ABSOLUTE AUTHORITY（NON-NEGOTIABLE）

本文档是 PR#3 唯一、最高、不可绕过的权威定义。

### §0.0 WHITEBOX IDENTITY RULE（白盒身份模型 · PATCH-1）

**In Whitebox v2.0, user identity is device-scoped, not account-scoped.**

所有 ownership、并发限制、幂等检测都基于 `X-Device-Id` 执行。

**硬规则**:
- 所有受保护端点（除 `/v1/health`）**必须**携带 `X-Device-Id` header
- 格式：UUID v4 小写带连字符（`^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$`）
- 缺失或格式非法 → 400 INVALID_REQUEST "Missing or invalid X-Device-Id"
- `user_id` 在白盒阶段 = `X-Device-Id`（1:1映射）

### §0.1 绝对规则

- Only the **12 endpoints** defined here EXIST.
- Only the **10 HTTP status codes** explicitly listed here are ALLOWED.
- Only the **7 business error codes** defined here are VALID.
- Only the request/response schemas defined here are LEGAL.
- Any undocumented behavior is a **BUG**, not a feature.

### §0.2 CLOSED WORLD PRINCIPLE（闭集原则）

| 情况 | 处理 |
|------|------|
| Unknown endpoints | → 404 |
| Unknown HTTP method for endpoint | → 404（不是405，PATCH-6） |
| Unknown fields in request | → 400 INVALID_REQUEST |
| Unknown fields in response | → **FORBIDDEN**（实现错误） |
| Unknown enum values | → 400 INVALID_REQUEST |
| Null where required | → 400 INVALID_REQUEST |

**FRAMEWORK DEFAULT STATUS CODES PROHIBITION（PATCH-5）**:
The following HTTP status codes MUST NEVER be returned under any circumstances:
- ❌ 422 Unprocessable Entity（FastAPI validation默认）
- ❌ 405 Method Not Allowed（必须用404替代，PATCH-6）
- ❌ 307/308 Redirect（禁止尾斜杠重定向，GATE-3）
- ❌ 204 No Content（所有响应必须有body）
- ❌ 431 Request Header Fields Too Large（用400替代）
- ❌ 415 Unsupported Media Type（用400替代）
- ❌ 416 Range Not Satisfiable（用400替代，PATCH-6）

All such framework-level responses MUST be intercepted and mapped to the allowed status codes.

---

## §1 HTTP STATUS CODES（CLOSED SET · 10 CODES）

### §1.1 Success Codes（3个）

| Code | Name | 使用场景 |
|------|------|----------|
| 200 | OK | 成功返回数据、更新成功 |
| 201 | Created | 成功创建资源 |
| 206 | Partial Content | Range请求部分下载 |

### §1.2 Error Codes（7个）

| Code | Name | 使用场景 |
|------|------|----------|
| 400 | Bad Request | 请求格式错误、参数无效、未知字段 |
| 401 | Unauthorized | 未认证或Token无效 |
| 404 | Not Found | 资源不存在、ownership校验失败（防枚举）、未知方法（PATCH-6） |
| 409 | Conflict | 状态冲突、幂等键冲突、重复操作 |
| 413 | Payload Too Large | 请求体过大（PATCH-8） |
| 429 | Too Many Requests | 限流 |
| 500 | Internal Server Error | 服务端内部错误 |

**任何其他HTTP状态码 → BUG**

---

## §2 BUSINESS ERROR CODES（CLOSED SET · 7 CODES）

| Code | 含义 | HTTP Status | 触发场景 |
|------|------|-------------|----------|
| INVALID_REQUEST | 请求格式错误 | 400 | JSON解析失败、必填字段缺失、未知字段、非法枚举值、X-Device-Id格式错误 |
| AUTH_FAILED | 认证失败 | 401 | Token无效、过期、缺失 |
| RESOURCE_NOT_FOUND | 资源不存在 | 404 | ID不存在、ownership校验失败（防枚举）、未知端点、未知方法 |
| STATE_CONFLICT | 状态冲突 | 409 | 非法状态转移、重复操作、幂等键冲突 |
| PAYLOAD_TOO_LARGE | 请求体过大 | 413 | 分片超过5MB、JSON body超过64KB（PATCH-8） |
| RATE_LIMITED | 限流 | 429 | 请求过于频繁 |
| INTERNAL_ERROR | 服务端错误 | 500 | 服务端内部错误（不暴露细节） |

---

## §3 RESPONSE FORMAT（UNIFIED & CLOSED）

### §3.1 Success Response

```json
{
  "success": true,
  "data": { ... }
}
```

### §3.2 Error Response

```json
{
  "success": false,
  "error": {
    "code": "ERROR_CODE",
    "message": "Human readable message",
    "details": {}
  }
}
```

### §3.3 Response Headers（MANDATORY · GATE-7）

**必需响应头（所有响应都必须包含）**:

| Header | 说明 | 示例 |
|--------|------|------|
| X-Request-Id | 请求唯一标识（回传或生成） | `req_abc123` |
| Content-Type | 内容类型 | `application/json`（JSON响应）或 `application/octet-stream`（二进制） |

**X-Request-Id规则**:
- 客户端可在请求中携带 `X-Request-Id`
- 服务端必须在响应中回传相同的 `X-Request-Id`（包括二进制下载响应）
- 若客户端未携带或格式非法，服务端必须生成并返回
- 格式约束：`[a-zA-Z0-9_-]`，最大长度64字符

### §3.4 Error Details Type（PATCH-2）

**details字段支持闭集值类型**:

`DetailValue := string | int | int_array`

**Swift实现**:
```swift
enum DetailValue: Codable, Equatable {
    case string(String)
    case int(Int)
    case intArray([Int])  // 用于missing chunks: [3,4,7]
}
```

**Python实现**:
```python
DetailValue = Union[str, int, List[int]]
```

**示例**:
```json
{
  "success": false,
  "error": {
    "code": "INVALID_REQUEST",
    "message": "Missing chunks",
    "details": {
      "missing": [3, 4, 7]
    }
  }
}
```

---

## §4 ENDPOINT DEFINITIONS（CLOSED SET · 12 ENDPOINTS）

| # | Method | Path | 描述 | 认证 |
|---|--------|------|------|------|
| 1 | GET | /v1/health | 健康检查 | ❌（GATE-8豁免） |
| 2 | POST | /v1/uploads | 创建上传会话 | ✅ |
| 3 | PATCH | /v1/uploads/{id}/chunks | 上传分片 | ✅ |
| 4 | GET | /v1/uploads/{id}/chunks | 查询已上传分片 | ✅ |
| 5 | POST | /v1/uploads/{id}/complete | 完成上传 | ✅ |
| 6 | POST | /v1/jobs | 创建任务（特殊场景） | ✅ |
| 7 | GET | /v1/jobs/{id} | 查询任务状态 | ✅ |
| 8 | GET | /v1/jobs | 查询任务列表 | ✅ |
| 9 | POST | /v1/jobs/{id}/cancel | 取消任务 | ✅ |
| 10 | GET | /v1/jobs/{id}/timeline | 查询任务时间线 | ✅ |
| 11 | GET | /v1/artifacts/{id} | 获取产物元信息 | ✅ |
| 12 | GET | /v1/artifacts/{id}/download | 下载产物 | ✅ |

**路由前缀**: `/v1`（不是`/api/v1`）

---

## §5 UPLOADS API（4 ENDPOINTS · CAMERA-ONLY）

### §5.1 POST /v1/uploads — 创建上传会话

**请求**:
```json
{
  "capture_source": "aether_camera",
  "capture_session_id": "uuid-of-capture-session",
  "bundle_hash": "sha256_hash_of_bundle",
  "bundle_size": 104857600,
  "chunk_count": 20,
  "idempotency_key": "sha256_hash_for_idempotency",
  "device_info": {
    "model": "iPhone 15 Pro",
    "os_version": "iOS 17.2",
    "app_version": "1.0.0"
  }
}
```

**硬边界约束**:
- `capture_source` 必须为 `"aether_camera"` → 400 INVALID_REQUEST
- `bundle_size` ≤ 500MB → 400 INVALID_REQUEST
- `chunk_count` ≤ 200 → 400 INVALID_REQUEST
- 用户活跃上传数 ≤ 1 → 409 STATE_CONFLICT

**成功响应**: 201 Created
```json
{
  "success": true,
  "data": {
    "upload_id": "upload_uuid",
    "upload_url": "/v1/uploads/upload_uuid/chunks",
    "chunk_size": 5242880,
    "expires_at": "2024-01-14T12:00:00Z"
  }
}
```

**CHUNK_SIZE权威来源（GATE-6）**: 服务端返回的 `chunk_size` 是唯一权威值。客户端**必须**使用服务端返回的 `chunk_size`。

---

### §5.2 PATCH /v1/uploads/{id}/chunks — 上传分片

**请求**:
- Content-Type: `application/octet-stream`
- Headers:
  - `Content-Length`: **必填**（GATE-5）
  - `X-Chunk-Index`: 分片索引（0-based）
  - `X-Chunk-Hash`: 分片SHA256哈希

**硬边界约束（GATE-5）**:
- Content-Length必须存在且≥1 → 400 INVALID_REQUEST
- Content-Length与实际body必须一致 → 400 INVALID_REQUEST
- 分片大小 ≤ 5MB → 413 PAYLOAD_TOO_LARGE（PATCH-8）

**成功响应**: 200 OK
```json
{
  "success": true,
  "data": {
    "chunk_index": 5,
    "chunk_status": "stored",
    "received_size": 5242880,
    "total_received": 6,
    "total_chunks": 20
  }
}
```

---

### §5.3 GET /v1/uploads/{id}/chunks — 查询已上传分片

**成功响应**: 200 OK
```json
{
  "success": true,
  "data": {
    "upload_id": "upload_uuid",
    "received_chunks": [0, 1, 2, 5, 6],
    "missing_chunks": [3, 4, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16, 17, 18, 19],
    "total_chunks": 20,
    "status": "in_progress",
    "expires_at": "2024-01-14T12:00:00Z"
  }
}
```

---

### §5.4 POST /v1/uploads/{id}/complete — 完成上传

**请求**:
```json
{
  "bundle_hash": "sha256_hash_of_complete_bundle"
}
```

**成功响应**: 200 OK
```json
{
  "success": true,
  "data": {
    "upload_id": "upload_uuid",
    "bundle_hash": "sha256_hash",
    "status": "completed",
    "job_id": "job_uuid"
  }
}
```

**关键行为（PATCH-4）**:
- 自动创建Job（初始状态：`"queued"`）
- 返回job_id供后续查询

---

## §6 JOBS API（5 ENDPOINTS · STATE MACHINE BOUND）

### §6.1 POST /v1/jobs — 创建任务

**请求**:
```json
{
  "bundle_hash": "sha256_hash",
  "parent_job_id": null,
  "idempotency_key": "sha256_hash_for_idempotency"
}
```

**成功响应（PATCH-4）**: 201 Created
```json
{
  "success": true,
  "data": {
    "job_id": "job_uuid",
    "state": "queued",
    "created_at": "2024-01-13T12:00:00Z"
  }
}
```

**初始状态（PATCH-4）**: 所有job创建路径（upload complete + POST /jobs）→ state = `"queued"`

---

### §6.2 GET /v1/jobs/{id} — 查询任务状态

**成功响应**: 200 OK
```json
{
  "success": true,
  "data": {
    "job_id": "job_uuid",
    "state": "processing",
    "progress": {
      "stage": "sfm",
      "percentage": 45,
      "message": "Running structure from motion"
    },
    "failure_reason": null,
    "cancel_reason": null,
    "created_at": "2024-01-13T12:00:00Z",
    "updated_at": "2024-01-13T12:05:30Z",
    "processing_started_at": "2024-01-13T12:03:00Z",
    "artifact_id": null
  }
}
```

**时间戳格式（GATE-4）**: RFC3339 UTC，无毫秒，格式：`YYYY-MM-DDTHH:MM:SSZ`

---

### §6.3 GET /v1/jobs — 查询任务列表

**查询参数**:
- `state`: 过滤状态（可选，逗号分隔）
- `limit`: 返回数量（默认20，范围1-100）
- `offset`: 偏移量（默认0，必须≥0）

**成功响应**: 200 OK
```json
{
  "success": true,
  "data": {
    "jobs": [...],
    "total": 15,
    "limit": 20,
    "offset": 0
  }
}
```

---

### §6.4 POST /v1/jobs/{id}/cancel — 取消任务

**请求**:
```json
{
  "reason": "user_requested"
}
```

**成功响应**: 200 OK
```json
{
  "success": true,
  "data": {
    "job_id": "job_uuid",
    "state": "cancelled",
    "cancel_reason": "user_requested",
    "cancelled_at": "2024-01-13T12:10:00Z"
  }
}
```

---

### §6.5 GET /v1/jobs/{id}/timeline — 查询任务时间线

**成功响应**: 200 OK
```json
{
  "success": true,
  "data": {
    "job_id": "job_uuid",
    "events": [
      {
        "timestamp": "2024-01-13T12:00:00Z",
        "from_state": null,
        "to_state": "pending",
        "trigger": "job_created"
      }
    ]
  }
}
```

---

## §7 ARTIFACTS API（2 ENDPOINTS）

### §7.1 GET /v1/artifacts/{id} — 获取产物元信息

**成功响应**: 200 OK
```json
{
  "success": true,
  "data": {
    "artifact_id": "artifact_uuid",
    "job_id": "job_uuid",
    "format": "splat",
    "size": 52428800,
    "hash": "sha256_hash",
    "created_at": "2024-01-13T12:30:00Z",
    "expires_at": "2024-01-20T12:30:00Z",
    "download_url": "/v1/artifacts/artifact_uuid/download"
  }
}
```

---

### §7.2 GET /v1/artifacts/{id}/download — 下载产物（PATCH-3）

**重要（PATCH-3）**: 此端点返回**二进制数据**，不是JSON。

**Python实现**: `StreamingResponse`（无APIResponse包装）  
**Swift实现**: `(Data, HTTPURLResponse)`  
**必需headers**: X-Request-Id（GATE-7）、Content-Length、Accept-Ranges、ETag、Content-Disposition

**Range请求支持**:
- 格式：`bytes=start-end`（单Range，PATCH-6）
- 无效格式 → 400 INVALID_REQUEST（不是416）
- 多Range → 400 INVALID_REQUEST

**成功响应**:
- 完整下载：200 OK
- 部分下载：206 Partial Content（包含Content-Range）

---

## §8 HEALTH CHECK

### §8.1 GET /v1/health — 健康检查（GATE-8）

**无需X-Device-Id**（唯一不需要身份标识的端点）

**响应Headers**:
- `Cache-Control: no-store`

**成功响应**: 200 OK
```json
{
  "success": true,
  "data": {
    "status": "healthy",
    "version": "1.0.0",
    "contract_version": "PR3-API-2.0",
    "timestamp": "2024-01-13T12:00:00Z"
  }
}
```

---

## §9 IDEMPOTENCY RULES

### §9.1 幂等键生成规则（PATCH-7）

**Canonical JSON Hash算法（SSOT）**:

**Python**:
```python
import json
import hashlib

def compute_payload_hash(payload: dict) -> str:
    canonical = json.dumps(
        payload,
        sort_keys=True,
        separators=(',', ':'),
        ensure_ascii=False
    )
    return hashlib.sha256(canonical.encode('utf-8')).hexdigest()
```

**Swift必须产生相同的字节序列**。

**共享测试向量**（必须通过）:
- 嵌套对象
- 数组
- Unicode字符串

---

## §10 REQUEST SIZE ENFORCEMENT（PATCH-8）

| Layer | Limit | Error | Location |
|-------|-------|-------|----------|
| Headers (total ≤ 8KB) | 8KB | 400 INVALID_REQUEST | middleware |
| JSON body (≤ 64KB) | 64KB | 413 PAYLOAD_TOO_LARGE | middleware |
| Binary chunk (≤ 5MB) | 5MB | 413 PAYLOAD_TOO_LARGE | handler |

**规则**:
- Header size = sum(key + value + overhead)
- JSON size仅适用于 `application/json`
- 二进制上传忽略JSON限制

---

## §11 FRAMEWORK OVERRIDES（PATCH-5, GATE-2, GATE-3）

### §11.1 全局异常处理器（PATCH-5）

**必须覆盖**:
- `RequestValidationError` → 400 INVALID_REQUEST（不是422）
- `MethodNotAllowed` → 404 RESOURCE_NOT_FOUND（不是405，GATE-2）

### §11.2 禁用尾斜杠重定向（GATE-3）

FastAPI必须实例化时设置：
```python
app = FastAPI(redirect_slashes=False)
```

测试：`/v1/health/` → 404

---

## §12 CONTRACT CONSTANTS（SSOT）

### §12.1 版本
- CONTRACT_VERSION = "PR3-API-2.0"
- API_VERSION = "v1"

### §12.2 计数
- ENDPOINT_COUNT = 12
- SUCCESS_CODE_COUNT = 3
- ERROR_CODE_COUNT = 7
- HTTP_CODE_COUNT = 10
- BUSINESS_ERROR_CODE_COUNT = 7

### §12.3 上传限制
- MAX_BUNDLE_SIZE_BYTES = 500 * 1024 * 1024
- MAX_CHUNK_COUNT = 200
- CHUNK_SIZE_BYTES = 5 * 1024 * 1024（GATE-6）
- MAX_CHUNK_SIZE_BYTES = 5 * 1024 * 1024

### §12.4 并发限制
- MAX_ACTIVE_UPLOADS_PER_USER = 1
- MAX_ACTIVE_JOBS_PER_USER = 1

### §12.5 请求限制（PATCH-8）
- MAX_HEADER_SIZE_BYTES = 8 * 1024
- MAX_JSON_BODY_SIZE_BYTES = 64 * 1024

### §12.6 取消窗口
- CANCEL_WINDOW_SECONDS = 30

---

## §13 PATCH SUMMARY

| Patch | 内容 | 实施位置 |
|-------|------|----------|
| PATCH-1 | X-Device-Id身份模型 | identity.py middleware |
| PATCH-2 | DetailValue支持int_array | contract.py (Swift + Python) |
| PATCH-3 | Artifact下载是二进制 | artifact_handlers.py |
| PATCH-4 | Job初始状态="queued" | upload_handlers.py, job_handlers.py |
| PATCH-5 | 禁止框架默认状态码 | main.py异常处理器 |
| PATCH-6 | 未知方法→404 | routes.py, main.py |
| PATCH-7 | Canonical JSON hash | idempotency.py, Swift hash工具 |
| PATCH-8 | 请求大小强制 | middleware, handlers |

---

## §14 FINAL GATES SUMMARY

| Gate | 内容 | 实施位置 |
|------|------|----------|
| GATE-1 | Pydantic v2配置 | contract.py (model_config) |
| GATE-2 | 405→404强制 | main.py异常处理器 |
| GATE-3 | 禁用尾斜杠重定向 | main.py FastAPI实例化 |
| GATE-4 | 时间戳格式RFC3339 | 所有时间字段 |
| GATE-5 | Chunk完整性校验 | upload_handlers.py |
| GATE-6 | Chunk size服务端权威 | upload_handlers.py |
| GATE-7 | X-Request-Id所有响应 | request_id.py middleware |
| GATE-8 | /health豁免 | routes.py, identity.py |

---

**END OF DOCUMENT**

