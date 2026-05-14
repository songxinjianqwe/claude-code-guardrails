#!/bin/bash
# 卸载所有改动
# 自动从最近一次安装备份恢复

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CLAUDE_DIR="$HOME/.claude"
HOOKS_DIR="$CLAUDE_DIR/hooks"
SETTINGS="$CLAUDE_DIR/settings.json"
TEMPLATE_DIR="$CLAUDE_DIR/git-hooks-template"

GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[0;33m'
NC='\033[0m'

ok()   { echo -e "${GREEN}✅ $*${NC}"; }
fail() { echo -e "${RED}❌ $*${NC}" >&2; }
info() { echo -e "${YELLOW}ℹ️  $*${NC}"; }

# ---- 找最近的备份 ----
BACKUP_BASE="$CLAUDE_DIR/backups"
LATEST_BACKUP=$(ls -1d "$BACKUP_BASE"/guardrails-* "$BACKUP_BASE"/proposed-changes-* 2>/dev/null | sort | tail -1)

if [ -z "$LATEST_BACKUP" ] || [ ! -d "$LATEST_BACKUP" ]; then
  fail "找不到 guardrails-* 备份"
  echo ""
  echo "如果你确定要手动卸载，执行以下命令："
  echo "  rm $HOOKS_DIR/check-mr-before-push.sh"
  echo "  rm $HOOKS_DIR/check-branch-merged-before-edit.sh"
  echo "  git config --global --unset core.hooksPath"
  echo "  rm -rf $TEMPLATE_DIR"
  echo "  # 手动从你之前的备份恢复 settings.json"
  exit 1
fi

info "使用备份: $LATEST_BACKUP"

# ---- 确认 ----
read -r -p "确认从 $LATEST_BACKUP 恢复？(y/N) " ANS
if [ "$ANS" != "y" ] && [ "$ANS" != "Y" ]; then
  echo "已取消"
  exit 0
fi

# ---- 恢复 hooks/ ----
if [ -d "$LATEST_BACKUP/hooks" ]; then
  rm -rf "$HOOKS_DIR"
  cp -R "$LATEST_BACKUP/hooks" "$HOOKS_DIR"
  ok "恢复 $HOOKS_DIR"
else
  info "备份中没有 hooks/ 目录，跳过"
fi

# ---- 恢复 settings.json ----
if [ -f "$LATEST_BACKUP/settings.json" ]; then
  cp "$LATEST_BACKUP/settings.json" "$SETTINGS"
  ok "恢复 $SETTINGS"
fi

# ---- 恢复 core.hooksPath ----
if [ -f "$LATEST_BACKUP/core.hooksPath.txt" ]; then
  PREV=$(cat "$LATEST_BACKUP/core.hooksPath.txt")
  if [ -n "$PREV" ]; then
    git config --global core.hooksPath "$PREV"
    ok "恢复 core.hooksPath = $PREV"
  else
    git config --global --unset core.hooksPath 2>/dev/null || true
    ok "清除 core.hooksPath（备份显示原本没设置）"
  fi
fi

# ---- 清理 template 目录 ----
if [ -d "$TEMPLATE_DIR" ]; then
  rm -rf "$TEMPLATE_DIR"
  ok "清理 $TEMPLATE_DIR"
fi

# ---- 清理 bypass log ----
if [ -f "$CLAUDE_DIR/logs/pre-push-bypass.log" ]; then
  info "保留 bypass 审计日志: $CLAUDE_DIR/logs/pre-push-bypass.log"
fi

echo ""
ok "🎉 卸载完成，已回到安装前状态"
echo ""
info "备份保留在 $LATEST_BACKUP（可手动删除）"
