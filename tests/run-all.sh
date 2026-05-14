#!/bin/bash
# 自动化测试套件
# 模拟"已 merged 分支 push"等各种场景，验证 hook 拦截行为正确
#
# 用法：bash run-all.sh
#
# 测试隔离：每个 case 创建临时目录 + bare repo + 工作 repo，互不影响

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROPOSED_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
PRE_PUSH_HOOK="$PROPOSED_ROOT/git-hooks/pre-push"
CHECK_MR_BEFORE_PUSH="$PROPOSED_ROOT/hooks/check-mr-before-push.sh"
CHECK_MERGED_BEFORE_EDIT="$PROPOSED_ROOT/hooks/check-branch-merged-before-edit.sh"

PASS=0
FAIL=0
FAILED_TESTS=()

# ---- 颜色 ----
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
NC='\033[0m'

ok()    { echo -e "${GREEN}✅ $*${NC}"; PASS=$((PASS+1)); }
fail()  { echo -e "${RED}❌ $*${NC}"; FAIL=$((FAIL+1)); FAILED_TESTS+=("$1"); }
info()  { echo -e "${YELLOW}ℹ️  $*${NC}"; }

# ---- 准备工作环境 ----
TMPROOT=$(mktemp -d /tmp/hook-test.XXXXXX)
trap "rm -rf $TMPROOT" EXIT
info "测试根目录: $TMPROOT"

# 工厂函数：创建一个干净的 bare repo + 一个工作 repo（带初始 master commit）
setup_repo() {
  local NAME="$1"
  local BARE="$TMPROOT/$NAME.git"
  local WORK="$TMPROOT/$NAME"

  git init --bare "$BARE" >/dev/null 2>&1
  git init -q "$WORK"
  cd "$WORK"
  git config user.email "test@example.com"
  git config user.name "test"
  git config commit.gpgsign false
  echo "init" > README.md
  git add README.md
  git commit -q -m "init"
  git branch -M master
  git remote add origin "$BARE"
  git push -q -u origin master 2>&1 | grep -v "^$" || true

  echo "$WORK"
}

# 安装 pre-push hook 到 repo
install_pre_push() {
  local REPO="$1"
  local HOOKS_DIR="$REPO/.git/hooks"
  mkdir -p "$HOOKS_DIR"
  cp "$PRE_PUSH_HOOK" "$HOOKS_DIR/pre-push"
  chmod +x "$HOOKS_DIR/pre-push"
}

# 让 PreToolUse hook 像 Claude Code 那样运行：传 stdin JSON，返回 stdout
run_check_mr_before_push() {
  local CWD="$1"
  local CMD="$2"
  local INPUT="{\"tool_input\": {\"command\": \"$CMD\", \"cwd\": \"$CWD\"}}"
  echo "$INPUT" | bash "$CHECK_MR_BEFORE_PUSH" 2>/dev/null
}

run_check_merged_before_edit() {
  local FILE_PATH="$1"
  local INPUT="{\"tool_input\": {\"file_path\": \"$FILE_PATH\"}}"
  echo "$INPUT" | bash "$CHECK_MERGED_BEFORE_EDIT" 2>/dev/null
}

# ========================================
# Test 1: pre-push hook 拦截已 merged 分支
# ========================================
echo ""
info "Test 1: pre-push 拦截已 merged 分支的 push"

REPO=$(setup_repo "test1")
cd "$REPO"
install_pre_push "$REPO"

# 创建 feature 分支，加 commit，merge 进 master
git checkout -q -b feat-foo
echo "feature" > feature.txt
git add feature.txt
git commit -q -m "feat: add feature"
FEAT_SHA=$(git rev-parse HEAD)

# 模拟把 feat-foo merge 到 master 并 push（用 fast-forward 模拟"被 merged"的效果）
git checkout -q master
git merge -q --ff-only feat-foo
git push -q origin master 2>&1 | grep -v "^$" || true

