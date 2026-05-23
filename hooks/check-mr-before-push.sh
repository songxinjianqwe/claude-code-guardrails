#!/bin/bash
# PreToolUse hook for Claude Code (matcher: Bash)
#
# L2 反馈层：在 Claude 调 git push 前做 merged 检查
#
# 与 L1（.git/hooks/pre-push）的区别：
# - L1 是物理防线，Claude 怎么改命令前缀都拦得住，但反馈给 Claude 的形式是 git 进程
#   stderr，Claude 看到的是"push 失败"
# - L2 在 Claude 工具调用前拦截，用 decision:block + reason 给出结构化反馈，Claude
#   能直接看到"为什么不行 + 下一步该怎么做"，下一轮就会按正确流程操作
#
# 与原版相比的关键修复：
# - 原版用 `git merge-base --is-ancestor "origin/$BRANCH" origin/master` 检查远端
#   缓存的分支引用，amend + force push 场景会漏（远端 ref 不会自动更新）
# - 新版用 `git merge-base --is-ancestor HEAD origin/master` 检查本地 HEAD，
#   amend 后的 HEAD 立刻能被检测到
# - 增加：主动 fetch 当前分支的远端引用，让 origin/$BRANCH 反映真实状态
# - 增加：把 fetch 失败、glab 不可用等场景明确处理，不静默放行

set -e

INPUT=$(cat)

# ---- 提取命令 ----
COMMAND=$(echo "$INPUT" | jq -r '.tool_input.command // ""')
COMMAND_FLAT=$(printf '%s' "$COMMAND" | tr '\n\r' '  ')

# ---- 只拦截 git push / git send-pack（兼容多种写法）----
# send-pack 是底层传输命令，不触发 git hooks，Claude 会用它绕过 pre-push hook。
# 注意：不能对整个 COMMAND_FLAT 做 grep，因为 commit message / heredoc 里可能包含 "git push" 文本。
# 策略：用 && / ; / | 分割命令，逐段检查是否有 git push / git send-pack 子命令。
IS_GIT_PUSH=0
while IFS= read -r segment; do
  # 去掉前后空格
  segment=$(echo "$segment" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
  # 跳过 git commit / git add 等（它们的 -m 参数可能包含 "push" 文字）
  if echo "$segment" | grep -qE '^git[[:space:]]+(commit|add|log|diff|show|tag|stash|rebase|merge|cherry-pick|revert)'; then
    continue
  fi
  # 检查是否是 git push 或 git send-pack
  if echo "$segment" | grep -qE '^git[[:space:]]+([^|;&]*[[:space:]]+)?(push|send-pack)([[:space:]]|$)'; then
    IS_GIT_PUSH=1
    break
  fi
  # 兼容 cd xxx && git push / send-pack
  if echo "$segment" | grep -qE 'git[[:space:]]+([^|;&]*[[:space:]]+)?(push|send-pack)([[:space:]]|$)' && \
     ! echo "$segment" | grep -qE 'git[[:space:]]+(commit|add|log|diff|show|tag)'; then
    IS_GIT_PUSH=1
    break
  fi
done <<< "$(echo "$COMMAND_FLAT" | tr ';&|' '\n')"

if [ "$IS_GIT_PUSH" = "0" ]; then
  echo '{"decision": "approve"}'
  exit 0
fi

# ---- 拦截"绕 hook"的命令模式（Case A3、C1 实证）----
# 这些模式不是直接的 git 行为问题，而是 Claude 主动尝试绕过 hook 的信号
# 命中即 block，强制 Claude 走正常流程
#
# 拦截清单:
#   1. --no-verify / -n  → 绕 git pre-push（L1 物理防线）
#   2. core.hooksPath=/dev/null / core.hooksPath= → 同上（Case A3 实证）
#   3. GIT_PUSH_SKIP_MERGED_CHECK=1 之类的 env 绕过 → Claude 自造的（Case C1 实证）
#   4. git send-pack → 底层传输命令，不触发 pre-push hook（2026-05-14 实证）
BYPASS_REASON=""
if echo "$COMMAND_FLAT" | grep -qE -- '(^|[[:space:]])(--no-verify|-n)([[:space:]]|$)' && \
   echo "$COMMAND_FLAT" | grep -qE 'git[[:space:]]+([^|;&]*[[:space:]]+)?push'; then
  BYPASS_REASON="检测到 --no-verify / -n 标志（会绕 git pre-push hook，禁用）"
fi
if echo "$COMMAND_FLAT" | grep -qE 'core\.hooksPath[[:space:]]*=[[:space:]]*(/dev/null|""|'\'\'')'; then
  BYPASS_REASON="检测到 core.hooksPath=/dev/null（会禁用 git 全局 hook）"
