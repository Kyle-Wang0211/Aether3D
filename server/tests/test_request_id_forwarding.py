# PR1E — API Contract Hardening Patch
# Request-Id Forwarding Test

"""测试Request-Id转发：接受并回传有效值，否则生成新的"""

import re
from fastapi.testclient import TestClient

from main import app

client = TestClient(app)

# Request-Id格式：^[A-Za-z0-9_-]{8,64}$
REQUEST_ID_PATTERN = re.compile(r'^[A-Za-z0-9_-]{8,64}$')


def get_headers(device_id: str = "550e8400-e29b-41d4-a716-446655440000", request_id: str = None) -> dict:
    """获取测试headers"""
    headers = {
        "X-Device-Id": device_id,
    }
    if request_id:
        headers["X-Request-Id"] = request_id
    return headers


def test_request_id_valid_forwarded():
    """
    PR1E: 有效X-Request-Id → 回传相同值
    """
    valid_request_id = "test-req-id-12345678"  # 8+字符
    headers = get_headers(request_id=valid_request_id)
    
    response = client.get("/v1/health", headers=headers)
    
    assert response.status_code == 200
    assert "X-Request-Id" in response.headers
    assert response.headers["X-Request-Id"] == valid_request_id


def test_request_id_invalid_generated():
    """
    PR1E: 无效X-Request-Id → 生成新值
    """
    invalid_request_ids = [
        "short",  # 少于8字符
        "invalid@format!",  # 包含非法字符
        "x" * 65,  # 超过64字符
        "",  # 空字符串
    ]
    
    for invalid_id in invalid_request_ids:
        headers = get_headers(request_id=invalid_id)
        response = client.get("/v1/health", headers=headers)
        
        assert response.status_code == 200
        assert "X-Request-Id" in response.headers
        assert response.headers["X-Request-Id"] != invalid_id
        # 验证生成的ID符合格式
        assert REQUEST_ID_PATTERN.match(response.headers["X-Request-Id"])


def test_request_id_missing_generated():
    """
    PR1E: 缺失X-Request-Id → 生成新值
    """
    headers = get_headers()  # 不包含X-Request-Id
    response = client.get("/v1/health", headers=headers)
    
    assert response.status_code == 200
    assert "X-Request-Id" in response.headers
    # 验证生成的ID符合格式
    assert REQUEST_ID_PATTERN.match(response.headers["X-Request-Id"])
    # 验证格式：应该以req_开头（根据中间件实现）
    assert response.headers["X-Request-Id"].startswith("req_")


def test_request_id_in_error_response():
    """
    PR1E: 错误响应也包含X-Request-Id
    """
    headers = get_headers(request_id="test-error-req-id")
    
    # 触发400错误（无效请求）
    response = client.post("/v1/uploads", json={}, headers=headers)
    
    assert response.status_code == 400
    assert "X-Request-Id" in response.headers
    assert response.headers["X-Request-Id"] == "test-error-req-id"
    
    # 验证错误响应body中也包含request_id（如果实现）
    # 注意：当前实现可能只在header中包含，body中可能没有
    # 根据PR1E要求，body中的request_id应该与header一致


def test_request_id_min_length():
    """
    PR1E: 验证最小长度8字符
    """
    # 7字符（无效）
    headers = get_headers(request_id="1234567")
    response = client.get("/v1/health", headers=headers)
    assert response.headers["X-Request-Id"] != "1234567"
    
    # 8字符（有效）
    headers = get_headers(request_id="12345678")
    response = client.get("/v1/health", headers=headers)
    assert response.headers["X-Request-Id"] == "12345678"


def test_request_id_max_length():
    """
    PR1E: 验证最大长度64字符
    """
    # 64字符（有效）
    valid_64 = "a" * 64
    headers = get_headers(request_id=valid_64)
    response = client.get("/v1/health", headers=headers)
    assert response.headers["X-Request-Id"] == valid_64
    
    # 65字符（无效）
    invalid_65 = "a" * 65
    headers = get_headers(request_id=invalid_65)
    response = client.get("/v1/health", headers=headers)
    assert response.headers["X-Request-Id"] != invalid_65