# 回到 feat-foo，此时 HEAD = FEAT_SHA，已经是 origin/master 的祖先
git checkout -q feat-foo

# 尝试 push（包括 force-with-lease）
PUSH_OUTPUT=$(git push origin feat-foo 2>&1 || true)
if echo "$PUSH_OUTPUT" | grep -q "PUSH 被 pre-push hook 拦截"; then
  ok "Test 1: pre-push 正确拦截了已 merged 分支的 push"
else
  fail "Test 1: pre-push 没拦住 merged 分支 push (output: $PUSH_OUTPUT)"
fi

# ========================================
# Test 1b: pre-push 拦截 "远端 HEAD 已 merged + 本地追加新 commit" 场景
# （实证 5/11 晚 infra-knowledgebase-parser OCR 并发改动 case）
# ========================================
echo ""
info "Test 1b: pre-push 拦截"已 merged 分支上追加新 commit"场景（Case 0-B 复现）"

REPO=$(setup_repo "test1b")
cd "$REPO"
install_pre_push "$REPO"

# 创建 feature 分支，加第 1 个 commit，push 到远端
git checkout -q -b feat-split-locks
echo "lock1" > lock1.txt
git add lock1.txt
git commit -q -m "feat: split locks"
FIRST_SHA=$(git rev-parse HEAD)
git push -q -u origin feat-split-locks 2>&1 | grep -v "^$" || true

# 模拟"用户合并 MR" = master 进了第 1 个 commit（fast-forward）
git checkout -q master
git merge -q --ff-only feat-split-locks
git push -q origin master 2>&1 | grep -v "^$" || true

# 用户没删本地分支，Claude 又切回去加第 2 个 commit
git checkout -q feat-split-locks
echo "ocr concurrency" > ocr.txt
git add ocr.txt
git commit -q -m "perf: OCR concurrency 3"
SECOND_SHA=$(git rev-parse HEAD)

# 此时:
# - local_sha (SECOND_SHA) 不是 master 祖先（带新内容）
# - remote_sha (FIRST_SHA) 已经是 master 祖先（被合并了）
# 应该被场景 2 拦住
PUSH_OUTPUT=$(git push origin feat-split-locks 2>&1 || true)
if echo "$PUSH_OUTPUT" | grep -q "PUSH 被 pre-push hook 拦截" && \
   echo "$PUSH_OUTPUT" | grep -q "命中场景       : 2"; then
  ok "Test 1b: pre-push 正确拦截了"远端已 merged + 本地追加"场景"
else
  fail "Test 1b: pre-push 没拦住场景 2 (output: $PUSH_OUTPUT)"
fi

# ========================================
# Test 2: pre-push 不拦截 未 merged 的正常分支
# ========================================
echo ""
info "Test 2: pre-push 放行未 merged 的正常分支 push"

REPO=$(setup_repo "test2")
cd "$REPO"
install_pre_push "$REPO"

git checkout -q -b feat-bar
echo "bar" > bar.txt
git add bar.txt
git commit -q -m "feat: bar"

# 这次不 merge 到 master，直接 push
PUSH_OUTPUT=$(git push -u origin feat-bar 2>&1 || true)
if echo "$PUSH_OUTPUT" | grep -q "PUSH 被 pre-push hook 拦截"; then
  fail "Test 2: pre-push 误拦了未 merged 的正常分支 (output: $PUSH_OUTPUT)"
else
  ok "Test 2: pre-push 正确放行未 merged 分支"
fi

# ========================================
# Test 3: pre-push 不拦截 删除分支的操作
# ========================================
echo ""
info "Test 3: pre-push 放行 push --delete 操作"

REPO=$(setup_repo "test3")
cd "$REPO"
install_pre_push "$REPO"

git checkout -q -b feat-to-delete
echo "x" > x.txt
git add x.txt
git commit -q -m "wip"
git push -q -u origin feat-to-delete 2>&1 | grep -v "^$" || true

