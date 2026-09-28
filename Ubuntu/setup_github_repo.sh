#!/usr/bin/env bash
set -Eeuo pipefail

# ============================================================
# 同步本地脚本到 GitHub
#
# 注意：
#   1. 默认分支 main，默认远程名 origin。
#   2. 默认目标目录是本脚本所在目录；如果它位于 Git 仓库中，会自动找到仓库根目录。
#   3. 所有“相对路径”都相对于 setup_github_repo.sh 所在目录，而不是当前终端目录。
#      只有 part 的相对模式例外：文件路径相对于它前面的 BASE_DIR。
#   4. 同步顺序：拉取远程 -> 复制文件 -> git add -> commit -> push。
#   5. 仓库已有未提交改动时会临时 stash，拉取后恢复；只 add 本次选择的目标路径。
#   6. 不会 force push；合并冲突或 push 失败时直接停止。
#   7. 请先配置 .gitignore，避免提交 .env、密钥、数据集等文件。
#
# 用法：
#   setup_github_repo.sh <user.name> <user.email> <repo_url> [选项] <all|part> ...
#
# 选项：
#   -b, --branch BRANCH       目标分支，默认 main
#   -r, --remote NAME         远程名，默认 origin
#   -t, --target-dir PATH     Git 仓库中的目标目录，默认脚本所在目录
#   -m, --message MESSAGE     commit 信息，默认 "sync scripts"
#   -h, --help                显示帮助
#
# all：复制 SOURCE_DIR 下的全部内容到目标目录，保留目录结构。
#   setup_github_repo.sh NAME EMAIL URL all SOURCE_DIR
#
# part 绝对路径模式：后面所有文件/目录必须全部是绝对路径，复制到目标目录。
#   setup_github_repo.sh NAME EMAIL URL part /abs/a.sh /abs/b.sh
#
# part 相对路径模式：第一个参数是 BASE_DIR，后面的文件/目录必须全部是相对路径。
# BASE_DIR 可以是绝对路径，也可以是相对于本脚本的路径；相对文件路径会保留目录结构。
#   setup_github_repo.sh NAME EMAIL URL part ../source a.sh sub/b.sh
# ============================================================

usage() {
  cat <<'USAGE'
Usage:
  setup_github_repo.sh <user.name> <user.email> <repo_url> [options] <all|part> ...

Options:
  -b, --branch BRANCH       target branch, default: main
  -r, --remote NAME         remote name, default: origin
  -t, --target-dir PATH     destination directory, default: script directory
  -m, --message MESSAGE     commit message, default: sync scripts
  -h, --help                show help

Path rules:
  Relative paths are resolved from the directory containing setup_github_repo.sh,
  not from the current shell directory.

  Exception: in "part" relative mode, file paths are relative to BASE_DIR.

Modes:
  all SOURCE_DIR
      Copy everything under SOURCE_DIR into target-dir.

  part /abs/a.sh /abs/b.sh
      Absolute mode. Every selected path must be absolute.

  part BASE_DIR a.sh sub/b.sh
      Relative mode. BASE_DIR may be absolute or relative to this script.
      Every selected file path after BASE_DIR must be relative.

Examples:
  ./setup_github_repo.sh lgs2513 2312863846@qq.com \
    git@github.com:lgs2513/tool_scripts.git \
    --branch main all ../my_scripts

  ./setup_github_repo.sh lgs2513 2312863846@qq.com \
    git@github.com:lgs2513/tool_scripts.git \
    --target-dir . part /home/guangshuo/a.sh /home/guangshuo/b.sh
USAGE
}

log() {
  printf '==> %s\n' "$*"
}

die() {
  printf 'ERROR: %s\n' "$*" >&2
  exit 1
}

