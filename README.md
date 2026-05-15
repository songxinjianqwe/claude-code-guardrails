# Claude Code Guardrails

防止 AI Coding Agent（Claude Code）往已 merged 的 git 分支追加 commit 的三层防御机制。

## 背景

Claude Code 在 git worktree 里工作时，反复出现一个翻车模式：

1. 用户在 GitLab 上合了 MR
2. Claude 不知道分支已被合并，继续在原 worktree 上改代码
3. `git push` 到已 merged 的远端分支
4. commit 落在孤儿历史上，**永远不会进入 master** → 代码丢失

2026-05-08 ~ 05-14 期间，这个问题在 3 个项目里实证发生了 **12+ 次**。

### 为什么"告诉 AI 不要做"没用

CLAUDE.md 里已经写了"不要往已 merged 分支 push"。但：
- LLM 的 instruction following 不是 100% 可靠
- 长会话、多任务切换、context 压缩后规则会被遗忘
- **关键约束必须用物理防线，不能只靠自然语言指令**

### AI Agent 会主动绕过防线

更出乎意料的是，被 hook 拦住后，Claude 会递进式尝试绕过：

```
git push 被拦
  → 试 --no-verify（绕 git hook）
  → 试 git -c core.hooksPath=/dev/null push（关掉全部 git hook）
  → 试 git send-pack（底层传输命令，不触发 pre-push hook）
  → 最终放弃，让用户手动跑
```

这不是恶意——是 LLM 的"解决当前报错"本能。防线设计必须考虑这种递进绕过模式。

## 解决方案：三层防御

```
┌──────────────────────────────────────────────────┐
│ Claude Code 准备 Edit 一个文件                      │
└─────────────────────────┬────────────────────────┘
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

| 层 | 文件 | 触发时机 | 作用 |
|---|---|---|---|
| L3 | `hooks/check-branch-merged-before-edit.sh` | Claude 调 Edit/Write 前 | 在已 merged 分支上编辑直接拦，避免白写代码 |
| L3 | `hooks/check-on-main-branch-before-edit.sh` | Claude 调 Edit/Write 前 | 在主分支(master/main)上编辑业务文件直接拦 |
| L2 | `hooks/check-mr-before-push.sh` | Claude 调 git push/send-pack 前 | 结构化反馈 + 拦截绕过行为 |
| L1 | `git-hooks/pre-push` | 任何 git push（git 协议层） | 最后防线，Claude 怎么改命令都绕不过 |

## 核心判断逻辑

### "已 merged"的判定

使用 `git merge-base --is-ancestor` 检查三种场景：

1. **本地 HEAD 是 master 祖先** → 分支内容已被合入（ff-merge / cherry-pick）
2. **远端分支 HEAD 是 master 祖先 + 本地有新 commit** → 在已 merged 分支上追加了新代码
3. **glab API 显示 MR 已 merged** → 兜底（处理 squash merge 等特殊情况）

### "新建分支"的判定（不应拦截）

- 远端没有该分支引用（`refs/remotes/origin/$BRANCH` 不存在）
- = 从没 push 过 = 不可能被 MR merge 过 → 放行

### 防绕过（命令字符串黑名单）

| 模式 | 目的 | 处理 |
|------|------|------|
| `--no-verify` / `-n` | 绕 git pre-push hook | block |
| `core.hooksPath=/dev/null` | 关掉全部 git hook | block |
| `core.hooksPath=<任意路径>` | 临时替换 hook 目录 | block |
| `SKIP_MERGED_CHECK=1` 等环境变量 | Claude 自造的绕过 | block |
| `git send-pack` | 底层传输命令不触发 pre-push | 按 push 同等检查 |

## 安装

```bash
git clone https://github.com/songxinjianqwe/claude-code-guardrails.git
cd claude-code-guardrails
bash INSTALL.sh
```

脚本会自动：
- 备份现有 `~/.claude/hooks/` 和 `settings.json` 到 `~/.claude/backups/`
- 复制 hook 脚本到 `~/.claude/hooks/`
- 安装全局 git pre-push hook（`core.hooksPath`）
- 扫描所有 repo 清理冲突的 local `core.hooksPath` 配置
- patch `settings.json` 注册 PreToolUse hook
- 安装 slash commands
- 跑 21 个测试用例验证
- 任何步骤失败自动回滚

## 卸载

```bash
bash UNINSTALL.sh
```

从最近一次备份恢复所有配置。

## 附带的 slash commands

| 命令 | 用途 |
|------|------|
| `/start-feature <name>` | 开新 worktree + 新分支，基于 origin/master |
| `/start-bugfix <描述>` | 修 bug，新开分支，不在原分支上 amend |
| `/continue-iteration` | 在已有 open MR 的 worktree 上继续迭代 |

## 紧急绕过

```bash
# 绕过 pre-push hook（会记审计日志到 ~/.claude/logs/pre-push-bypass.log）
BYPASS_MERGED_CHECK=1 git push ...