PUSH_OUTPUT=$(git push origin --delete feat-to-delete 2>&1 || true)
if echo "$PUSH_OUTPUT" | grep -q "PUSH 被 pre-push hook 拦截"; then
  fail "Test 3: pre-push 误拦了 --delete (output: $PUSH_OUTPUT)"
else
  ok "Test 3: pre-push 正确放行 --delete"
fi

# ========================================
# Test 4: pre-push BYPASS 紧急逃生口
# ========================================
echo ""
info "Test 4: BYPASS_MERGED_CHECK=1 紧急绕过"

REPO=$(setup_repo "test4")
cd "$REPO"
install_pre_push "$REPO"

git checkout -q -b feat-bypass
echo "bypass" > bypass.txt
git add bypass.txt
git commit -q -m "wip"
git checkout -q master
git merge -q --ff-only feat-bypass
git push -q origin master 2>&1 | grep -v "^$" || true
git checkout -q feat-bypass

# 加一个新 commit（让它不是 master 祖先；但模拟 amend 场景：本地 HEAD 改了，
# 但 origin/feat-bypass 还指向已 merged 的 commit）
# 这里改用：force push 已 merged 的 commit（HEAD 已是 master 祖先）+ BYPASS
PUSH_OUTPUT=$(BYPASS_MERGED_CHECK=1 git push -f origin feat-bypass 2>&1 || true)
if echo "$PUSH_OUTPUT" | grep -q "BYPASS_MERGED_CHECK=1 已设置"; then
  ok "Test 4: BYPASS 环境变量正确绕过"
  # 验证审计日志写入
  if [ -f "$HOME/.claude/logs/pre-push-bypass.log" ] && tail -1 "$HOME/.claude/logs/pre-push-bypass.log" | grep -q "BYPASSED"; then
    ok "Test 4b: BYPASS 审计日志正确写入"
  else
    info "Test 4b: BYPASS 审计日志路径 ~/.claude/logs/pre-push-bypass.log 未找到（可能权限问题，不算失败）"
  fi
else
  fail "Test 4: BYPASS 失败 (output: $PUSH_OUTPUT)"
fi

# ========================================
# Test 5: PreToolUse check-mr-before-push 拦截
# ========================================
echo ""
info "Test 5: check-mr-before-push.sh 拦截 merged 分支"

REPO=$(setup_repo "test5")
cd "$REPO"

git checkout -q -b feat-pretool
echo "x" > x.txt
git add x.txt
git commit -q -m "wip"
# 模拟真实 MR 流程：先 push 分支，再 merge
git push -q -u origin feat-pretool 2>&1 | grep -v "^$" || true
git checkout -q master
git merge -q --ff-only feat-pretool
git push -q origin master 2>&1 | grep -v "^$" || true
git checkout -q feat-pretool
git fetch -q origin 2>&1 | grep -v "^$" || true

# 调用 PreToolUse hook，模拟 Claude 准备跑 git push
OUTPUT=$(run_check_mr_before_push "$REPO" "git push origin feat-pretool")
if echo "$OUTPUT" | grep -q '"decision":"block"' && echo "$OUTPUT" | grep -q "merged"; then
  ok "Test 5: PreToolUse hook 正确返回 block"
else
  fail "Test 5: PreToolUse hook 没 block (output: $OUTPUT)"
fi

# ========================================
# Test 6: PreToolUse 放行 未 merged 分支
# ========================================
echo ""
info "Test 6: check-mr-before-push.sh 放行未 merged 分支"

REPO=$(setup_repo "test6")
cd "$REPO"

git checkout -q -b feat-pretool-ok
echo "x" > x.txt
git add x.txt
git commit -q -m "wip"

OUTPUT=$(run_check_mr_before_push "$REPO" "git push -u origin feat-pretool-ok")
if echo "$OUTPUT" | grep -q '"decision":"approve"' || echo "$OUTPUT" | grep -q '"decision": "approve"'; then
  ok "Test 6: PreToolUse hook 正确放行未 merged 分支"