require_value() {
  [[ $# -ge 2 && -n "$2" ]] || die "$1 缺少参数"
}

resolve_from_script() {
  local path=$1
  if [[ "$path" == /* ]]; then
    realpath -m -- "$path"
  else
    realpath -m -- "$SCRIPT_DIR/$path"
  fi
}

is_within() {
  local child=$1
  local parent=$2
  [[ "$child" == "$parent" || "$child" == "$parent/"* ]]
}

ensure_git_state_valid() {
  local git_dir marker
  git_dir=$(git -C "$REPO_ROOT" rev-parse --git-dir)

  for marker in MERGE_HEAD CHERRY_PICK_HEAD REVERT_HEAD; do
    [[ ! -e "$git_dir/$marker" ]] || die "检测到未完成的 Git 操作：$marker"
  done

  [[ ! -d "$git_dir/rebase-merge" && ! -d "$git_dir/rebase-apply" ]] || \
    die "检测到未完成的 rebase"

  [[ -z "$(git -C "$REPO_ROOT" diff --name-only --diff-filter=U)" ]] || \
    die "仓库中存在未解决的冲突，请先处理"
}

copy_path() {
  local src=$1
  local dst=$2

  src=$(realpath -e -- "$src")
  dst=$(realpath -m -- "$dst")

  is_within "$dst" "$REPO_ROOT" || die "目标路径不在 Git 仓库内：$dst"
  is_within "$dst" "$TARGET_DIR" || die "目标路径超出 target-dir：$dst"

  if [[ "$src" == "$dst" ]]; then
    return 0
  fi

  if [[ -d "$src" && ! -L "$src" ]]; then
    if [[ -e "$dst" && ! -d "$dst" ]]; then
      die "类型冲突：源是目录，但目标不是目录：$dst"
    fi

    mkdir -p -- "$dst"
    (
      cd "$src"
      tar --exclude='.git' --exclude='*/.git' -cf - .
    ) | (
      cd "$dst"
      tar -xf -
    )
  else
    if [[ -d "$dst" && ! -L "$dst" ]]; then
      die "类型冲突：源是文件，但目标是目录：$dst"
    fi

    mkdir -p -- "$(dirname -- "$dst")"
    cp -a -- "$src" "$dst"
  fi
}

stage_path() {
  local abs_path=$1
  local rel_path

  abs_path=$(realpath -m -- "$abs_path")
  is_within "$abs_path" "$REPO_ROOT" || die "无法添加仓库外路径：$abs_path"

  if [[ "$abs_path" == "$REPO_ROOT" ]]; then
    rel_path=.
  else
    rel_path=${abs_path#"$REPO_ROOT"/}
  fi

  if git -C "$REPO_ROOT" check-ignore -q -- "$rel_path" 2>/dev/null; then
    log "跳过 .gitignore：$rel_path"
    return 0
  fi

  git -C "$REPO_ROOT" add -- "$rel_path"
}

prepare_local_changes() {
  AUTO_STASH=false
  AUTO_STASH_REF=''
  UNBORN_BACKUP=false
  UNBORN_BACKUP_DIR=''

  if git -C "$REPO_ROOT" rev-parse --verify HEAD >/dev/null 2>&1; then
    [[ -n "$(git -C "$REPO_ROOT" status --porcelain)" ]] || return 0

    log "临时保存本地未提交改动"
    git -C "$REPO_ROOT" stash push -u -m "setup_github_repo auto-stash" >/dev/null
    AUTO_STASH=true
    AUTO_STASH_REF='stash@{0}'
    return 0
  fi

  [[ "$REMOTE_BRANCH_EXISTS" == true ]] || return 0

  if find "$REPO_ROOT" -mindepth 1 -maxdepth 1 ! -name .git -print -quit | grep -q .; then
    log "临时备份本地文件"
    UNBORN_BACKUP_DIR=$(mktemp -d)
    (
      cd "$REPO_ROOT"
      tar --exclude='.git' --exclude='*/.git' -cf - .
    ) | (
      cd "$UNBORN_BACKUP_DIR"
      tar -xf -
    )

    find "$REPO_ROOT" -mindepth 1 -maxdepth 1 ! -name .git -exec rm -rf -- {} +
    UNBORN_BACKUP=true
  fi
}

restore_local_changes() {
  if [[ "$UNBORN_BACKUP" == true ]]; then
    log "恢复本地文件"
    (
      cd "$UNBORN_BACKUP_DIR"
      tar -cf - .
    ) | (
      cd "$REPO_ROOT"
      tar -xf -
    )
    rm -rf -- "$UNBORN_BACKUP_DIR"
    UNBORN_BACKUP=false
  fi

  if [[ "$AUTO_STASH" == true ]]; then
    log "恢复本地未提交改动"
    if ! git -C "$REPO_ROOT" stash apply "$AUTO_STASH_REF"; then
      die "恢复自动 stash 时发生冲突；stash 未删除，请运行 git status 处理"
    fi

    git -C "$REPO_ROOT" stash drop "$AUTO_STASH_REF" >/dev/null
    AUTO_STASH=false
  fi
}

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)

if [[ $# -eq 1 && ( "$1" == "-h" || "$1" == "--help" ) ]]; then
  usage
  exit 0
fi

[[ $# -ge 4 ]] || {
  usage >&2
  exit 64
}

USER_NAME=$1
USER_EMAIL=$2
REPO_URL=$3
shift 3

[[ -n "$USER_NAME" ]] || die "user.name 不能为空"
[[ -n "$USER_EMAIL" ]] || die "user.email 不能为空"
[[ -n "$REPO_URL" ]] || die "repo_url 不能为空"

BRANCH=main
REMOTE=origin
TARGET_RAW=$SCRIPT_DIR
COMMIT_MESSAGE='sync scripts'
MODE=''

declare -a MODE_ARGS=()

while [[ $# -gt 0 ]]; do
  case "$1" in
    -b|--branch)
      require_value "$1" "${2-}"
      BRANCH=$2
      shift 2
      ;;
    -r|--remote)
      require_value "$1" "${2-}"
      REMOTE=$2
      shift 2
      ;;
    -t|--target-dir)
      require_value "$1" "${2-}"
      TARGET_RAW=$2
      shift 2
      ;;
    -m|--message)
      require_value "$1" "${2-}"
      COMMIT_MESSAGE=$2
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    all|part)
      MODE=$1
      shift
      MODE_ARGS=("$@")
      break
      ;;
    --)
      shift
      [[ $# -gt 0 ]] || die "缺少 all 或 part"
      MODE=$1
      [[ "$MODE" == "all" || "$MODE" == "part" ]] || die "模式必须是 all 或 part"
      shift
      MODE_ARGS=("$@")
      break
      ;;
    *)
      die "未知参数：$1"
      ;;
  esac
done

[[ -n "$MODE" ]] || die "缺少 all 或 part"

command -v git >/dev/null 2>&1 || die "未找到 git"
command -v realpath >/dev/null 2>&1 || die "未找到 realpath"
command -v tar >/dev/null 2>&1 || die "未找到 tar"

git check-ref-format --branch "$BRANCH" >/dev/null 2>&1 || die "无效分支名：$BRANCH"
git check-ref-format "refs/remotes/$REMOTE/check" >/dev/null 2>&1 || die "无效远程名：$REMOTE"

TARGET_DIR=$(resolve_from_script "$TARGET_RAW")
mkdir -p -- "$TARGET_DIR"
TARGET_DIR=$(realpath -e -- "$TARGET_DIR")

# 先解析源路径。
declare -a SRC_PATHS=()
declare -a DST_PATHS=()
ALL_ABSOLUTE=false

if [[ "$MODE" == "all" ]]; then
  [[ ${#MODE_ARGS[@]} -eq 1 ]] || die "all 需要且只需要一个 SOURCE_DIR"

  SOURCE_DIR=$(resolve_from_script "${MODE_ARGS[0]}")
  [[ -d "$SOURCE_DIR" ]] || die "SOURCE_DIR 不是目录：$SOURCE_DIR"
  SOURCE_DIR=$(realpath -e -- "$SOURCE_DIR")

else
  [[ ${#MODE_ARGS[@]} -ge 1 ]] || die "part 至少需要一个路径"

  ALL_ABSOLUTE=true
  for arg in "${MODE_ARGS[@]}"; do
    if [[ "$arg" != /* ]]; then
      ALL_ABSOLUTE=false
      break
    fi
  done

  if [[ "$ALL_ABSOLUTE" == true ]]; then
    for arg in "${MODE_ARGS[@]}"; do
      [[ -e "$arg" || -L "$arg" ]] || die "路径不存在：$arg"
      SRC_PATHS+=("$(realpath -e -- "$arg")")
    done
  else
    [[ ${#MODE_ARGS[@]} -ge 2 ]] || \
      die "part 相对模式需要：BASE_DIR + 至少一个相对文件路径"

    BASE_DIR=$(resolve_from_script "${MODE_ARGS[0]}")
    [[ -d "$BASE_DIR" ]] || die "BASE_DIR 不是目录：$BASE_DIR"
    BASE_DIR=$(realpath -e -- "$BASE_DIR")

    for ((i = 1; i < ${#MODE_ARGS[@]}; i++)); do
      rel=${MODE_ARGS[$i]}
      [[ "$rel" != /* ]] || die "part 相对模式中，文件路径必须全部是相对路径：$rel"

      src=$(realpath -e -- "$BASE_DIR/$rel" 2>/dev/null) || die "路径不存在：$BASE_DIR/$rel"
      is_within "$src" "$BASE_DIR" || die "相对路径不能超出 BASE_DIR：$rel"

      SRC_PATHS+=("$src")
      DST_PATHS+=("$rel")
    done
  fi
fi

# 检查远程访问，并判断目标分支是否存在。
log "检查远程仓库"
REMOTE_HEADS=$(git ls-remote --heads "$REPO_URL") || \
  die "无法访问远程仓库，请检查仓库地址和认证信息"

REMOTE_BRANCH_EXISTS=false
if printf '%s\n' "$REMOTE_HEADS" | awk -v ref="refs/heads/$BRANCH" '$2 == ref { found=1 } END { exit !found }'; then
  REMOTE_BRANCH_EXISTS=true
elif [[ -n "$REMOTE_HEADS" ]]; then
  log "远程不存在分支 $BRANCH；本次会创建该分支，不会合并其他分支"
fi

# 找到现有 Git 仓库；没有则在 target-dir 初始化。
if git -C "$TARGET_DIR" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  REPO_ROOT=$(git -C "$TARGET_DIR" rev-parse --show-toplevel)
  REPO_ROOT=$(realpath -e -- "$REPO_ROOT")
else
  log "初始化 Git 仓库：$TARGET_DIR"
  if ! git -C "$TARGET_DIR" init -q -b "$BRANCH" 2>/dev/null; then
    git -C "$TARGET_DIR" init -q
    git -C "$TARGET_DIR" symbolic-ref HEAD "refs/heads/$BRANCH"
  fi
  REPO_ROOT=$TARGET_DIR
fi

is_within "$TARGET_DIR" "$REPO_ROOT" || die "target-dir 不在 Git 仓库内"

log "repo_root: $REPO_ROOT"
log "target_dir: $TARGET_DIR"
log "branch: $BRANCH"
log "remote: $REMOTE"

ensure_git_state_valid

git -C "$REPO_ROOT" config --local user.name "$USER_NAME"
git -C "$REPO_ROOT" config --local user.email "$USER_EMAIL"

if git -C "$REPO_ROOT" remote get-url "$REMOTE" >/dev/null 2>&1; then
  OLD_URL=$(git -C "$REPO_ROOT" remote get-url "$REMOTE")
  if [[ "$OLD_URL" != "$REPO_URL" ]]; then
    log "更新 $REMOTE: $OLD_URL -> $REPO_URL"
    git -C "$REPO_ROOT" remote set-url "$REMOTE" "$REPO_URL"
  fi
else
  git -C "$REPO_ROOT" remote add "$REMOTE" "$REPO_URL"
fi

LOCAL_HAS_HEAD=false
if git -C "$REPO_ROOT" rev-parse --verify HEAD >/dev/null 2>&1; then
  LOCAL_HAS_HEAD=true
fi

# fetch 不修改工作区，可以在 stash 前执行。
if [[ "$REMOTE_BRANCH_EXISTS" == true ]]; then
  log "获取 $REMOTE/$BRANCH"
  git -C "$REPO_ROOT" fetch --prune "$REMOTE" "$BRANCH"
fi

prepare_local_changes

# 切换并同步目标分支。
if git -C "$REPO_ROOT" show-ref --verify --quiet "refs/heads/$BRANCH"; then
  git -C "$REPO_ROOT" checkout -q "$BRANCH"
elif [[ "$REMOTE_BRANCH_EXISTS" == true ]]; then
  git -C "$REPO_ROOT" checkout -q -b "$BRANCH" --track "$REMOTE/$BRANCH"
elif [[ "$LOCAL_HAS_HEAD" == true ]]; then
  git -C "$REPO_ROOT" checkout -q -b "$BRANCH"
else
  git -C "$REPO_ROOT" symbolic-ref HEAD "refs/heads/$BRANCH"
fi

if [[ "$REMOTE_BRANCH_EXISTS" == true ]]; then
  log "同步 $REMOTE/$BRANCH"

  if git -C "$REPO_ROOT" merge-base HEAD "$REMOTE/$BRANCH" >/dev/null 2>&1; then
    if ! git -C "$REPO_ROOT" merge --no-edit "$REMOTE/$BRANCH"; then
      git -C "$REPO_ROOT" merge --abort >/dev/null 2>&1 || true
      restore_local_changes || true
      die "远程分支合并冲突，已停止"
    fi
  else
    if ! git -C "$REPO_ROOT" merge --allow-unrelated-histories --no-edit "$REMOTE/$BRANCH"; then
      git -C "$REPO_ROOT" merge --abort >/dev/null 2>&1 || true
      restore_local_changes || true
      die "本地与远程历史冲突，已停止"
    fi
  fi
fi

restore_local_changes

# 复制并记录本次需要 git add 的目标路径。
declare -a STAGE_PATHS=()

if [[ "$MODE" == "all" ]]; then
  log "复制全部内容：$SOURCE_DIR -> $TARGET_DIR"

  if is_within "$TARGET_DIR" "$SOURCE_DIR" && [[ "$TARGET_DIR" != "$SOURCE_DIR" ]]; then
    die "target-dir 位于 SOURCE_DIR 内，可能造成递归复制"
  fi

  while IFS= read -r -d '' src; do
    name=$(basename -- "$src")
    [[ "$name" == ".git" ]] && continue

    dst=$(realpath -m -- "$TARGET_DIR/$name")
    copy_path "$src" "$dst"
    STAGE_PATHS+=("$dst")
  done < <(find "$SOURCE_DIR" -mindepth 1 -maxdepth 1 -print0)

elif [[ "$ALL_ABSOLUTE" == true ]]; then
  log "复制指定路径（绝对路径模式）"

  for src in "${SRC_PATHS[@]}"; do
    name=$(basename -- "$src")
    dst=$(realpath -m -- "$TARGET_DIR/$name")
    copy_path "$src" "$dst"
    STAGE_PATHS+=("$dst")
  done

else
  log "复制指定路径（相对路径模式）"

  for ((i = 0; i < ${#SRC_PATHS[@]}; i++)); do
    src=${SRC_PATHS[$i]}
    rel=${DST_PATHS[$i]}
    dst=$(realpath -m -- "$TARGET_DIR/$rel")
    is_within "$dst" "$TARGET_DIR" || die "目标相对路径超出 target-dir：$rel"
    copy_path "$src" "$dst"
    STAGE_PATHS+=("$dst")
  done
fi

# 只 add 本次复制涉及的路径。
if [[ ${#STAGE_PATHS[@]} -gt 0 ]]; then
  for path in "${STAGE_PATHS[@]}"; do
    stage_path "$path"
  done
else
  log "没有找到可复制的文件"
fi

if ! git -C "$REPO_ROOT" diff --cached --quiet; then
  log "提交改动"
  git -C "$REPO_ROOT" commit -m "$COMMIT_MESSAGE"
else
  log "没有新的文件改动需要提交"
fi

# 空仓库且没有可提交内容时，建立目标分支。
if ! git -C "$REPO_ROOT" rev-parse --verify HEAD >/dev/null 2>&1; then
  log "创建空的 Initial commit"
  git -C "$REPO_ROOT" commit --allow-empty -m "Initial commit"
fi

log "推送 $BRANCH -> $REMOTE"
if ! git -C "$REPO_ROOT" push -u "$REMOTE" "$BRANCH"; then
  die "push 失败；未执行 force push"
fi

log "完成"
printf '\nrepo_root=%s\n' "$REPO_ROOT"
printf 'target_dir=%s\n' "$TARGET_DIR"
printf 'branch=%s\n' "$BRANCH"
printf 'remote=%s\n' "$REMOTE"
printf 'remote_url=%s\n\n' "$(git -C "$REPO_ROOT" remote get-url "$REMOTE")"
git -C "$REPO_ROOT" status --short --branch
