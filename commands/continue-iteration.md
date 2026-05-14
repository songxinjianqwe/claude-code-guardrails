---
name: continue-iteration
description: 在一个还没 merged 的 MR 上继续迭代（补改动、改 review 意见、加测试等）。会检查 MR 状态，如果已 merged 会强制让你用 /start-bugfix。
---

你要在一个还没 merged 的 MR 上继续迭代：$ARGUMENTS

**严格按以下顺序执行。**

## 步骤 1：检查当前分支

```bash
git branch --show-current
git rev-parse --show-toplevel
```

- 当前分支是 master/main/dev/develop → STOP，告诉用户 "你在主分支上，应该用 /start-feature 开新分支，不是 /continue-iteration"
- 当前不在 worktree 里（路径不含 `.claude/worktrees/`） → 警告用户 "你在主工作区，建议先 cd 到对应的 worktree 再用本 command"

## 步骤 2：检查 MR 状态（关键）

```bash
BRANCH=$(git branch --show-current)
# 剥掉 worktree- 前缀（如果有）
RAW_BRANCH="${BRANCH#worktree-}"

glab mr list --source-branch "$RAW_BRANCH"
```

读 glab 输出，判断：
- **state = merged** → **STOP**，明确告诉用户：「这个分支对应的 MR 已经 merged。不能在已 merged 的 MR 上追加 commit。请用 `/start-bugfix` 开新分支修复。」**绝不继续。**
- **state = closed (未 merged)** → 问用户是否要 reopen MR 还是新开
- **state = open** → 继续步骤 3
- **没有 MR** → 问用户是不是首次 push（没建 MR），如果是建议先 push 再建

## 步骤 3：同步远端

```bash
git fetch origin master
git fetch origin "$RAW_BRANCH"
```

检查：
- 远端是否落后本地：`git log --oneline origin/$RAW_BRANCH..HEAD`
- master 是否前进：`git rev-list HEAD..origin/master --count`
- 如果 master 前进 > 5 commits → 建议先 rebase origin/master，让用户决定

## 步骤 4：状态总结报告

```
✅ 准备继续迭代

当前分支: <name>
对应 MR: <id> "<title>" (state=open)
master 是否前进: <count> commits
本地是否领先远端: <count> commits

请描述要补充的改动。
```

然后停下等用户描述。

## 步骤 5：用户描述完之后

正常改文件、commit、push。
push 时会触发 pre-push hook 再次检查 merged 状态（如果你在步骤 2 之后用户在 Web 上手动合并了，这里会拦住——这是设计上的双重保险）。

## 严格禁止

- ❌ 跳过步骤 2 的 MR 状态检查
- ❌ MR 已 merged 还继续 commit/push
- ❌ 在主工作区切分支
- ❌ 凭记忆判断 MR 状态（必须 glab mr list 实查）

## 失败兜底

任何一步失败 → 报告错误原文 + STOP。