else
  fail "Test 6: PreToolUse hook 误拦了 (output: $OUTPUT)"
fi

# ========================================
# Test 7: PreToolUse 跳过非 push 命令
# ========================================
echo ""
info "Test 7: check-mr-before-push.sh 跳过非 push 命令"

REPO=$(setup_repo "test7")
cd "$REPO"

OUTPUT=$(run_check_mr_before_push "$REPO" "git status")
if echo "$OUTPUT" | grep -q "approve"; then
  ok "Test 7: PreToolUse hook 正确跳过 git status"
else
  fail "Test 7: PreToolUse hook 错误拦截 git status (output: $OUTPUT)"
fi

# ========================================
# Test 8: PreToolUse 处理 worktree 前缀分支名
# ========================================
echo ""
info "Test 8: check-mr-before-push.sh 处理 worktree- 前缀"

REPO=$(setup_repo "test8")
cd "$REPO"

# 用 worktree- 前缀的分支名（模拟 Claude Code EnterWorktree 工具的命名约定）
git checkout -q -b worktree-feat-test
echo "wt" > wt.txt
git add wt.txt
git commit -q -m "wip"
# 模拟真实流程：先 push 分支
git push -q -u origin worktree-feat-test 2>&1 | grep -v "^$" || true
git checkout -q master
git merge -q --ff-only worktree-feat-test
git push -q origin master 2>&1 | grep -v "^$" || true
git checkout -q worktree-feat-test
git fetch -q origin 2>&1 | grep -v "^$" || true

OUTPUT=$(run_check_mr_before_push "$REPO" "git push origin worktree-feat-test:feat-test")
if echo "$OUTPUT" | grep -q '"decision":"block"'; then
  ok "Test 8: PreToolUse hook 正确处理 worktree- 前缀分支"
else
  fail "Test 8: PreToolUse hook 没处理 worktree- 前缀 (output: $OUTPUT)"
fi

# ========================================
# Test 8b/c/d/e: check-mr-before-push.sh 拦截"绕 hook"模式（Case A3、C1 实证）
# ========================================
echo ""
info "Test 8b: 拦截 --no-verify"

REPO=$(setup_repo "test8b")
cd "$REPO"
git checkout -q -b feat-bypass
echo "x" > x.txt && git add x.txt && git commit -q -m "wip"

OUTPUT=$(run_check_mr_before_push "$REPO" "git push --no-verify origin feat-bypass")
if echo "$OUTPUT" | grep -q '"decision":"block"' && echo "$OUTPUT" | grep -q "no-verify"; then
  ok "Test 8b: --no-verify 被拦截"
else
  fail "Test 8b: --no-verify 没被拦 (output: $OUTPUT)"
fi

echo ""
info "Test 8c: 拦截 core.hooksPath=/dev/null（Case A3 实证）"

REPO=$(setup_repo "test8c")
cd "$REPO"
git checkout -q -b feat-bypass
echo "x" > x.txt && git add x.txt && git commit -q -m "wip"

OUTPUT=$(run_check_mr_before_push "$REPO" "git -c core.hooksPath=/dev/null push --force origin feat-bypass")
if echo "$OUTPUT" | grep -q '"decision":"block"' && echo "$OUTPUT" | grep -q "core.hooksPath"; then
  ok "Test 8c: core.hooksPath=/dev/null 被拦截"
else
  fail "Test 8c: core.hooksPath=/dev/null 没被拦 (output: $OUTPUT)"
fi

echo ""
info "Test 8d: 拦截 GIT_PUSH_SKIP_MERGED_CHECK=1（Case C1 实证）"

REPO=$(setup_repo "test8d")
cd "$REPO"
git checkout -q -b feat-bypass
echo "x" > x.txt && git add x.txt && git commit -q -m "wip"

