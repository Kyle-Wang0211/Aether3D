# PR1E — API Contract Hardening Patch
# Anti-enumeration Lint Test

"""Lint测试：禁止handlers直接返回401/403（除auth middleware外）"""

import ast
import importlib.util
from pathlib import Path


def test_handlers_no_direct_401_403():
    """
    PR1E: 扫描所有handler模块，确保不直接返回401/403
    
    允许的例外：
    - auth middleware文件
    - 明确的auth依赖/中间件
    """
    handlers_dir = Path(__file__).parent.parent / "app" / "api" / "handlers"
    middleware_dir = Path(__file__).parent.parent / "app" / "middleware"
    
    # 白名单：auth相关的文件可以返回401/403
    whitelist = {
        "auth.py",
        "identity.py",  # IdentityMiddleware可能返回401相关的错误
    }
    
    violations = []
    
    # 扫描handlers目录
    for handler_file in handlers_dir.glob("*.py"):
        if handler_file.name == "__init__.py":
            continue
        
        violations.extend(_check_file_for_401_403(handler_file, whitelist))
    
    # 扫描middleware目录（排除白名单）
    for middleware_file in middleware_dir.glob("*.py"):
        if middleware_file.name == "__init__.py":
            continue
        
        if middleware_file.name not in whitelist:
            violations.extend(_check_file_for_401_403(middleware_file, whitelist))
    
    assert len(violations) == 0, (
        f"Found {len(violations)} violations of anti-enumeration rule:\n"
        + "\n".join(f"  - {v}" for v in violations)
        + "\n\n"
        + "API handlers must never return 401/403 for resource access.\n"
        + "Use ensure_ownership_or_404() from app.core.ownership instead."
    )


def _check_file_for_401_403(file_path: Path, whitelist: set) -> list:
    """检查文件是否包含直接返回401/403的代码"""
    violations = []
    
    try:
        with open(file_path, "r", encoding="utf-8") as f:
            content = f.read()
        
        # 检查HTTP状态码常量
        if "HTTP_401_UNAUTHORIZED" in content or "HTTP_403_FORBIDDEN" in content:
            # 解析AST以获取更精确的位置
            try:
                tree = ast.parse(content, filename=str(file_path))
                violations.extend(_find_401_403_in_ast(tree, file_path))
            except SyntaxError:
                # 如果AST解析失败，至少报告文件包含401/403
                violations.append(f"{file_path}: Contains HTTP_401_UNAUTHORIZED or HTTP_403_FORBIDDEN")
        
        # 检查数字状态码
        if "401" in content or "403" in content:
            # 更精确的检查：查找status_code=401或status_code=403
            lines = content.split("\n")
            for i, line in enumerate(lines, 1):
                if ("status_code" in line or "status_code=" in line) and ("401" in line or "403" in line):
                    # 排除注释
                    if not line.strip().startswith("#"):
                        violations.append(f"{file_path}:{i}: Direct use of 401/403 status code")
    
    except Exception as e:
        # 如果文件读取失败，跳过
        pass
    
    return violations


def _find_401_403_in_ast(tree: ast.AST, file_path: Path) -> list:
    """在AST中查找401/403的使用"""
    violations = []
    
    class Visitor(ast.NodeVisitor):
        def visit_Constant(self, node):
            if isinstance(node.value, int) and node.value in [401, 403]:
                violations.append(f"{file_path}:{node.lineno}: Direct use of status code {node.value}")
            self.generic_visit(node)
        
        def visit_Attribute(self, node):
            if isinstance(node.attr, str) and ("UNAUTHORIZED" in node.attr or "FORBIDDEN" in node.attr):
                violations.append(f"{file_path}:{node.lineno}: Direct use of {node.attr}")
            self.generic_visit(node)
    
    Visitor().visit(tree)
    return violations
