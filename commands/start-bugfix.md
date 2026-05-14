---
name: start-bugfix
description: 修复一个已 merged 的 commit 引入的 bug。自动开新 worktree + 新分支基于 origin/master，绝不在原 commit 所在分支上 amend。
---

你要修复一个已 merged 的 commit 引入的 bug：$ARGUMENTS

**严格按以下顺序执行。**

## 步骤 1：参数和上下文收集

如果 $ARGUMENTS 为空：问用户 "bug 是什么？建议格式：『修复 <commit-hash 或 MR-编号> 引入的 <bug 现象>』"

收集以下信息（如果用户没在 $ARGUMENTS 里提供，主动问）：
- 引入 bug 的 commit hash 或 MR 编号
- bug 的具体现象
- 期望行为

## 步骤 2：找到主仓库根

```bash
git rev-parse --git-common-dir
# 去 /.git 后 cd 到主仓库根
```

## 步骤 3：同步 master + 看引入 bug 的 commit

```bash
git fetch origin master
git checkout master
git pull --ff-only origin master
git show <hash> --stat
# 或 glab mr view <mr-id>
```

读完后**用一句话总结这个 commit 做了什么**给用户看，确认理解正确再继续。

## 步骤 4：决定 fix 分支名

格式：`fix/<short-description>`
- 例：`fix/call-log-modal-esc`
- 例：`fix/billing-totals-rounding`

如果分支已存在：换一个名字或加后缀。

## 步骤 5：开新 worktree + 新分支（基于 origin/master，不是 bug 所在分支）

```bash
git worktree add .claude/worktrees/<fix-name> -b fix/<fix-name> origin/master
cd .claude/worktrees/<fix-name>
```

## 步骤 6：验证环境

```bash
git branch --show-current   # fix/<...>
git log --oneline -1        # 应该是 origin/master HEAD
```

## 步骤 7：报告

```
✅ bug fix 准备就绪

引入 bug 的 commit: <hash> "<title>"
这个 commit 做了什么: <一句话总结>

bug 现象: <用户描述>
期望行为: <用户描述>

新 worktree 路径: .claude/worktrees/<fix-name>
新分支: fix/<fix-name>
基于 master HEAD: <short sha>

准备修复。是否补充信息？
```

然后停下等用户确认或补充，**不要立刻开始改文件**。

## 严格禁止

- ❌ 在引入 bug 的原分支上 amend（这是经典坑：原分支已 merged，amend 后 push 进孤儿历史）
- ❌ 在主工作区直接改文件
- ❌ 复用已存在的 fix/ 分支名
- ❌ 跳过 fetch 直接基于落后的本地 master
- ❌ 在用户确认信息前自作主张定位代码或改文件

## 失败兜底

任何一步失败 → 报告错误原文 + STOP。