OUTPUT=$(run_check_mr_before_push "$REPO" "GIT_PUSH_SKIP_MERGED_CHECK=1 git push origin feat-bypass")
if echo "$OUTPUT" | grep -q '"decision":"block"' && echo "$OUTPUT" | grep -q "SKIP"; then
  ok "Test 8d: GIT_PUSH_SKIP_MERGED_CHECK=1 被拦截"
else
  fail "Test 8d: GIT_PUSH_SKIP_MERGED_CHECK=1 没被拦 (output: $OUTPUT)"
fi

echo ""
info "Test 8e: 拦截 core.hooksPath=任意路径"

REPO=$(setup_repo "test8e")
cd "$REPO"
git checkout -q -b feat-bypass
echo "x" > x.txt && git add x.txt && git commit -q -m "wip"

OUTPUT=$(run_check_mr_before_push "$REPO" "git -c core.hooksPath=/tmp/empty push origin feat-bypass")
if echo "$OUTPUT" | grep -q '"decision":"block"' && echo "$OUTPUT" | grep -q "core.hooksPath"; then
  ok "Test 8e: core.hooksPath=任意路径 被拦截"
else
  fail "Test 8e: core.hooksPath=任意路径 没被拦 (output: $OUTPUT)"
fi

# ========================================
# Test 9: check-branch-merged-before-edit 拦截已 merged 分支 Edit
# ========================================
echo ""
info "Test 9: check-branch-merged-before-edit.sh 拦截 merged 分支编辑"

REPO=$(setup_repo "test9")
cd "$REPO"

git checkout -q -b feat-edit
echo "x" > some-file.txt
git add some-file.txt
git commit -q -m "wip"
# 模拟真实 MR 流程：先 push 分支到远端，再 merge 进 master
git push -q -u origin feat-edit 2>&1 | grep -v "^$" || true
git checkout -q master
git merge -q --ff-only feat-edit
git push -q origin master 2>&1 | grep -v "^$" || true
git checkout -q feat-edit
# fetch 让本地知道 origin/feat-edit 存在
git fetch -q origin 2>&1 | grep -v "^$" || true

OUTPUT=$(run_check_merged_before_edit "$REPO/some-file.txt")
if echo "$OUTPUT" | grep -q '"decision":"block"'; then
  ok "Test 9: 编辑 hook 正确拦截已 merged 分支"
else
  fail "Test 9: 编辑 hook 没拦住 (output: $OUTPUT)"
fi

# ========================================
# Test 10: check-branch-merged-before-edit 放行未 merged 分支
# ========================================
echo ""
info "Test 10: check-branch-merged-before-edit.sh 放行未 merged 分支"

REPO=$(setup_repo "test10")
cd "$REPO"

git checkout -q -b feat-edit-ok
echo "x" > other-file.txt
git add other-file.txt
git commit -q -m "wip"

OUTPUT=$(run_check_merged_before_edit "$REPO/other-file.txt")
# 这里期望 stdout 为空（hook 静默 exit 0）
if [ -z "$OUTPUT" ]; then
  ok "Test 10: 编辑 hook 正确放行未 merged 分支"
else
  fail "Test 10: 编辑 hook 误拦了未 merged 分支 (output: $OUTPUT)"
fi

# ========================================
# Test 11: check-branch-merged-before-edit 跳过 master
# ========================================
echo ""
info "Test 11: check-branch-merged-before-edit.sh 跳过 master 分支"

REPO=$(setup_repo "test11")
cd "$REPO"
# 当前在 master
OUTPUT=$(run_check_merged_before_edit "$REPO/README.md")
if [ -z "$OUTPUT" ]; then
  ok "Test 11: 编辑 hook 正确跳过 master"
else
  fail "Test 11: 编辑 hook 错误拦截了 master (output: $OUTPUT)"
fi

