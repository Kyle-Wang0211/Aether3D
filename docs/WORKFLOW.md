# Aether3D Development Workflow

本文件定义 Aether3D 的**分支策略、开发流程、回滚规则与阶段约束**。  
所有贡献者（包括作者本人）必须遵守。

---

## 核心原则（不可妥协）

- **main 分支历史只允许向前追加**
- **公共历史只允许修正（revert），禁止改写**
- **所有功能开发必须通过 Pull Request**
- **Phase Tag 是锚点，不可移动**

---

## 分支策略

### main（最高保护级别）

允许：
- Pull Request 合并（**仅 squash merge**）

禁止：
- 直接 push
- git reset
- git rebase
- git push --force / --force-with-lease

回滚方式：
- **只能通过 git revert**
- revert 必须走 PR（Rollback via PR）

---

### feature / phase 分支

命名规范：
- `phase1/<topic>`
- `feat/<topic>`
- `hotfix/<topic>`

来源规则：
- 必须从 `main` 拉取
- 禁止从其他 feature 分支派生

同步规则：
- 使用 `git merge origin/main`
- ❌ 禁止 rebase main

历史整理：
- **未 push 前**：允许 git reset / amend
- **已 push 或创建 PR 后**：只允许 revert 或新 commit 修复

生命周期：
- 合并到 main 后立即删除（本地 + 远端）

---

## Pull Request 规则

- main 只接受 PR
- PR 合并策略：**Squash merge**
- 每个 PR 对应一个清晰目标
- PR 描述必须说明：
  - 做了什么
  - 是否可能需要回滚
  - 回滚方式

---

## Rollback via PR（强制）

标准流程：
1. 从 main 拉 rollback 分支
2. 执行 git revert <commit>
3. 解决冲突（如有）
4. push 分支
5. 创建 PR（说明原因与影响）
6. 合并 PR

详细演练见：`docs/ROLLBACK.md`

---

## Phase 进入与退出

### Phase 0
- 只读锚点
- 对应 tag：phase0
- 永不移动

### Phase 0.5
- 仅允许文档 / 脚本 / CI
- 禁止任何功能与工程文件变更
- 验收标准：
  - Workflow 文档齐全
  - Rollback 文档齐全
  - 至少一次真实 revert 演练

### Phase 1
- 功能开发阶段
- 必须基于最新 main（完成所有 0.5 护栏）
- 出现事故必须可一键 revert

---

## 禁止清单（Phase 0.5 特别强调）

- *.swift
- *.metal
- *.xcodeproj/project.pbxproj
- Package.swift
- Info.plist / Entitlements