fi
if echo "$COMMAND_FLAT" | grep -qE 'core\.hooksPath[[:space:]]*='; then
  # 任何形式的临时改 core.hooksPath 都拦（包括指向其他路径）
  # 合法场景几乎没有——用户/Claude 都不应该临时改 core.hooksPath
  if [ -z "$BYPASS_REASON" ]; then
    BYPASS_REASON="检测到临时改 core.hooksPath（任何形式都禁止，包括 git -c core.hooksPath=xxx）"
  fi
fi
if echo "$COMMAND_FLAT" | grep -qE '(GIT_PUSH_SKIP_MERGED_CHECK|SKIP_MERGED_CHECK|SKIP_HOOK)[[:space:]]*=[[:space:]]*[1-9yYtT]'; then
  if [ -z "$BYPASS_REASON" ]; then
    BYPASS_REASON="检测到 SKIP_MERGED_CHECK / SKIP_HOOK 类环境变量绕过"
  fi
fi
# 4. git send-pack → 底层命令绕过 pre-push hook
#    不直接 block 为"绕过"（避免 commit message 里出现 send-pack 文字误触发）
#    而是让它走正常 merged 检查流程——分段逻辑已经把 send-pack 识别为 IS_GIT_PUSH=1

if [ -n "$BYPASS_REASON" ]; then
  REASON=$(cat <<EOMSG
🚨 PUSH 被拦截：检测到绕 hook 行为

$BYPASS_REASON

完整命令：
$COMMAND_FLAT

━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
为什么这条命令被拦：
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

这些标志/环境变量的作用都是禁用 git pre-push hook 或类似机制，绕过分支合并状态检查。
之前的会话历史里 Claude 在 5/8、5/9 反复出现这类绕过行为，导致 commit 推到已 merged 分支丢失。

━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
正确做法：
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

1. 不要试图绕开 hook。如果 hook 拦你，是有原因的——通常是当前分支已 merged
2. 跑 git rev-parse --short HEAD 看本地 HEAD
3. 跑 git fetch origin master 同步主分支
4. 跑 git merge-base --is-ancestor HEAD origin/master
   - 返回 0（祖先）→ HEAD 已 merged，新开分支
   - 返回 1 → 应该能正常 push，hook 误判，请用 BYPASS_MERGED_CHECK=1（会记审计日志）

如果你确实是因为非 merged 场景需要 --no-verify（如 pre-commit hook 阻碍），
应该修 hook 不应该绕。
EOMSG
)
  printf '{"decision":"block","reason":%s}' "$(printf '%s' "$REASON" | jq -Rs .)"
  exit 0
fi

# ---- 解析实际工作目录（处理 cd dir / git -C dir / GIT_WORK_TREE=dir 模式）----
REPO_DIR=""
# 1. cd dir && git push
if [[ "$COMMAND_FLAT" == *"cd "*"git "*"push"* ]]; then
  rest="${COMMAND_FLAT#*cd }"
  while [[ "$rest" == [[:space:]]* ]]; do rest="${rest:1}"; done
  candidate=""
  i=0
  while [ "$i" -lt "${#rest}" ]; do
    c="${rest:$i:1}"
    case "$c" in
      ' '|$'\t'|';'|'|'|'&') break ;;
      *) candidate="${candidate}${c}" ;;
    esac
    i=$((i + 1))
  done
  REPO_DIR="$candidate"
