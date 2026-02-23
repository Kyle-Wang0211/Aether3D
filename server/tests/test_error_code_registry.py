# PR1E — API Contract Hardening Patch
# Error Code Evolution Guard Test

"""测试错误码注册表与文档的一致性"""

import re
from pathlib import Path

from app.api.error_registry import ERROR_CODE_REGISTRY
from app.api.contract import APIErrorCode


def test_error_codes_match_registry():
    """
    PR1E: 验证APIErrorCode枚举值与ERROR_CODE_REGISTRY完全匹配
    """
    registry_set = set(ERROR_CODE_REGISTRY)
    enum_set = {e.value for e in APIErrorCode}
    
    assert registry_set == enum_set, (
        f"Error code mismatch!\n"
        f"Registry: {registry_set}\n"
        f"Enum:     {enum_set}\n"
        f"Missing in enum: {registry_set - enum_set}\n"
        f"Extra in enum:   {enum_set - registry_set}"
    )


def test_error_codes_match_documentation():
    """
    PR1E: 验证ERROR_CODE_REGISTRY与API_CONTRACT.md文档中的错误码完全匹配
    
    从文档中提取错误码列表，与注册表进行集合比较。
    """
    contract_path = Path(__file__).parent.parent.parent / "docs" / "constitution" / "API_CONTRACT.md"
    
    with open(contract_path, "r", encoding="utf-8") as f:
        content = f.read()
    
    # 从文档中提取错误码（查找§2 BUSINESS ERROR CODES章节）
    # 格式: | INVALID_REQUEST | 请求格式错误 | 400 | ...
    error_code_pattern = r'\|\s+([A-Z_]+)\s+\|'
    
    # 查找§2章节
    section_match = re.search(r'## §2 BUSINESS ERROR CODES.*?## §', content, re.DOTALL)
    if not section_match:
        # 如果找不到§2，尝试查找整个文档
        section_content = content
    else:
        section_content = section_match.group(0)
    
    # 提取所有错误码
    documented_codes = set()
    for match in re.finditer(error_code_pattern, section_content):
        code = match.group(1)
        # 过滤掉非错误码的匹配（如HTTP状态码）
        if code in ["Code", "含义", "HTTP", "Status", "触发场景"]:
            continue
        documented_codes.add(code)
    
    # 验证注册表与文档完全匹配
    registry_set = set(ERROR_CODE_REGISTRY)
    
    assert registry_set == documented_codes, (
        f"Error code mismatch between registry and documentation!\n"
        f"Registry:     {sorted(registry_set)}\n"
        f"Documented:   {sorted(documented_codes)}\n"
        f"Missing in doc: {registry_set - documented_codes}\n"
        f"Extra in doc:   {documented_codes - registry_set}\n"
        f"If you added a new error code, update both ERROR_CODE_REGISTRY and API_CONTRACT.md"
    )
