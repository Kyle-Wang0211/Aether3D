# Rollback Playbook

本文件定义 Aether3D 的**唯一官方回滚方式**，用于多人协作与事故处理。

---

## 回滚原则

- **main 分支永不改写历史**
- **回滚必须留下痕迹**
- **修正 > 删除**

---

## 什么时候用 revert，什么时候不用

### 必须使用 git revert
- main 分支
- 已 push 的 feature 分支
- 已合并 PR
- 任何公共历史

### 允许使用 git reset（严格条件）
- 仅限 feature 分支
- 且 commit 从未 push 到远端

---

## 标准 Revert 流程（main）

```bash
git checkout -b rollback/<reason>
git revert <commit_sha>
# 如有冲突，解决后：
git commit
git push origin rollback/<reason>

→ 创建 PR → Review → 合并
```

---

## Revert Merge Commit（如存在）

仅在 main 存在 merge commit 时：

```bash
git revert -m 1 <merge_commit_sha>
```

PR 描述必须说明：
- 为什么 revert merge
- 影响范围
- 是否需要后续补救 PR

---

## 回到 Phase 0 的正确方式

仅用于查看：

```bash
git checkout phase0
```

❌ 禁止：
- `git reset --hard phase0`
- `git rebase phase0`

---

## 紧急例外（极少数）

允许场景：
- API Key / Token 泄露
- 法律 / 合规风险
- 严重数据破坏

处理顺序（必须）：
1. 立即吊销 / 轮换密钥
2. 再处理 Git 历史
3. 记录 incident（原因 + 影响 + 修复）

---

## 常见坑

- revert 一个 revert（会重新引入 bug）
- 在 main 上 rebase
- 使用 --force-with-lease 伪装安全
- 回滚不走 PR（破坏审计）