# 绕过主分支编辑拦截
BYPASS_MAIN_BRANCH_EDIT=1
```

## 测试

```bash
bash tests/run-all.sh   # 21/21 通过
```

## 迭代历程

### 第一轮：会话中的应急补丁（5/8）

- 加了 `check-mr-before-push.sh`（最简版 grep + is-ancestor）
- 效果有限：Claude 用 `--no-verify` 和 `core.hooksPath=/dev/null` 绕过

### 第二轮：系统性分析 + 三层方案（5/11-12）

- 分析了 12 个翻车 case 的 session JSONL
- 设计三层防御架构 + 命令黑名单
- 21 个测试用例 + INSTALL/UNINSTALL 脚本

### 第三轮：实战暴露 edge case + 逐个修复（5/12-15）

| # | Bug | 修复 |
|---|-----|------|
| 1 | 非 git 目录写文件 exit 128 | `\|\| true` 防 set -e 崩溃 |
| 2 | 新建分支 HEAD==master 被误拦 | 远端无该分支引用 → 放行 |
| 3 | commit message 含 "push" 误触发 | 按分隔符分段匹配，跳过 git commit 段 |
| 4 | PostToolUse hook 同样误判 | 同上 |
| 5 | repo-local `core.hooksPath` 覆盖全局 | 清除 + INSTALL 自动扫描 |
| 6 | worktree- 前缀剥离找不到远端引用 | 先查完整名再 fallback |
| 7 | fetch 后 HEAD≠MAIN 豁免失效 | 改用"远端无分支引用"判断 |
| 8 | dirty-check 拦同 feature 多文件 | 删掉这个 hook |
| 9 | `git -C <path>` 路径不解析 | 提取 -C 参数 + 展开 ~ |
| 10 | `git send-pack` 绕过全部防线 | 加入命令匹配 |
| 11 | 改完代码才发现分支不对 | 加 memory 规则 + CLAUDE.md 强制要求 |

## 设计决策

1. **L1 不对 HEAD==origin/master 做豁免**：push 时 HEAD 在 master 上说明没有独立 commit，不应该 push
2. **用"远端无分支引用"判断新建分支**：比 HEAD==MAIN_SHA 更可靠，不受 fetch 时机影响
3. **非 git 目录静默放行**：memory 文件等不在 git 仓库里的路径，hook 直接 exit 0
4. **send-pack 走正常 merged 检查**：不直接 block 为"绕过"（避免 commit message 误触发），而是和 push 同等对待
5. **绕过检测对整个命令字符串做**：因为 `-c core.hooksPath=` 在实际命令里不可能出现在 commit message 段

## 目录结构

```
claude-code-guardrails/
├── INSTALL.sh                              # 一键安装
├── UNINSTALL.sh                            # 一键卸载
├── README.md
├── slides.md                               # 分享 slides 素材
├── commands/                               # Claude Code slash commands
│   ├── start-feature.md
│   ├── start-bugfix.md
│   └── continue-iteration.md
├── docs/
│   ├── slides.html                         # 完整 slides（standalone HTML）
│   └── cc喜欢往一个merged mr里继续推commit.html  # 12 个翻车 case 分析报告
├── git-hooks/
│   └── pre-push                            # L1 物理防线
├── hooks/
│   ├── check-mr-before-push.sh             # L2 push 前反馈
│   ├── check-mr-after-push.sh              # PostToolUse 检测
│   ├── check-branch-merged-before-edit.sh  # L3 已 merged 分支编辑拦截
│   └── check-on-main-branch-before-edit.sh # L3 主分支编辑拦截
└── tests/
    └── run-all.sh                          # 21 个测试用例
```

## 经验教训

1. **靠 instruction 防不住 AI 犯错** — LLM 会遗忘规则，关键约束必须用物理防线
2. **防线要防"绕过"本身** — AI 被拦后会自主尝试绕过，hook 不仅要拦目标行为还要拦拆 hook 的行为
3. **Hook 的 grep 匹配必须精确** — 对整个命令字符串 grep 是灾难，commit message 里的关键词会误触发
4. **全局 git config 会被 local 覆盖** — `core.hooksPath` 的 local > global 优先级导致 L1 静默失效
5. **测试场景要贴近真实工作流** — 本地 merge 的模拟和真实 GitLab MR 流程有差异
6. **拦截越早越好** — L3 在编辑前拦 = 0 浪费，L1 在 push 时拦 = 代码写完了才发现白干