fi
# 2. git -C <path> push
if [ -z "$REPO_DIR" ]; then
  C_PATH=$(echo "$COMMAND_FLAT" | grep -oE 'git[[:space:]]+-C[[:space:]]+[^[:space:]]+' | head -1 | sed 's/git[[:space:]]*-C[[:space:]]*//')
  # 展开 ~ 为 $HOME
  C_PATH="${C_PATH/#\~/$HOME}"
  if [ -n "$C_PATH" ] && [ -d "$C_PATH" ]; then
    REPO_DIR="$C_PATH"
  fi
fi
# 3. GIT_WORK_TREE=<path> 环境变量
if [ -z "$REPO_DIR" ]; then
  GWT_PATH=$(echo "$COMMAND_FLAT" | grep -oE 'GIT_WORK_TREE=[^[:space:]]+' | head -1 | sed 's/GIT_WORK_TREE=//')
  GWT_PATH="${GWT_PATH/#\~/$HOME}"
  if [ -n "$GWT_PATH" ] && [ -d "$GWT_PATH" ]; then
    REPO_DIR="$GWT_PATH"
  fi
fi

# ---- 显式指定了路径但解析不出真实目录：通常是路径含未展开的 $变量 / 命令替换 ----
# hook 在命令执行前只能拿到字面量，无法展开 $VAR。这种情况绝不能静默回退到 cwd——
# cwd 往往停在别的 worktree 上，会把"那个分支已 merged"误套到本次 push（2026-05-23 实证：
# git -C "$W" push 被误判为已 merged）。改为直接拦截并要求改用字面路径。
if [ -z "$REPO_DIR" ] || [ ! -d "$REPO_DIR" ]; then
  DYNAMIC_PATH=0
  if echo "$COMMAND_FLAT" | grep -qE 'git[[:space:]]+-C[[:space:]]+[^[:space:];&|]*[$`]' \
     || echo "$COMMAND_FLAT" | grep -qE 'GIT_WORK_TREE=[^[:space:];&|]*[$`]' \
     || echo "$COMMAND_FLAT" | grep -qE '(^|[;&|])[[:space:]]*cd[[:space:]]+[^[:space:];&|]*[$`]'; then
    DYNAMIC_PATH=1
  fi
  if [ "$DYNAMIC_PATH" = "1" ]; then
    REASON=$(cat <<'EOMSG'
🚨 PUSH 被拦截：路径含未展开变量，无法静态判断目标分支

命令里的 git -C / cd / GIT_WORK_TREE 路径包含 shell 变量（$VAR）或命令替换（`...` / $(...)）。
hook 在命令执行前只能看到字面量，无法展开成真实目录，也就无法可靠判断目标分支是否已 merged。
为避免静默回退到当前工作目录（很可能是另一个 worktree）导致误判，这里直接拦截。

✅ 正确做法：把路径写成完整字面量再重试，例如
   git -C /abs/path/to/worktree push -u origin <branch>
   或  cd /abs/path/to/worktree && git push -u origin <branch>
EOMSG
)
    printf '{"decision":"block","reason":%s}' "$(printf '%s' "$REASON" | jq -Rs .)"
    exit 0
  fi
  REPO_DIR=$(echo "$INPUT" | jq -r '.tool_input.cwd // .cwd // ""')
fi

if [ -n "$REPO_DIR" ] && [ -d "$REPO_DIR" ]; then
  cd "$REPO_DIR" || true
fi

# ---- 确认在 git repo 内 ----
if ! git rev-parse --git-dir >/dev/null 2>&1; then
  echo '{"decision": "approve"}'
  exit 0
fi

# ---- 探测主分支（master 优先）----
MAIN_BRANCH=""
for candidate in master main; do
  if git show-ref --verify --quiet "refs/remotes/origin/$candidate" 2>/dev/null; then
    MAIN_BRANCH="$candidate"
    break
  fi
done

if [ -z "$MAIN_BRANCH" ]; then
  echo '{"decision": "approve"}'
  exit 0
fi

# ---- 当前本地分支 ----
LOCAL_BRANCH=$(git branch --show-current 2>/dev/null)
# worktree 工具约定带 worktree- 前缀；剥离后查 GitLab
BRANCH="${LOCAL_BRANCH#worktree-}"

