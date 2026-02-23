# PR#3 — API Contract v2.0
# Stage: WHITEBOX | Camera-only
# Endpoints: 12 | HTTP Codes: 10 (3 success + 7 error) | Business Errors: 7

"""健康检查处理器（GATE-8：豁免X-Device-Id）"""

from datetime import datetime
from fastapi import status
from fastapi.responses import JSONResponse

from app.api.contract import APIResponse, HealthResponse, format_rfc3339_utc
from app.api.contract_constants import APIContractConstants


async def health_check() -> JSONResponse:
    """
    GET /v1/health - 健康检查
    
    GATE-8: 无需X-Device-Id，无需限流，无需幂等性
    """
    response_data = HealthResponse(
        status="healthy",
        version="1.0.0",  # TODO: 从构建信息获取
        contract_version=APIContractConstants.CONTRACT_VERSION,
        timestamp=format_rfc3339_utc(datetime.utcnow())
    )
    
    api_response = APIResponse(success=True, data=response_data.model_dump())
    
    response = JSONResponse(
        status_code=status.HTTP_200_OK,
        content=api_response.model_dump(exclude_none=True)
    )
    
    # Cache-Control: no-store
    response.headers["Cache-Control"] = "no-store"
    
    return response

