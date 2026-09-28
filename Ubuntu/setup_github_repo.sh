#!/usr/bin/env bash
set -Eeuo pipefail

# ============================================================
# 将本地目录初始化/同步到 GitHub 仓库
#
# 注意：
#   1. 脚本会执行 git add -A 并提交本地改动；请先配置好 .gitignore。
#   2. repo_url 使用 SSH 时，请先确保当前机器已配置 GitHub SSH Key。
#   3. 远程已有内容时会先拉取并合并；发生冲突会停止，不会 force push。
#   4. 当前仓库已有 origin 且地址不同时，会改为传入的 repo_url。
#   5. user.name / user.email 只写入当前仓库，不修改全局 Git 配置。
#   6. 本地和远程都为空时，会创建一个空的 Initial commit。
#
# 用法：
#   setup_github_repo.sh <user.name> <user.email> <repo_url> [work_dir]
#
# 参数：
#   user.name   Git 提交用户名
#   user.email  Git 提交邮箱
#   repo_url    GitHub 仓库地址，支持 SSH / HTTPS
#   work_dir    本地仓库目录，默认当前目录 .
#
# 示例：
#   ./setup_github_repo.sh \
#     "lgs2513" \
#     "your_email@example.com" \
#     "git@github.com:lgs2513/tool_scripts.git" \
#     "$HOME/tool_scripts"
# ============================================================

usage() {
  cat <<'USAGE'
Usage:
  setup_github_repo.sh <user.name> <user.email> <repo_url> [work_dir]

Example:
  setup_github_repo.sh \
    "lgs2513" \
    "your_email@example.com" \
    "git@github.com:lgs2513/tool_scripts.git" \
    "$HOME/tool_scripts"
USAGE
}

log() {
  printf '==> %s\n' "$*"
}

die() {
  printf 'ERROR: %s\n' "$*" >&2
  exit 1
}

[[ $# -ge 3 && $# -le 4 ]] || {
  usage >&2
  exit 64
}

USER_NAME=$1
USER_EMAIL=$2
REPO_URL=$3
WORK_DIR=${4:-.}

[[ -n "$USER_NAME" ]] || die "user.name 不能为空"
[[ -n "$USER_EMAIL" ]] || die "user.email 不能为空"
[[ -n "$REPO_URL" ]] || die "repo_url 不能为空"

command -v git >/dev/null 2>&1 || die "未找到 git"

# 兼容将 ~ 作为普通参数传入的情况。
case "$WORK_DIR" in
  "~")
    WORK_DIR=$HOME
    ;;
  "~/"*)
    WORK_DIR="$HOME/${WORK_DIR#\~/}"
    ;;
esac

mkdir -p "$WORK_DIR"
WORK_DIR=$(cd "$WORK_DIR" && pwd -P)

log "work_dir: $WORK_DIR"
log "repo_url: $REPO_URL"

# 检查本地仓库状态。
LOCAL_REPO=false
LOCAL_BRANCH=""

if git -C "$WORK_DIR" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  TOPLEVEL=$(git -C "$WORK_DIR" rev-parse --show-toplevel)
  [[ "$TOPLEVEL" == "$WORK_DIR" ]] || \
    die "$WORK_DIR 位于另一个 Git 仓库中：$TOPLEVEL"

  LOCAL_REPO=true
  LOCAL_BRANCH=$(git -C "$WORK_DIR" symbolic-ref --quiet --short HEAD 2>/dev/null || true)
fi

# 检查远程仓库，并确定远程默认分支。
log "检查远程仓库"
REMOTE_REFS=$(git ls-remote "$REPO_URL") || \
  die "无法访问远程仓库，请检查仓库地址和认证信息"

REMOTE_HEAD_INFO=$(git ls-remote --symref "$REPO_URL" HEAD 2>/dev/null || true)

REMOTE_BRANCH=$(
  printf '%s\n' "$REMOTE_HEAD_INFO" |
    awk '$1 == "ref:" && $2 ~ /^refs\/heads\// && $3 == "HEAD" {
      sub(/^refs\/heads\//, "", $2)
      print $2
      exit
    }'
)

REMOTE_HAS_BRANCH=false
if printf '%s\n' "$REMOTE_REFS" | grep -q $'\trefs/heads/'; then
  REMOTE_HAS_BRANCH=true
fi

if [[ "$REMOTE_HAS_BRANCH" == true && -z "$REMOTE_BRANCH" ]]; then
  if printf '%s\n' "$REMOTE_REFS" | grep -q $'\trefs/heads/main$'; then
    REMOTE_BRANCH=main
  elif printf '%s\n' "$REMOTE_REFS" | grep -q $'\trefs/heads/master$'; then
    REMOTE_BRANCH=master
  else
    REMOTE_BRANCH=$(
      printf '%s\n' "$REMOTE_REFS" |
        awk '$2 ~ /^refs\/heads\// {
          sub(/^refs\/heads\//, "", $2)
          print $2
          exit
        }'
    )
  fi
fi

if [[ "$REMOTE_HAS_BRANCH" == true ]]; then
  TARGET_BRANCH=$REMOTE_BRANCH
elif [[ "$LOCAL_REPO" == true && -n "$LOCAL_BRANCH" ]]; then
  TARGET_BRANCH=$LOCAL_BRANCH