# 跳过主分支
if [ "$BRANCH" = "$MAIN_BRANCH" ] || [ "$BRANCH" = "dev" ] || [ "$BRANCH" = "develop" ] || [ -z "$BRANCH" ]; then
  echo '{"decision": "approve"}'
  exit 0
fi

# ---- 拉取最新主分支引用（防止本地缓存落后导致 is-ancestor 误判）----
git fetch origin "$MAIN_BRANCH" --quiet 2>/dev/null || true

# 同时拉取当前分支远端引用（用于兜底场景）
git fetch origin "$BRANCH" --quiet 2>/dev/null || true

# ---- 前置放行：从没 push 过的分支不可能是"已 merged"----
# MR merge 的前提是远端有该分支。如果 origin 上既没有 LOCAL_BRANCH 也没有 BRANCH，直接放行。
REMOTE_BRANCH_EXISTS=0
if git show-ref --verify --quiet "refs/remotes/origin/$LOCAL_BRANCH" 2>/dev/null; then
  REMOTE_BRANCH_EXISTS=1
elif [ "$LOCAL_BRANCH" != "$BRANCH" ] && git show-ref --verify --quiet "refs/remotes/origin/$BRANCH" 2>/dev/null; then
  REMOTE_BRANCH_EXISTS=1
fi
if [ "$REMOTE_BRANCH_EXISTS" = "0" ]; then
  echo '{"decision": "approve"}'
  exit 0
fi

# ---- 核心检查 1：本地 HEAD 是否已经是 origin/MAIN 的祖先 ----
HEAD_SHA=$(git rev-parse HEAD 2>/dev/null)
if [ -z "$HEAD_SHA" ]; then
  echo '{"decision": "approve"}'
  exit 0
fi

SHORT_SHA=$(git rev-parse --short HEAD 2>/dev/null || echo "$HEAD_SHA")

if git merge-base --is-ancestor "$HEAD_SHA" "origin/$MAIN_BRANCH" 2>/dev/null; then
  REASON=$(cat <<EOMSG
🚨 PUSH 被拦截：分支已 merged

当前分支：$LOCAL_BRANCH
本地 HEAD：$SHORT_SHA ($HEAD_SHA)
主分支：origin/$MAIN_BRANCH

原因：本地 HEAD 已经是 origin/$MAIN_BRANCH 的祖先，说明该分支的内容已经被合并进主分支。

继续 push 的后果：commit 会落到孤儿历史，不会进入主分支（白做）。

━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
必须执行的正确流程：
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

1. 找到主仓库根目录（不是当前 worktree）：
   先 git rev-parse --git-common-dir 看 git common 在哪
   或者 cd 到 ~/dev/java/<项目名>/（不带 .claude/worktrees/ 后缀）

2. 同步主分支：
   git checkout $MAIN_BRANCH && git pull origin $MAIN_BRANCH

3. 开新 worktree + 新分支（分支名要新，不要复用已 push 过的）：
   git worktree add .claude/worktrees/<new-name> -b <new-name> origin/$MAIN_BRANCH

4. 进入新 worktree，cherry-pick 你想保留的 commit：
   cd .claude/worktrees/<new-name>
   git cherry-pick $SHORT_SHA

5. push 新分支 + 新建 MR：
   git push -u origin <new-name>
   glab mr create --target-branch $MAIN_BRANCH --title "..." --description "..."

━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
绝对不要做的事：
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

❌ git push -f / git push --force / git push --force-with-lease 到当前分支
❌ git commit --amend 当前 HEAD 再 push
❌ 在当前分支上再加 commit 然后 push
❌ 在 settings.json 里临时关掉这个 hook
EOMSG
)
  # 用 jq 把 reason 安全转 JSON string
  printf '{"decision":"block","reason":%s}' "$(printf '%s' "$REASON" | jq -Rs .)"
  exit 0
fi

