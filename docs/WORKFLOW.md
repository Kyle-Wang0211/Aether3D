# Aether3D Development Workflow

本文件定义 Aether3D 的分支策略、提交规范与回滚流程。
所有贡献者（包括 AI 工具）必须遵守。

---

## 分支策略

### main 分支
- ✅ 只接受 Pull Request
- ❌ 禁止直接 push
- ❌ 禁止 force push
- ✅ 历史只允许向前追加

### Phase 0
- 以 Git Tag `phase0` 形式存在
- 仅用于查看与回滚参考
- 永不移动、永不修改

### phase0.5 分支
- 当前护栏分支
- Phase 1 必须从此分支拉出

### 功能分支命名规范
- `phase1/*`：Phase 1 功能开发
- `feat/*`：独立功能
- `hotfix/*`：紧急修复
- `release/*`：发布准备

---

## 提交规范

格式：
{Phase}: {简要说明}
示例：
- `Phase 0.5-1: guardrails docs`
- `Phase 1-1: camera capture MVP`

规则：
- 一个 commit 只做一件事
- 禁止混杂文档 + 功能代码

---

## 标准开发流程（强制）

1. 运行 Preflight 检查
2. 从 phase0.5 创建分支
3. 开发
4. 更新相关文档
5. 提交 commit
6. 创建 PR
7. Code Review
8. CI 通过
9. 合并到 main
10. 创建 Tag（如适用）

---

## 回滚流程（唯一合法）

### 允许
```bash
git revert <commit>
git push

禁止
git reset --hard
git rebase
git push --force

原则
	•	所有回滚必须可追溯
	•	不允许“假装没发生过”
---

## 三、你现在该做的检查清单（很短）

完成粘贴后，在终端跑：

```bash
wc -l README.md docs/PHASES.md docs/WORKFLOW.md
git status --short

