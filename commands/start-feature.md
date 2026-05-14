---
name: start-feature
description: 开始一个全新的 feature 开发。自动开新 worktree + 新分支 + 同步 master。基于 origin/master 最新 HEAD。
---

你要开始一个新 feature 的开发：$ARGUMENTS

**严格按以下顺序执行，每一步都要打印结果给用户看，不要静默跳过任何一步。**

## 步骤 1：参数检查

- 如果 $ARGUMENTS 为空：立刻问用户 "feature 名字是什么？（kebab-case，比如 user-permission）"，等用户回答再继续
- feature 名字会被转成分支名 `feat/<name>`，例如 `feat/user-permission`
- 如果 $ARGUMENTS 含有空格 / 特殊字符：先转成合法的 kebab-case，让用户确认

## 步骤 2：找到主仓库根（不是当前 worktree）

```bash
git rev-parse --git-common-dir
# 输出形如 /path/to/repo/.git
# 去掉 /.git 就是主仓库根

cd <主仓库根>
git rev-parse --show-toplevel
# 确认 cd 成功
```

如果当前不在任何 git 仓库里：STOP，告诉用户 "你当前不在 git 仓库内，请先 cd 到目标项目根"。

## 步骤 3：同步 master

```bash
git fetch origin master
git checkout master
git pull --ff-only origin master
```

如果 `git pull` 失败（本地 master 不是 fast-forward）：STOP，报告用户。**不要 git reset --hard / git stash**。

## 步骤 4：检查分支名不冲突

```bash
git branch --list "feat/<feature-name>"
git ls-remote --heads origin "feat/<feature-name>"
```

如果分支名已存在（本地或远端任一）：STOP，建议用户加后缀（比如 v2、retry）或换一个名字。**不要复用已存在的分支名。**

## 步骤 5：开新 worktree + 新分支

```bash
mkdir -p .claude/worktrees
git worktree add .claude/worktrees/<feature-name> -b feat/<feature-name> origin/master
```

如果命令失败：报告原因，让用户决定下一步，不要自作主张清理重试。

## 步骤 6：cd 到新 worktree 验证环境

```bash
cd .claude/worktrees/<feature-name>
git branch --show-current   # 应该输出 feat/<feature-name>
git log --oneline -1        # 应该是 origin/master 的 HEAD
git status                  # 应该是 nothing to commit
```

## 步骤 7：报告给用户

输出格式（不要省略任何字段）：

```
✅ 新 feature 已就绪

worktree 路径: .claude/worktrees/<feature-name>
分支名: feat/<feature-name>
基于的 master HEAD: <short sha> "<commit title>"
工作目录干净: 是

请描述 feature 的具体需求。
```

然后**停下等用户描述需求**，不要立刻开始猜或开始改文件。

## 严格禁止

- ❌ 在主工作区切分支（git checkout / git switch）
- ❌ 复用已存在的分支名
- ❌ 跳过 git fetch（直接基于落后的本地 master）
- ❌ 静默修改默认值（比如把 feat/ 前缀换成别的）
- ❌ 跑 git reset --hard 或 git stash
- ❌ 在用户描述需求之前自作主张改任何文件

## 失败兜底

任何一步失败 → 把错误原文报告给用户 + STOP。
不要"我试试别的方法"。流程是死的，错了让用户决定。