# ---- 核心检查 2：origin/BRANCH 是否已是 origin/MAIN 祖先（远端分支已被 merge）----
# 注：远端分支名可能保留 worktree- 前缀（push 时用完整的 LOCAL_BRANCH），所以先查 LOCAL_BRANCH 再 fallback 到 BRANCH
REMOTE_REF=""
if git show-ref --verify --quiet "refs/remotes/origin/$LOCAL_BRANCH" 2>/dev/null; then
  REMOTE_REF="origin/$LOCAL_BRANCH"
elif git show-ref --verify --quiet "refs/remotes/origin/$BRANCH" 2>/dev/null; then
  REMOTE_REF="origin/$BRANCH"
fi
if [ -n "$REMOTE_REF" ]; then
  REMOTE_BRANCH_SHA=$(git rev-parse "$REMOTE_REF" 2>/dev/null)
  if [ -n "$REMOTE_BRANCH_SHA" ] && git merge-base --is-ancestor "$REMOTE_BRANCH_SHA" "origin/$MAIN_BRANCH" 2>/dev/null; then
    # 远端分支 HEAD 已被合入 master
    # 但本地 HEAD 还没——这是 Claude 在已 merge 分支上 amend / 加新 commit 准备 push 的典型场景
    REASON=$(cat <<EOMSG
🚨 PUSH 被拦截：远端分支已 merged

当前分支：$LOCAL_BRANCH
本地 HEAD：$SHORT_SHA
远端 origin/$BRANCH：$(git rev-parse --short "$REMOTE_BRANCH_SHA" 2>/dev/null || echo "$REMOTE_BRANCH_SHA")

原因：远端分支 origin/$BRANCH 的 HEAD 已经是 origin/$MAIN_BRANCH 的祖先（已被 merge）。
你的本地 commit 是基于这个已 merged 的分支继续叠加的——push 上去会形成与 master 完全无关的孤儿历史。

必须开新分支：
1. 切回主仓库：cd <主仓库根目录>
2. git checkout $MAIN_BRANCH && git pull
3. 开新 worktree：git worktree add .claude/worktrees/<new-name> -b <new-name> origin/$MAIN_BRANCH
4. cherry-pick 本地未合并的 commit：git cherry-pick $SHORT_SHA
5. push + 新建 MR
EOMSG
)
    printf '{"decision":"block","reason":%s}' "$(printf '%s' "$REASON" | jq -Rs .)"
    exit 0
  fi
fi

# ---- 核心检查 3：glab API 兜底 ----
# 远端分支名可能是 LOCAL_BRANCH（带 worktree- 前缀）或 BRANCH（剥离后），两个都查
if command -v glab >/dev/null 2>&1; then
  MR_STATE=$(glab mr list --source-branch="$LOCAL_BRANCH" --merged 2>/dev/null | head -5 || true)
  if ! echo "$MR_STATE" | grep -q "!" && [ "$LOCAL_BRANCH" != "$BRANCH" ]; then
    MR_STATE=$(glab mr list --source-branch="$BRANCH" --merged 2>/dev/null | head -5 || true)
  fi
  if echo "$MR_STATE" | grep -q "!"; then
    MR_NUM=$(echo "$MR_STATE" | grep -oE '![0-9]+' | head -1)
    REASON=$(cat <<EOMSG
🚨 PUSH 被拦截：分支对应的 MR 已 merged

分支：$BRANCH
对应 MR：$MR_NUM（已 merged）

虽然本地 HEAD 还不是 master 祖先（可能你 amend 了新内容），但你在已 merged 的 MR 分支上继续工作——这就是把 commit 推到孤儿历史的标准失败模式。

必须开新分支：
1. 切回主仓库：cd <主仓库根目录>
2. git checkout $MAIN_BRANCH && git pull
3. 开新 worktree：git worktree add .claude/worktrees/<new-name> -b <new-name> origin/$MAIN_BRANCH
4. cherry-pick 你的改动到新分支
5. push + 新建 MR
EOMSG
)
    printf '{"decision":"block","reason":%s}' "$(printf '%s' "$REASON" | jq -Rs .)"
    exit 0
  fi
fi

# ---- 全部检查通过 ----
echo '{"decision": "approve"}'
