#!/bin/bash
# PreToolUse hook for Claude Code (matcher: Edit|Write)
#
# 用户没用 slash command 时的兜底：在主分支 (master/main/dev/develop) 上直接 Edit/Write 业务文件 → block
# 强制用户走 /start-feature 或 /start-bugfix 开新 worktree
#
# 设计原则：
# - 主分支干净 ≠ 可以编辑（即使现有的 check-branch-dirty-before-edit 放行了，本 hook 也会拦）
# - 唯一例外：被编辑的文件是 README / docs / CHANGELOG 等顶层文档（轻量改动允许）
# - 例外可以通过 BYPASS_MAIN_BRANCH_EDIT=1 紧急绕过

set -e

INPUT=$(cat)
FILE_PATH=$(echo "$INPUT" | jq -r '.tool_input.file_path // ""')

[ -z "$FILE_PATH" ] && exit 0

# 紧急绕过
if [ "${BYPASS_MAIN_BRANCH_EDIT:-0}" = "1" ]; then
  exit 0
fi

# 推断 git 仓库（非 git 目录静默放行）
DIR=$(dirname "$FILE_PATH")
GIT_ROOT=$(cd "$DIR" 2>/dev/null && git rev-parse --show-toplevel 2>/dev/null) || true
[ -z "$GIT_ROOT" ] && exit 0

cd "$GIT_ROOT"

# 当前分支
LOCAL_BRANCH=$(git branch --show-current 2>/dev/null)
[ -z "$LOCAL_BRANCH" ] && exit 0

# 只拦主分支
case "$LOCAL_BRANCH" in
  master|main|dev|develop)
    ;;
  *)
    exit 0
    ;;
esac

# 顶层文档类轻量改动放行（README / CHANGELOG / docs / .gitignore 等）
# 用 basename + 路径包含模式判断（避免 realpath --relative-to 在 macOS 不支持的问题）
BASENAME=$(basename "$FILE_PATH")
case "$BASENAME" in
  README*|CHANGELOG*|LICENSE*|.gitignore|.gitattributes|CONTRIBUTING*)
    exit 0
    ;;
esac

# 顶层 docs/ 和 .claude/ 目录下的文件也放行（这些目录通常是文档/配置）
case "$FILE_PATH" in
  "$GIT_ROOT"/docs/*|"$GIT_ROOT"/.claude/*|*/docs/*|*/.claude/*)
    exit 0
    ;;
esac

# 拦截：在主分支上 Edit/Write 业务文件
REASON=$(cat <<EOMSG
🚨 编辑被拦截：当前在主分支 $LOCAL_BRANCH 上

文件：$FILE_PATH

不要在主分支上直接修改业务代码。每个新开发任务都必须开新 worktree + 新分支。

━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
请用以下命令之一启动新任务：
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

【全新功能开发】
  /start-feature <feature-name>
  例：/start-feature user-permission

【修复已 merged commit 引入的 bug】
  /start-bugfix <commit-hash 或 MR-编号> + bug 现象描述
  例：/start-bugfix 修复 abc123 引入的 ESC 关闭 bug

【在已有 open MR 上继续迭代】
  先 cd 到对应的 worktree，然后 /continue-iteration

━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
紧急绕过（极少数场景，如文档轻量改动）：
  BYPASS_MAIN_BRANCH_EDIT=1
（注：README/CHANGELOG/docs/* 已自动放行）
EOMSG
)

printf '{"decision":"block","reason":%s}' "$(printf '%s' "$REASON" | jq -Rs .)"
