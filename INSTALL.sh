#!/bin/bash
# claude-code-guardrails 安装脚本
#
# 用法：
#   cd <本项目目录>
#   bash INSTALL.sh
#
# 会自动备份、安装、验证。失败自动回滚。

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CLAUDE_DIR="$HOME/.claude"
HOOKS_DIR="$CLAUDE_DIR/hooks"
SETTINGS="$CLAUDE_DIR/settings.json"

# ---- 颜色 ----
GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[0;33m'
NC='\033[0m'

ok()    { echo -e "${GREEN}✅ $*${NC}"; }
fail()  { echo -e "${RED}❌ $*${NC}" >&2; }
info()  { echo -e "${YELLOW}ℹ️  $*${NC}"; }

# ---- 前置检查 ----
if [ ! -d "$CLAUDE_DIR" ]; then
  fail "找不到 $CLAUDE_DIR，请确认 Claude Code 已安装"
  exit 1
fi

if [ ! -f "$SETTINGS" ]; then
  fail "找不到 $SETTINGS"
  exit 1
fi

if ! command -v jq >/dev/null 2>&1; then
  fail "需要 jq 命令，请先安装：brew install jq"
  exit 1
fi

mkdir -p "$HOOKS_DIR"

# ---- 备份 ----
BACKUP="$CLAUDE_DIR/backups/guardrails-$(date '+%Y%m%d-%H%M%S')"
mkdir -p "$BACKUP"
cp -R "$HOOKS_DIR" "$BACKUP/hooks" 2>/dev/null || true
cp "$SETTINGS" "$BACKUP/settings.json"

EXISTING_HOOKS_PATH=$(git config --global --get core.hooksPath 2>/dev/null || echo "")
echo "$EXISTING_HOOKS_PATH" > "$BACKUP/core.hooksPath.txt"

ok "已备份到 $BACKUP"

# 中断时回滚
ROLLBACK_DONE=0
rollback() {
  if [ "$ROLLBACK_DONE" = "1" ]; then return; fi
  ROLLBACK_DONE=1
  fail "安装中断，回滚..."
  rm -rf "$HOOKS_DIR"
  cp -R "$BACKUP/hooks" "$HOOKS_DIR" 2>/dev/null || mkdir -p "$HOOKS_DIR"
  cp "$BACKUP/settings.json" "$SETTINGS"
  if [ -n "$EXISTING_HOOKS_PATH" ]; then
    git config --global core.hooksPath "$EXISTING_HOOKS_PATH"
  else
    git config --global --unset core.hooksPath 2>/dev/null || true
  fi
  info "回滚完成。备份保留在 $BACKUP"
  exit 1
}
trap rollback INT TERM ERR

# ---- 1. 复制 PreToolUse hook 脚本 ----
info "1/5 复制 PreToolUse hook 脚本"
cp "$SCRIPT_DIR/hooks/check-mr-before-push.sh" "$HOOKS_DIR/"
cp "$SCRIPT_DIR/hooks/check-branch-merged-before-edit.sh" "$HOOKS_DIR/"
cp "$SCRIPT_DIR/hooks/check-on-main-branch-before-edit.sh" "$HOOKS_DIR/"
chmod +x "$HOOKS_DIR/check-mr-before-push.sh"
chmod +x "$HOOKS_DIR/check-branch-merged-before-edit.sh"
chmod +x "$HOOKS_DIR/check-on-main-branch-before-edit.sh"
ok "PreToolUse hook 已就位"

# ---- 1b. 复制 slash commands ----
info "1b/5 安装 slash commands"
COMMANDS_DIR="$CLAUDE_DIR/commands"
mkdir -p "$COMMANDS_DIR"
for f in "$SCRIPT_DIR"/commands/*.md; do
  [ -f "$f" ] && cp "$f" "$COMMANDS_DIR/"
done
ok "slash commands 已安装"

# ---- 2. 安装 git pre-push hook（全局模式）----
info "2/5 安装 git pre-push hook（全局模式）"

TEMPLATE_DIR="$CLAUDE_DIR/git-hooks-template"
mkdir -p "$TEMPLATE_DIR"
cp "$SCRIPT_DIR/git-hooks/pre-push" "$TEMPLATE_DIR/pre-push-merged-check"
chmod +x "$TEMPLATE_DIR/pre-push-merged-check"

# dispatcher（兼容项目本地 husky / pre-push.local）
cat > "$TEMPLATE_DIR/pre-push" <<'DISPATCHER'
#!/bin/bash
set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CORE_HOOK="$SCRIPT_DIR/pre-push-merged-check"

STDIN_DATA=$(cat)

if [ -x "$CORE_HOOK" ]; then
  echo "$STDIN_DATA" | "$CORE_HOOK" "$@"
fi

GIT_DIR=$(git rev-parse --git-common-dir 2>/dev/null)
if [ -n "$GIT_DIR" ] && [ -x "$GIT_DIR/hooks/pre-push.local" ]; then
  echo "$STDIN_DATA" | "$GIT_DIR/hooks/pre-push.local" "$@"
fi

TOPLEVEL=$(git rev-parse --show-toplevel 2>/dev/null)
if [ -n "$TOPLEVEL" ] && [ -f "$TOPLEVEL/.husky/pre-push" ]; then
  echo "$STDIN_DATA" | "$TOPLEVEL/.husky/pre-push" "$@"
fi

exit 0
DISPATCHER
chmod +x "$TEMPLATE_DIR/pre-push"

if [ -n "$EXISTING_HOOKS_PATH" ] && [ "$EXISTING_HOOKS_PATH" != "$TEMPLATE_DIR" ]; then
  info "  检测到现有 core.hooksPath=$EXISTING_HOOKS_PATH，覆盖（原值已备份）"
fi
git config --global core.hooksPath "$TEMPLATE_DIR"
ok "git pre-push hook 已全局安装"

# ---- 2b. 清理 repo-local core.hooksPath（会覆盖全局设置导致 L1 失效）----
info "2b/5 扫描 ~/dev/java/ 下的 repo，清理 local core.hooksPath"
CLEANED=0
for repo in "$HOME"/dev/java/*/; do
  if [ -d "$repo/.git" ]; then
    local_hp=$(git -C "$repo" config --local --get core.hooksPath 2>/dev/null)
    if [ -n "$local_hp" ] && [ "$local_hp" != "$TEMPLATE_DIR" ]; then
      git -C "$repo" config --local --unset core.hooksPath
      CLEANED=$((CLEANED+1))
    fi
  fi
done
if [ "$CLEANED" -gt 0 ]; then
  ok "清理了 $CLEANED 个 repo 的 local core.hooksPath"
else
  ok "没有 repo 有冲突的 local core.hooksPath"
fi

# ---- 3. patch settings.json ----
info "3/5 patch settings.json"

# 动态生成 hook command 路径
HOOK_CMD_MERGED="$HOOKS_DIR/check-branch-merged-before-edit.sh"
HOOK_CMD_MAIN="$HOOKS_DIR/check-on-main-branch-before-edit.sh"

HOOKS_TO_REGISTER=$(jq -n --arg h1 "$HOOK_CMD_MERGED" --arg h2 "$HOOK_CMD_MAIN" '[
  {"command": $h1, "statusMessage": "Checking branch merged status...", "timeout": 10, "type": "command"},
  {"command": $h2, "statusMessage": "Checking main branch...", "timeout": 5, "type": "command"}
]')

NEW_SETTINGS=$(jq --argjson new_hooks "$HOOKS_TO_REGISTER" '
  .hooks.PreToolUse = (.hooks.PreToolUse // []) |
  (.hooks.PreToolUse |= (
    if any(.[]; .matcher == "Edit|Write") then
      map(
        if .matcher == "Edit|Write" then
          .hooks = (
            (.hooks // []) as $existing
            | reduce $new_hooks[] as $nh ($existing;
                if any(.[]; (.command? // "") == $nh.command) then . else . + [$nh] end
              )
          )
        else . end
      )
    else
      . + [{
        "matcher": "Edit|Write",
        "hooks": $new_hooks
      }]
    end
  ))
' "$SETTINGS")

if echo "$NEW_SETTINGS" | jq empty 2>/dev/null; then
  echo "$NEW_SETTINGS" > "$SETTINGS"
  ok "settings.json 已 patch"
else
  fail "patch 后 JSON 不合法"
  exit 1
fi

# ---- 4. 跑测试 ----
info "4/5 跑测试验证"
if bash "$SCRIPT_DIR/tests/run-all.sh" >/tmp/guardrails-test.log 2>&1; then
  ok "所有测试通过"
else
  fail "测试失败，详见 /tmp/guardrails-test.log"
  tail -20 /tmp/guardrails-test.log
  exit 1
fi

# ---- 5. 自检 ----
info "5/5 自检"
CHECKS_FAILED=0

for f in check-mr-before-push.sh check-branch-merged-before-edit.sh check-on-main-branch-before-edit.sh; do
  if [ -x "$HOOKS_DIR/$f" ]; then
    ok "  $HOOKS_DIR/$f"
  else
    fail "  $HOOKS_DIR/$f 不存在或不可执行"
    CHECKS_FAILED=$((CHECKS_FAILED+1))
  fi
done

ACTUAL_HOOKS_PATH=$(git config --global --get core.hooksPath)
if [ "$ACTUAL_HOOKS_PATH" = "$TEMPLATE_DIR" ]; then
  ok "  core.hooksPath = $TEMPLATE_DIR"
else
  fail "  core.hooksPath 设置异常"
  CHECKS_FAILED=$((CHECKS_FAILED+1))
fi

if [ -x "$TEMPLATE_DIR/pre-push" ] && [ -x "$TEMPLATE_DIR/pre-push-merged-check" ]; then
  ok "  pre-push template 文件就位"
else
  fail "  pre-push template 文件缺失"
  CHECKS_FAILED=$((CHECKS_FAILED+1))
fi

if [ "$CHECKS_FAILED" -gt 0 ]; then
  fail "自检发现 $CHECKS_FAILED 项问题"
  exit 1
fi

trap - INT TERM ERR

echo ""
echo "================================="
ok "安装完成"
echo ""
info "三层防御："
echo "  L1: $TEMPLATE_DIR/pre-push（物理防线，所有 git push 都拦）"
echo "  L2: $HOOKS_DIR/check-mr-before-push.sh（Claude push 前反馈）"
echo "  L3: $HOOKS_DIR/check-branch-merged-before-edit.sh（编辑前预防）"
echo "  L3: $HOOKS_DIR/check-on-main-branch-before-edit.sh（主分支编辑拦截）"
echo ""
info "回滚：bash $SCRIPT_DIR/UNINSTALL.sh"
info "绕过：BYPASS_MERGED_CHECK=1 git push ..."
echo ""
echo "备份在: $BACKUP"
echo "================================="
