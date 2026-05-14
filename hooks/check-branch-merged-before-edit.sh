#!/bin/bash
# PreToolUse hook for Claude Code (matcher: Edit|Write)
#
# L3 战线前移：编辑文件前就拦"已 merged 分支"
#
# 目的：避免 Claude 在已 merged 的分支上写完一堆代码才发现 push 不上去，要 cherry-pick
# 重做。早一步拦截，让 Claude 直接换 worktree。
#
# 性能权衡：每次 Edit/Write 都跑一次 is-ancestor 检查，会有约 50-100ms 开销。
# 不做主动 fetch（避免每次编辑都拉远端），靠 push hook 在 push 时兜底 fetch。
# 所以这一层只能拦住"上一次会话里 push 过 → 用户在 Web merge → 这次会话继续编辑"
# 的标准场景，不拦"用户刚刚 merge 完，本地还没 fetch"的边缘场景。

set -e

INPUT=$(cat)
FILE_PATH=$(echo "$INPUT" | jq -r '.tool_input.file_path // ""')

# 没有文件路径则跳过
[ -z "$FILE_PATH" ] && exit 0

# 推断 git 仓库（非 git 目录静默放行）
DIR=$(dirname "$FILE_PATH")
GIT_ROOT=$(cd "$DIR" 2>/dev/null && git rev-parse --show-toplevel 2>/dev/null) || true
[ -z "$GIT_ROOT" ] && exit 0

cd "$GIT_ROOT"

# 探测主分支
MAIN_BRANCH=""
for candidate in master main; do
  if git show-ref --verify --quiet "refs/remotes/origin/$candidate" 2>/dev/null; then
    MAIN_BRANCH="$candidate"
    break
  fi
done
[ -z "$MAIN_BRANCH" ] && exit 0

# 当前分支
LOCAL_BRANCH=$(git branch --show-current 2>/dev/null)
BRANCH="${LOCAL_BRANCH#worktree-}"

# 跳过主分支
if [ "$BRANCH" = "$MAIN_BRANCH" ] || [ "$BRANCH" = "dev" ] || [ "$BRANCH" = "develop" ] || [ -z "$BRANCH" ]; then
  exit 0
fi

# 核心检查：本地 HEAD 是否已是 origin/MAIN 祖先
# 注：不主动 fetch（性能考虑）。用本地缓存的 origin/MAIN——上一次 push hook 跑过就够新了。
HEAD_SHA=$(git rev-parse HEAD 2>/dev/null)
[ -z "$HEAD_SHA" ] && exit 0

# 如果 HEAD 等于 origin/MAIN 且远端还没有该分支（新建分支首次 push），放行
MAIN_SHA=$(git rev-parse "origin/$MAIN_BRANCH" 2>/dev/null)
if [ "$HEAD_SHA" = "$MAIN_SHA" ] && ! git show-ref --verify --quiet "refs/remotes/origin/$BRANCH" 2>/dev/null; then
  exit 0
fi

if git merge-base --is-ancestor "$HEAD_SHA" "origin/$MAIN_BRANCH" 2>/dev/null; then
  SHORT_SHA=$(git rev-parse --short HEAD 2>/dev/null || echo "$HEAD_SHA")

  REASON=$(cat <<EOMSG
🚨 编辑被拦截：当前分支已 merged

文件：$FILE_PATH
当前分支：$LOCAL_BRANCH
HEAD：$SHORT_SHA

原因：本地 HEAD 已经是 origin/$MAIN_BRANCH 的祖先（说明该分支内容已被合入主分支）。
继续在这个分支上写代码，写完根本 push 不上去（pre-push hook 会拦住），相当于白干。

━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
必须先换 worktree，再编辑：
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

1. cd 到主仓库根（不是当前 worktree）

2. 同步主分支：
   git checkout $MAIN_BRANCH && git pull

3. 开新 worktree + 新分支（分支名必须是新的）：
   git worktree add .claude/worktrees/<new-name> -b <new-name> origin/$MAIN_BRANCH

4. 在新 worktree 里继续你的编辑：
   cd .claude/worktrees/<new-name>
   <重新做你刚才想做的修改>

不要：
❌ 在当前 worktree 继续 Edit/Write
❌ 试图 amend 当前 HEAD
❌ 强行 push -f
EOMSG
)
  printf '{"decision":"block","reason":%s}' "$(printf '%s' "$REASON" | jq -Rs .)"
  exit 0
fi

exit 0
