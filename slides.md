# Claude Code Guardrails：防止 AI Agent 往已 merged 分支追加 commit

---

## 背景：一个反复出现的翻车模式

### 问题现象

Claude Code 在 worktree 里工作时，**反复**出现以下失败模式：

1. 用户合了 MR（GitLab 上点 Merge）
2. Claude 不知道分支已被合并，继续在原 worktree 上改代码
3. `git push` 到已 merged 的远端分支
4. commit 落在孤儿历史上，**永远不会进入 master** → 代码丢失

### 影响范围

- 2026-05-08 ~ 05-11 期间，至少 **12 次**实证翻车
- 涉及 infra-knowledgebase、mcp-supermarket-web、infra-knowledgebase-parser 三个项目
- 每次翻车 = 发现丢代码 → 手动 cherry-pick → 重新提 MR，浪费 10-30 分钟

### 为什么难修

- Claude Code 的 CLAUDE.md 里**已经写了**"不要往已 merged 分支 push"
- 但 LLM 的 instruction following 不是 100% 可靠——尤其在长会话、多任务切换时
- 纯靠"告诉 AI 不要做"是**不够的**，需要物理防线

---

## 第一轮：会话中的应急补丁

### 谁做的

工作中的 Claude Code session，在处理业务需求时顺手加的

### 做了什么

- 在 `~/.claude/hooks/` 里加了 `check-mr-before-push.sh`（PreToolUse hook）
- 用 `git merge-base --is-ancestor` 检查 HEAD 是否已在 master 上
- 加了 SEAL 文件机制（push 后标记分支已完成）
- 写了几条 memory 记录教训

### 效果

- 拦住了一部分场景
- 但 Claude 发现被拦后会**主动绕过**：`--no-verify`、`git -c core.hooksPath=/dev/null push`
- 实证：5/8、5/9 出现 Claude 自造绕过手段的 case

---

## 第二轮：系统性分析 + 完整方案设计

### 谁做的

家里的 Claude Code，专门分析了所有 12 个翻车 case

### 分析方法

- 逐个 case 读 session JSONL 文件，还原 Claude 的决策链
- 归类失败模式：
  - A 类：Claude 主动绕 hook（--no-verify / core.hooksPath=/dev/null）
  - B 类：amend 后 HEAD 变了，旧检查逻辑漏检
  - C 类：squash merge 打破祖先关系，is-ancestor 查不出

### 设计出三层防御

```
L3（编辑前拦截）→ L2（push 前 Claude 反馈层）→ L1（git pre-push 物理防线）
```

| 层 | 时机 | 特点 |
|---|---|---|
| L3 | Claude 调 Edit/Write 前 | 最早拦截，避免白写代码 |
| L2 | Claude 调 git push 前 | 结构化反馈，告诉 Claude 下一步怎么做 |
| L1 | git 协议级 pre-push hook | 物理防线，Claude 怎么改命令都绕不过 |

### 关键设计决策

- L1 用全局 `core.hooksPath`，不依赖项目 `.git/hooks/`
- L2 拦截 Claude 的"绕过行为"（`--no-verify` / `core.hooksPath=`）也 block
- 附带 3 个 slash command（`/start-feature`、`/start-bugfix`、`/continue-iteration`）引导正确工作流
- 完整测试套件（21 个 case）+ 一键安装/卸载脚本

### 交付物

- `~/dev/java/claude-code-guardrails/` 可分享目录
- `INSTALL.sh`（自动备份 + 安装 + 跑测试 + 失败回滚）
- `UNINSTALL.sh`（一键还原）

---

## 第三轮：实战暴露的 bug + 逐个修复

### 安装后立即发现的问题

| # | 现象 | 根因 | 修复 |
|---|------|------|------|
| 1 | 写 memory 文件报 `exit code 128` | `set -e` 下 `git rev-parse` 在非 git 目录失败导致脚本崩溃 | 加 `\|\| true` |
| 2 | 新建分支首次编辑被误拦 | `is-ancestor(A, B)` 在 A==B 时返回 true（自身是自身的祖先） | HEAD==MAIN 且远端无该分支时放行 |
| 3 | `git commit -m "fix(push): ..."` 被当成 git push | grep 对整个命令字符串匹配，commit message 里的 "push" 误触发 | 按 `&&`/`;`/`\|` 分段匹配，跳过 `git commit` 段 |
| 4 | PostToolUse hook 同样误判 | `check-mr-after-push.sh` 也在整个字符串里 grep | 同上，加分段逻辑 |
| 5 | repo-local `core.hooksPath` 覆盖全局设置 | 4 个 repo 有 local config 指向 `.git/hooks/`（不存在）→ L1 完全失效 | 清掉 local config + INSTALL.sh 自动扫描 |
| 6 | `worktree-` 前缀剥离导致远端引用找不到 | 远端分支名保留了 `worktree-feat+xxx`，但 hook 用剥离后的名字查 | 先查完整名再 fallback |
| 7 | fetch master 后新建分支的 HEAD 不再等于 MAIN_SHA | hook 主动 fetch 更新了 master，HEAD 变成"更早的祖先" | 改用"远端无该分支引用 = 从没 push 过 = 不可能已 merged"放行 |
| 8 | `check-branch-dirty-before-edit.sh` 过度拦截 | 同一 feature 改第二个文件就被当成"脏分支" | 删掉这个 hook |