else
  TARGET_BRANCH=main
fi

log "目标分支: $TARGET_BRANCH"

# 初始化仓库。
if [[ "$LOCAL_REPO" == false ]]; then
  log "初始化本地仓库"

  if ! git -C "$WORK_DIR" init -q -b "$TARGET_BRANCH" 2>/dev/null; then
    git -C "$WORK_DIR" init -q
    git -C "$WORK_DIR" symbolic-ref HEAD "refs/heads/$TARGET_BRANCH"
  fi
fi

cd "$WORK_DIR"

# 未完成的 merge/rebase 不继续处理。
for marker in MERGE_HEAD CHERRY_PICK_HEAD REVERT_HEAD; do
  marker_path=$(git rev-parse --git-path "$marker")
  [[ ! -e "$marker_path" ]] || \
    die "检测到未完成的 Git 操作：$marker，请先处理"
done

rebase_merge=$(git rev-parse --git-path rebase-merge)
rebase_apply=$(git rev-parse --git-path rebase-apply)
[[ ! -d "$rebase_merge" && ! -d "$rebase_apply" ]] || \
  die "检测到未完成的 rebase，请先处理"

# 仅配置当前仓库的 Git 用户信息。
git config --local user.name "$USER_NAME"
git config --local user.email "$USER_EMAIL"

# 配置 origin。
if git remote get-url origin >/dev/null 2>&1; then
  OLD_ORIGIN=$(git remote get-url origin)

  if [[ "$OLD_ORIGIN" != "$REPO_URL" ]]; then
    log "更新 origin: $OLD_ORIGIN -> $REPO_URL"
    git remote set-url origin "$REPO_URL"
  fi
else
  git remote add origin "$REPO_URL"
fi

# 先保存当前本地内容，避免切换分支时丢失未提交改动。
log "检查本地改动"
git add -A

if ! git diff --cached --quiet; then
  git commit -m "chore: snapshot local worktree before GitHub sync"
fi

LOCAL_HEAD=""
if git rev-parse --verify HEAD >/dev/null 2>&1; then
  LOCAL_HEAD=$(git rev-parse HEAD)
fi

# 拉取远程分支。
if [[ "$REMOTE_HAS_BRANCH" == true ]]; then
  log "拉取远程内容"
  git fetch --prune origin '+refs/heads/*:refs/remotes/origin/*'

  git show-ref --verify --quiet "refs/remotes/origin/$TARGET_BRANCH" || \
    die "未能获取 origin/$TARGET_BRANCH"
fi

# 切换到目标分支。
if git show-ref --verify --quiet "refs/heads/$TARGET_BRANCH"; then
  git checkout --no-overwrite-ignore "$TARGET_BRANCH"
elif [[ -n "$LOCAL_HEAD" ]]; then
  git checkout --no-overwrite-ignore -b "$TARGET_BRANCH" "$LOCAL_HEAD"
elif [[ "$REMOTE_HAS_BRANCH" == true ]]; then
  git checkout --no-overwrite-ignore \
    -b "$TARGET_BRANCH" \
    --track "origin/$TARGET_BRANCH"
else
  git symbolic-ref HEAD "refs/heads/$TARGET_BRANCH"
fi

merge_or_stop() {
  local source=$1
  local label=$2

  if git merge-base --is-ancestor "$source" HEAD >/dev/null 2>&1; then
    return 0
  fi

  log "合并 $label"

  if ! git merge \
      --allow-unrelated-histories \
      --no-edit \
      --no-overwrite-ignore \
      "$source"; then
    cat >&2 <<EOF

合并发生冲突，脚本已停止，没有执行 force push。

处理方式：
  cd "$WORK_DIR"
  git status

解决冲突后：
  git add -A
  git commit
  git push -u origin "$TARGET_BRANCH"

放弃本次合并：
  git merge --abort
EOF
    exit 2
  fi
}

# 保留原本地历史。
if [[ -n "$LOCAL_HEAD" ]]; then
  merge_or_stop "$LOCAL_HEAD" "本地历史"
fi

# 合并远程历史。
if [[ "$REMOTE_HAS_BRANCH" == true ]]; then
  merge_or_stop "origin/$TARGET_BRANCH" "origin/$TARGET_BRANCH"
fi

# 本地和远程都为空时，创建空提交以建立远程分支。
if ! git rev-parse --verify HEAD >/dev/null 2>&1; then
  log "本地和远程均为空，创建 Initial commit"
  git commit --allow-empty -m "Initial commit"
fi

# 推送。
log "推送到 origin/$TARGET_BRANCH"
if ! git push -u origin "$TARGET_BRANCH"; then
  cat >&2 <<EOF

push 失败，没有执行 force push。
常见原因：认证失败、分支保护、远程在本次 fetch 后又有新提交。
修复问题后重新运行脚本即可。
EOF
  exit 3
fi

log "完成"
printf '\nwork_dir=%s\n' "$WORK_DIR"
printf 'branch=%s\n' "$(git branch --show-current)"
printf 'origin=%s\n' "$(git remote get-url origin)"
printf 'user.name=%s\n' "$(git config --local user.name)"
printf 'user.email=%s\n\n' "$(git config --local user.email)"

git status --short --branch