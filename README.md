# Aether3D

Aether3D 是一个基于 Gaussian Splatting 的 3D 点云采集、训练与可视化项目。

## 当前阶段
- Phase 0: Frozen Baseline（tag: `phase0`，只读）
- Phase 0.5: Guardrails（制度护栏，当前阶段）

## 开发硬性约束
- 禁止直接 push 到 `main`
- 禁止 force push 到 `main`
- 所有破坏性变更必须使用 `git revert`（不得 reset/rebase）
- `main` 历史只允许向前追加

## 回滚方式（正确 vs 错误）
- ✅ 正确：`git revert <commit>`
- ❌ 错误：`git reset --hard phase0`；`git rebase phase0`

## 新开发者开始方式
1) `git checkout phase0.5`（或包含 0.5 护栏的 `main`）
2) 从其上创建功能分支：`git checkout -b phase1/feature-name`
3) 开发、提交、走 PR 合并流程





