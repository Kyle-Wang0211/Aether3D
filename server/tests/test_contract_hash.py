# PR1E — API Contract Hardening Patch
# CONTRACT Doc Hash Gate Test

"""测试API_CONTRACT.md的哈希值必须与API_CONTRACT.hash一致"""

import hashlib
from pathlib import Path


def test_contract_hash_matches():
    """
    PR1E: 验证API_CONTRACT.md的SHA256哈希值与API_CONTRACT.hash文件一致
    
    如果文档更改但hash文件未更新，此测试将失败。
    """
    contract_path = Path(__file__).parent.parent.parent / "docs" / "constitution" / "API_CONTRACT.md"
    hash_path = Path(__file__).parent.parent.parent / "docs" / "constitution" / "API_CONTRACT.hash"
    
    # 读取文档内容
    with open(contract_path, "rb") as f:
        content = f.read()
    
    # 计算SHA256哈希
    computed_hash = hashlib.sha256(content).hexdigest()
    
    # 读取存储的哈希值
    with open(hash_path, "r") as f:
        stored_hash = f.read().strip()
    
    # 验证哈希值匹配
    assert computed_hash == stored_hash, (
        f"API_CONTRACT.md hash mismatch!\n"
        f"Computed: {computed_hash}\n"
        f"Stored:   {stored_hash}\n"
        f"If you modified API_CONTRACT.md, update API_CONTRACT.hash with the new hash."
    )
