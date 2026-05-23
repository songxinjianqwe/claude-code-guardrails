#!/bin/bash
# PreToolUse hook: git push 前检查当前分支是否落后 origin/<default>
# 落后则阻止 push，强制 Claude 先 rebase，避免 MR 提交后又跟新合的 master 冲突
#
# 输入：从 stdin 读取 tool_input JSON
# 输出：JSON 到 stdout（落后则 decision=block，否则 approve 透传）

INPUT=$(cat)
COMMAND=$(echo "$INPUT" | jq -r '.tool_input.command // ""')

# 用 tr 把换行/回车折成空格，避免 HEREDOC commit message 多行命令导致 grep 单行匹配失败。
COMMAND_FLAT=$(printf '%s' "$COMMAND" | tr '\n\r' '  ')

# 分段检测：按 && ; | 分割命令，逐段检查是否有 git push 子命令
# 避免 commit message / heredoc 里包含 "git push" 文本导致误触发
IS_GIT_PUSH=0
while IFS= read -r segment; do
  segment=$(echo "$segment" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
  [ -z "$segment" ] && continue
  # 跳过 git commit / git add 等（它们的 -m 参数可能包含 "push" 文字）
  if echo "$segment" | grep -qE '^git[[:space:]]+(commit|add|log|diff|show|tag|stash|rebase|merge|cherry-pick|revert)'; then
    continue
  fi
  # 检查是否是 git push
  if echo "$segment" | grep -qE '^git[[:space:]]+([^|;&]*[[:space:]]+)?push([[:space:]]|$)'; then
    IS_GIT_PUSH=1
    break
  fi
  # 兼容 cd xxx && git push
  if echo "$segment" | grep -qE 'git[[:space:]]+([^|;&]*[[:space:]]+)?push([[:space:]]|$)' && \
     ! echo "$segment" | grep -qE 'git[[:space:]]+(commit|add|log|diff|show|tag)'; then
    IS_GIT_PUSH=1
    break
  fi
done <<< "$(echo "$COMMAND_FLAT" | tr ';&|' '\n')"

if [ "$IS_GIT_PUSH" = "0" ]; then
  exit 0
fi
# 跳过 --help / --dry-run
if echo "$COMMAND_FLAT" | grep -qE 'git[[:space:]]+push[[:space:]].*(--help|--dry-run)'; then
  exit 0
fi

# 解析 cd 目录（支持 "cd /path && git push" 模式）
CWD=$(echo "$INPUT" | jq -r '.cwd // ""')
REPO_DIR=""
if echo "$COMMAND_FLAT" | grep -qE 'cd[[:space:]]+[^[:space:]]+.*&&.*git[[:space:]]+push'; then
  REPO_DIR=$(echo "$COMMAND_FLAT" | sed -E 's/^.*cd[[:space:]]+([^[:space:]]+).*/\1/')
fi
[ -z "$REPO_DIR" ] && REPO_DIR="$CWD"
if [ -n "$REPO_DIR" ] && [ -d "$REPO_DIR" ]; then
  cd "$REPO_DIR" 2>/dev/null || exit 0
fi

# 必须在 git 仓库内
git rev-parse --git-dir >/dev/null 2>&1 || exit 0

# 从 push 命令提取实际推送的远程分支名
PUSH_BRANCH=""
REFSPEC=$(echo "$COMMAND_FLAT" | grep -oE '[a-zA-Z0-9._/-]+:[a-zA-Z0-9._/-]+' | head -1)
if [ -n "$REFSPEC" ]; then
  PUSH_BRANCH="${REFSPEC##*:}"
fi
if [ -z "$PUSH_BRANCH" ]; then
  # `git push origin <branch>` 提取 origin 后第一个非 flag 参数
  AFTER_ORIGIN=$(echo "$COMMAND_FLAT" | sed -E 's/.*origin[[:space:]]*//' | sed 's/[[:space:]]*2>.*//')
  for word in $AFTER_ORIGIN; do
    if [[ "$word" != -* ]]; then
      PUSH_BRANCH="$word"
      break
    fi
  done
fi

BRANCH=$(git branch --show-current 2>/dev/null)
# 如果推送目标分支和当前分支不同（如 HEAD:new-branch），跳过检查
if [ -n "$PUSH_BRANCH" ] && [ "$PUSH_BRANCH" != "$BRANCH" ]; then
  exit 0
fi
[ -z "$BRANCH" ] && exit 0

# 如果 push 命令带了 -o merge_request.target=<branch>，用该分支做比较
MR_TARGET=$(echo "$COMMAND_FLAT" | grep -oE 'merge_request\.target=[^[:space:]]+' | head -1 | sed 's/merge_request\.target=//')
# 推断默认分支（远端 HEAD），fallback master
DEFAULT=$(git symbolic-ref refs/remotes/origin/HEAD 2>/dev/null | sed 's@^refs/remotes/origin/@@')
[ -z "$DEFAULT" ] && DEFAULT=master

# 如果指定了 MR target 且不等于 DEFAULT，用 MR target 做比较基准
if [ -n "$MR_TARGET" ] && [ "$MR_TARGET" != "$DEFAULT" ]; then
  DEFAULT="$MR_TARGET"
fi
# 推默认/生产分支不检查
case "$BRANCH" in
  master|main|dev|"$DEFAULT")
    exit 0
    ;;
esac

# fetch 默认分支（静默）
git fetch origin "$DEFAULT" --quiet 2>/dev/null

# 远端默认分支没拉到（首次或无网），跳过
git rev-parse "origin/$DEFAULT" >/dev/null 2>&1 || exit 0

# 计算 HEAD 落后 origin/<default> 多少 commit
BEHIND=$(git rev-list --count "HEAD..origin/$DEFAULT" 2>/dev/null)
if [ -z "$BEHIND" ] || [ "$BEHIND" = "0" ]; then
  exit 0
fi

# 落后 → block，给出明确操作步骤
REASON=$(cat <<EOMSG
分支 $BRANCH 落后 origin/$DEFAULT $BEHIND 个提交，push 前必须 rebase。

⚠️ 重要：如果你的命令是 "git commit ... && git push ..."，整条命令都被拦截了，
commit 也没有执行！请拆开单独执行 commit，再处理 rebase。

━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
正确操作顺序（严格按这个来，不要跳步）：
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

1. 如果有未 commit 的改动，先单独 commit（不要和 push 写在一条命令里）：
   git add <你改的文件> && git commit -m "你的 commit message"

2. rebase（只跑一次，不要循环 fetch）：
   git rebase origin/$DEFAULT

3. 如果有冲突：
   手动解决 → git add <冲突文件> → git rebase --continue

4. push（用 --force-with-lease）：
   git push --force-with-lease origin $BRANCH

━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
注意：不要反复 fetch + rebase！master 上随时有人合 MR，
每次 fetch 都会发现新 commit。rebase 一次就够了，
落后 1-2 个 commit 不影响 push。
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
EOMSG
)
printf '{"decision":"block","reason":%s}' "$(printf '%s' "$REASON" | jq -Rs .)"