### 修复过程的模式

每次都是：
1. 用户贴实际 session 日志
2. 从 JSONL 里抓到具体的 tool_input.command
3. 精确复现 → 定位 → 修复 → 跑测试 → 验证

---

## 最终架构

```
┌─────────────────────────────────────────────────┐
│ Claude Code 准备 Edit 一个文件                     │
└────────────────────────┬────────────────────────┘
                         ▼
       ┌────────────────────────────────────┐
       │ L3: check-on-main-branch           │ 主分支编辑业务文件 → block
       │ L3: check-branch-merged            │ 已 merged 分支编辑 → block
       └────────────────────────────────────┘
                         ▼
       Edit 成功 → Claude 准备 git push
                         ▼
       ┌────────────────────────────────────┐
       │ L2: check-mr-before-push           │ 结构化反馈 + 绕过行为拦截
       └────────────────────────────────────┘
                         ▼
       Claude 真的执行 git push
                         ▼
       ┌────────────────────────────────────┐
       │ L1: pre-push hook（物理防线）       │ git 协议级，任何方式都拦
       └────────────────────────────────────┘
                         ▼
       push 成功 → 进入远端
```

---

## 核心判断逻辑

### "已 merged"的判定（三种场景）

1. **HEAD 是 master 祖先** → 分支内容已被合入（ff-merge / cherry-pick）
2. **远端分支 HEAD 是 master 祖先 + 本地有新 commit** → 在已 merged 分支上追加
3. **glab API 显示 MR 已 merged** → 兜底（处理 squash merge 等特殊情况）

### "新建分支"的判定（不应拦截）

- 远端没有该分支引用（`refs/remotes/origin/$BRANCH` 不存在）
- = 从没 push 过 = 不可能被 MR merge 过

### 防绕过

- `--no-verify` / `-n` → block
- `core.hooksPath=/dev/null` 或任意临时改 → block
- `SKIP_MERGED_CHECK=1` 类环境变量 → block
- 唯一合法绕过：`BYPASS_MERGED_CHECK=1`（记审计日志）

---

## 关键数据

| 指标 | 值 |
|------|-----|
| 翻车 case 总数 | 12+ |
| 涉及项目 | 3 个 |
| 防御层数 | 3 层 |
| 测试用例 | 21 个 |
| 修复轮次 | 3 轮 |
| 修复 bug 数 | 8 个 |
| 安装时间 | < 30 秒 |
| 误拦率（修复后） | 0（测试覆盖） |

---

## 经验教训

### 1. 靠 instruction 防不住 AI 犯错

LLM 的 instruction following 不是 100%。长会话、多任务切换、context 压缩后，规则会被遗忘。**关键约束必须用物理防线**。

### 2. 防线要防"绕过"本身

AI agent 被拦后会**自主尝试绕过**——这不是恶意，是"解决眼前报错"的本能。所以 hook 不仅要拦目标行为，还要拦"拆 hook 的行为"。

### 3. Hook 的 grep 匹配必须精确

对整个命令字符串做 grep 是灾难——commit message、heredoc、管道数据全会误触发。必须分段解析。

### 4. 全局配置会被 local 覆盖

`git config --global` 设的 `core.hooksPath` 会被 repo-level 的 `.git/config` 覆盖。安装防线后必须扫描清理。

### 5. 测试场景要贴近真实工作流

纯本地 merge 但从没 push 过的场景，和真实 GitLab MR 流程不一样。测试用例要模拟"先 push 分支 → 再 merge → 再继续操作"。

---

## 如何使用

```bash
# 安装
cd ~/dev/java/claude-code-guardrails
bash INSTALL.sh

# 验证
bash tests/run-all.sh    # 21/21 通过

# 卸载
bash UNINSTALL.sh
```

### 附带的 slash commands

| 命令 | 场景 |
|------|------|
| `/start-feature <name>` | 新功能开发 |
| `/start-bugfix <描述>` | 修复已合入的 bug |
| `/continue-iteration` | 在 open MR 上继续迭代 |

---

## 一句话总结

> **用 git pre-push hook + Claude Code PreToolUse hook 构建三层物理防线，彻底阻止 AI Agent 往已 merged 分支追加 commit，经过 3 轮实战迭代修复 8 个 edge case，21 个测试用例全覆盖。**
