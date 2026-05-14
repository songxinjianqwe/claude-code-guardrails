#!/bin/bash
# PostToolUse hook: push 完成后检查实际 push 的远程分支 MR 是否已 merged
# 如果已 merged 说明 push 的 commit 不会进 master，需要新开分支

INPUT=$(cat)
COMMAND=$(echo "$INPUT" | jq -r '.tool_input.command // ""')
COMMAND_FLAT=$(printf '%s' "$COMMAND" | tr '\n\r' '  ')

# 只处理 git push（分段匹配，避免 commit message / heredoc 里的 "git push" 文本误触发）
IS_GIT_PUSH=0
while IFS= read -r segment; do
  segment=$(echo "$segment" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
  [ -z "$segment" ] && continue
  if echo "$segment" | grep -qE '^git[[:space:]]+(commit|add|log|diff|show|tag|stash|rebase|merge|cherry-pick|revert)'; then
    continue
  fi
  if echo "$segment" | grep -qE '^git[[:space:]]+([^|;&]*[[:space:]]+)?push([[:space:]]|$)'; then
    IS_GIT_PUSH=1
    break
  fi
  if echo "$segment" | grep -qE 'git[[:space:]]+([^|;&]*[[:space:]]+)?push([[:space:]]|$)' && \
     ! echo "$segment" | grep -qE 'git[[:space:]]+(commit|add|log|diff|show|tag)'; then
    IS_GIT_PUSH=1
    break
  fi
done <<< "$(echo "$COMMAND_FLAT" | tr ';&|' '\n')"

if [ "$IS_GIT_PUSH" = "0" ]; then
  exit 0
fi

# 从命令中提取 cd 目标目录
REPO_DIR=""
if [[ "$COMMAND_FLAT" == *"cd "*"git push"* ]]; then
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
if [ -n "$REPO_DIR" ] && [ -d "$REPO_DIR" ]; then
  cd "$REPO_DIR" || true
fi

# 提取实际 push 的远程分支名
BRANCH=""
# 1. HEAD:remote-branch refspec
REFSPEC=$(echo "$COMMAND_FLAT" | grep -oE '[a-zA-Z0-9._/-]+:[a-zA-Z0-9._/-]+' | head -1)
if [ -n "$REFSPEC" ]; then
  BRANCH="${REFSPEC##*:}"
fi
# 2. `git push origin <branch>` 或 `git push -u origin <branch>`
if [ -z "$BRANCH" ]; then
  # 提取 origin 后面的非 flag 参数
  AFTER_ORIGIN=$(echo "$COMMAND_FLAT" | sed -E 's/.*origin[[:space:]]*//' | sed 's/[[:space:]]*2>.*//')
  for word in $AFTER_ORIGIN; do
    if [[ "$word" != -* ]]; then
      BRANCH="$word"
      break
    fi
  done
fi
# 3. fallback 到当前分支（去掉 worktree- 前缀）
if [ -z "$BRANCH" ]; then
  BRANCH=$(git branch --show-current 2>/dev/null)
  BRANCH="${BRANCH#worktree-}"
fi

if [ -z "$BRANCH" ] || [ "$BRANCH" = "master" ] || [ "$BRANCH" = "main" ] || [ "$BRANCH" = "dev" ]; then
  exit 0
fi

MR_STATE=$(glab mr list --source-branch="$BRANCH" --merged 2>/dev/null | head -5)
if echo "$MR_STATE" | grep -q "!"; then
  MR_NUM=$(echo "$MR_STATE" | grep -oE '![0-9]+' | head -1)
  # 找出刚才 push 了哪些 commit（远端分支领先 master 的部分）
  LOST_COMMITS=$(git log --oneline "origin/master..origin/$BRANCH" 2>/dev/null | head -5)
  cat <<EOJSON
{"hookSpecificOutput":{"hookEventName":"PostToolUse","additionalContext":"🚨🚨🚨 CRITICAL ERROR 🚨🚨🚨\n\n你刚才 push 到了已 merged 的分支 $BRANCH（MR $MR_NUM）！\n这些 commit 不会进入 master，已经丢失：\n$LOST_COMMITS\n\n你必须立即执行：\n1. git checkout master && git pull\n2. git checkout -b <新分支名>\n3. git cherry-pick <丢失的commit hash>\n4. git push -u origin <新分支名>\n5. glab mr create --target-branch master\n\n不要继续其他操作，先修复这个问题！"}}
EOJSON
fi
