# claude-code-guardrails

防止 Claude Code 往已 merged 的分支追加 commit 的三层防御机制。

## 问题

Claude Code 在 worktree 里工作时，经常出现：
1. 用户合了 MR → Claude 继续在原 worktree 上改代码 → push 到已 merged 分支 → commit 丢失
2. Claude 在主分支上直接 Edit 业务代码（没开 worktree）

## 解决方案

三层拦截，从早到晚：

```
L3（编辑前）→ L2（push 前，Claude 工具层）→ L1（git pre-push hook，物理防线）
```

| 层 | 文件 | 触发时机 | 作用 |
|---|---|---|---|
| L3 | `hooks/check-branch-merged-before-edit.sh` | Claude 调 Edit/Write 前 | 在已 merged 分支上编辑直接拦，避免白写 |
| L3 | `hooks/check-on-main-branch-before-edit.sh` | Claude 调 Edit/Write 前 | 在主分支(master/main)上编辑业务文件直接拦 |
| L2 | `hooks/check-mr-before-push.sh` | Claude 调 git push 前 | 结构化反馈，告诉 Claude 下一步怎么做 |
| L1 | `git-hooks/pre-push` | 任何 git push（物理层） | 最后防线，Claude 怎么改命令都绕不过 |

## 安装

```bash
cd ~/dev/java/claude-code-guardrails
bash INSTALL.sh
```

脚本会自动：
- 备份现有配置到 `~/.claude/backups/`
- 复制 hook 脚本
- 安装全局 git pre-push hook
- patch settings.json 注册新 hook
- 跑测试验证
- 失败自动回滚

## 卸载

```bash
bash UNINSTALL.sh
```

## 附带的 slash commands

| 命令 | 用途 |
|------|------|
| `/start-feature <name>` | 开新 worktree + 新分支，基于 origin/master |
| `/start-bugfix <描述>` | 修 bug，新开分支，不在原分支上 amend |
| `/continue-iteration` | 在已有 open MR 的 worktree 上继续迭代 |

## 紧急绕过

```bash
# 绕过 pre-push hook（会记审计日志）
BYPASS_MERGED_CHECK=1 git push ...

# 绕过主分支编辑拦截
BYPASS_MAIN_BRANCH_EDIT=1
```

## 测试

```bash
bash tests/run-all.sh
```

## 设计决策

1. **L1 pre-push 不对 HEAD==origin/master 做豁免**：push 时如果 HEAD 就是 master，说明没有独立 commit，不应该 push
2. **L3 编辑 hook 对"新建分支首次编辑"做豁免**：判断条件是 HEAD==origin/master 且远端没有该分支引用（`refs/remotes/origin/$BRANCH` 不存在）
3. **非 git 目录的文件静默放行**：memory 文件等不在 git 仓库里的路径，hook 直接 exit 0
4. **拦截 Claude 绕 hook 的行为**：`--no-verify`、`core.hooksPath=/dev/null`、`SKIP_MERGED_CHECK=1` 等绕过手段都会被 L2 拦截
