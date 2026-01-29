# PR1E — API Contract Hardening Patch
# Error Code Evolution Guard (Closed-World)

"""错误码注册表（SSOT - Single Source of Truth）"""

from typing import List

# PR1E: 所有API错误码必须在此注册表中定义
# 任何新增错误码必须同时更新此注册表和API_CONTRACT.md文档

ERROR_CODE_REGISTRY: List[str] = [
    "INVALID_REQUEST",
    "AUTH_FAILED",
    "RESOURCE_NOT_FOUND",
    "STATE_CONFLICT",
    "PAYLOAD_TOO_LARGE",
    "RATE_LIMITED",
    "INTERNAL_ERROR",
]

# 验证：确保注册表包含所有7个业务错误码
assert len(ERROR_CODE_REGISTRY) == 7, f"Expected 7 error codes, found {len(ERROR_CODE_REGISTRY)}"

# 验证：确保无重复
assert len(ERROR_CODE_REGISTRY) == len(set(ERROR_CODE_REGISTRY)), "Duplicate error codes found in registry"