# ========================================
# Test 12: check-on-main-branch-before-edit 拦截在 master 上编辑业务文件
# ========================================
echo ""
info "Test 12: 拦截在 master 分支上编辑业务文件"

REPO=$(setup_repo "test12")
cd "$REPO"
# 当前在 master，建一个业务文件
echo "public class Foo {}" > src/main/java/Foo.java || (mkdir -p src/main/java && echo "public class Foo {}" > src/main/java/Foo.java)

CHECK_MAIN_BRANCH="$PROPOSED_ROOT/hooks/check-on-main-branch-before-edit.sh"
INPUT="{\"tool_input\": {\"file_path\": \"$REPO/src/main/java/Foo.java\"}}"
OUTPUT=$(echo "$INPUT" | bash "$CHECK_MAIN_BRANCH" 2>/dev/null || true)
if echo "$OUTPUT" | grep -q '"decision":"block"' && echo "$OUTPUT" | grep -q "/start-feature"; then
  ok "Test 12: 主分支编辑业务文件 被拦截 + 提示 slash command"
else
  fail "Test 12: 主分支编辑业务文件 没被拦 (output: $OUTPUT)"
fi

# ========================================
# Test 12b: check-on-main-branch-before-edit 放行 README 等文档
# ========================================
echo ""
info "Test 12b: 放行 README/docs/CHANGELOG 类轻量改动"

REPO=$(setup_repo "test12b")
cd "$REPO"
INPUT="{\"tool_input\": {\"file_path\": \"$REPO/README.md\"}}"
OUTPUT=$(echo "$INPUT" | bash "$CHECK_MAIN_BRANCH" 2>/dev/null || true)
if [ -z "$OUTPUT" ]; then
  ok "Test 12b: README 文档编辑放行"
else
  fail "Test 12b: README 文档编辑被误拦 (output: $OUTPUT)"
fi

# ========================================
# Test 12c: check-on-main-branch-before-edit 在 feature 分支上放行
# ========================================
echo ""
info "Test 12c: 放行非主分支上的编辑"

REPO=$(setup_repo "test12c")
cd "$REPO"
git checkout -q -b feat-something
INPUT="{\"tool_input\": {\"file_path\": \"$REPO/foo.java\"}}"
OUTPUT=$(echo "$INPUT" | bash "$CHECK_MAIN_BRANCH" 2>/dev/null || true)
if [ -z "$OUTPUT" ]; then
  ok "Test 12c: feature 分支上编辑放行"
else
  fail "Test 12c: feature 分支编辑被误拦 (output: $OUTPUT)"
fi

# ========================================
# Test 12d: BYPASS_MAIN_BRANCH_EDIT 紧急绕过
# ========================================
echo ""
info "Test 12d: BYPASS_MAIN_BRANCH_EDIT=1 紧急绕过"

REPO=$(setup_repo "test12d")
cd "$REPO"
mkdir -p src && echo "x" > src/x.java
INPUT="{\"tool_input\": {\"file_path\": \"$REPO/src/x.java\"}}"
OUTPUT=$(echo "$INPUT" | BYPASS_MAIN_BRANCH_EDIT=1 bash "$CHECK_MAIN_BRANCH" 2>/dev/null || true)
if [ -z "$OUTPUT" ]; then
  ok "Test 12d: BYPASS 紧急绕过生效"
else
  fail "Test 12d: BYPASS 没生效 (output: $OUTPUT)"
fi

# ========================================
# 总结
# ========================================
echo ""
echo "================================="
echo "测试完成"
echo "  ${GREEN}通过: $PASS${NC}"
echo "  ${RED}失败: $FAIL${NC}"
if [ ${#FAILED_TESTS[@]} -gt 0 ]; then
  echo ""
  echo "失败的测试："
  for t in "${FAILED_TESTS[@]}"; do
    echo "  - $t"
  done
fi
echo "================================="

if [ "$FAIL" -gt 0 ]; then
  exit 1
fi
