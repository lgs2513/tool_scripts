#!/usr/bin/env bash
set -Eeuo pipefail
export LC_ALL=C

# ============================================================
# linux_source.sh — Linux 内核源码仓库管理脚本
#
# 功能概述：
#   1. clone     把上游最新源码克隆到目标目录（浅克隆 / 完整克隆 / 自定义深度）；
#   2. checkout  把目标目录中的源码切换到指定版本，版本支持：
#                  - 标签           ：v6.8、v6.8-rc2
#                  - git describe   ：v7.2-14827-g45c13f3f9e3b
#                  - 提交 SHA       ：45c13f3f9e3b...（完整 40 位命中率最高）
#                  - 分支           ：master
#                  - 完整引用       ：refs/heads/master、refs/tags/v6.8
#   3. update    把已有仓库更新到上游最新（fetch 后重置到默认分支尖端），
#                也可以带版本参数直接更新到指定版本；
#   4. status    查看仓库当前状态（分支、版本、是否浅克隆、本地改动）；
#   5. unshallow 把浅克隆补全为完整历史（含全部标签）；
#   6. tags      列出远程仓库的标签（支持按正则过滤），方便挑选版本。
#
# 版本获取策略（checkout/update 指定版本时按顺序尝试，直到成功）：
#   a. 本地已能解析（标签/分支/SHA）      —— 直接使用，无需联网；
#   b. describe 形式（xxx-g<sha>）        —— 向远程精确拉取该提交；
#   c. 纯 SHA 恰好是某远程引用的尖端      —— ls-remote 定位后按引用拉取；
#   d. 标签形式（v6.8 / v6.8-rc2）       —— 只拉取需要的单个标签（不拉全部标签）；
#   e. 分支 / refs/ 完整引用              —— 按普通 refspec 拉取；
#   f. 仍失败且当前是浅克隆：
#      - describe 形式带有明确的提交距离，逐级加深历史（--depth 递增）重试；
#      - 最后补全完整历史（--unshallow）后重试，体积较大时会提示磁盘空间需求。
#
# 安全约定：
#   - 绝不自动删除未跟踪文件（本地补丁、编译产物等是安全的）；
#   - 工作区中已跟踪文件被修改时，checkout/update 拒绝执行，除非显式 --force；
#   - update 会把本地分支重置到远程尖端；若本地分支含有未推送的提交，
#     同样需要 --force 确认（必要时可通过 git reflog 找回）；
#   - clone 失败时自动清理本次脚本新建的目录；已存在的目录绝不会被删除。
#
# 依赖与环境：
#   - bash 4.4+、git >= 2.15、coreutils（df/realpath/sort）、awk；
#   - 磁盘空间：浅克隆约需 3GB，完整克隆约需 8GB（脚本会提前检查剩余空间）。
#
# 环境变量（可覆盖默认值）：
#   LINUX_SOURCE_REPO_URL   默认源码仓库地址（见下方 DEFAULT_REPO_URL）
#   LINUX_SOURCE_REMOTE     默认远程名（origin）
#
# 用法：
#   linux_source.sh [选项] <命令> [参数...]
#   详见 -h/--help。
# ============================================================

# ---------------- 默认配置（可被环境变量与命令行选项覆盖） ----------------
DEFAULT_REPO_URL=${LINUX_SOURCE_REPO_URL:-https://github.com/torvalds/linux.git}
DEFAULT_REMOTE=${LINUX_SOURCE_REMOTE:-origin}
DEFAULT_NUM_TAGS=20

# 磁盘空间检查阈值（GB），略高于实际需求，宁严勿漏
SHALLOW_NEED_GB=3
FULL_NEED_GB=8
UNSHALLOW_NEED_GB=8
UPDATE_NEED_GB=2

# ---------------- 运行期选项与状态 ----------------
OPT_REPO_URL=''
OPT_BRANCH=''
OPT_FORCE=false
CLONE_MODE=shallow          # shallow | full | depth
CLONE_DEPTH=1
NUM_TAGS=$DEFAULT_NUM_TAGS

CLONE_CREATED_DIR=false     # 仅当目标目录由本脚本新建时为 true
CLEANUP_DIR=''

usage() {
  cat <<USAGE
Usage: linux_source.sh [选项] <命令> [参数...]

管理 Linux 内核源码仓库：克隆最新源码、切换到指定版本、更新到最新/指定版本。

命令:
  clone     <目录> [版本]    克隆最新源码到 <目录>；若给出 [版本]，克隆后立即切换过去
  checkout  <目录> <版本>    把 <目录> 中的源码切换到 <版本>
  update    <目录> [版本]    拉取远程更新并重置到默认分支尖端；带 [版本] 则更新到该版本
  status    <目录>           查看仓库当前状态
  unshallow <目录>           把浅克隆补全为完整历史（含全部标签）
  tags      [目录|模式]      列出远程标签；参数是目录时使用该仓库的远程，否则作为过滤正则

版本支持的形式:
  标签            v6.8 / v6.8-rc2
  git describe    v7.2-14827-g45c13f3f9e3b
  提交 SHA        45c13f3f9e3b...（完整 40 位命中率最高）
  分支            master
  完整引用        refs/heads/master、refs/tags/v6.8

选项:
  --repo-url URL   源码仓库地址，默认: ${DEFAULT_REPO_URL}
                   （环境变量 LINUX_SOURCE_REPO_URL 同名覆盖；
                    kernel.org 官方源: https://git.kernel.org/pub/scm/linux/kernel/git/torvalds/linux.git）
  --remote NAME    远程名，默认: ${DEFAULT_REMOTE}（环境变量 LINUX_SOURCE_REMOTE）
  --branch NAME    克隆/更新使用的分支；默认自动探测远程 HEAD（torvalds/linux 为 master）
  --shallow        浅克隆，depth=1（默认，下载量最小）
  --full           完整克隆，包含全部历史和标签
  --depth N        自定义克隆深度（正整数）
  --num-tags N     tags 命令显示的标签数量，默认: ${DEFAULT_NUM_TAGS}
  --force          允许丢弃已跟踪文件的本地修改 / 本地未推送的提交
  -h, --help       显示本帮助

示例:
  linux_source.sh clone ~/kernel/linux
  linux_source.sh --full clone ~/kernel/linux
  linux_source.sh clone ~/kernel/linux v6.8
  linux_source.sh checkout ~/kernel/linux v7.2-14827-g45c13f3f9e3b
  linux_source.sh checkout ~/kernel/linux master
  linux_source.sh update ~/kernel/linux
  linux_source.sh update ~/kernel/linux v6.8
  linux_source.sh status ~/kernel/linux
  linux_source.sh tags 'v6\.1'
  linux_source.sh unshallow ~/kernel/linux
  linux_source.sh --repo-url https://git.kernel.org/pub/scm/linux/kernel/git/torvalds/linux.git clone ~/kernel/linux

退出码: 0 成功；1 执行失败；64 用法错误。
USAGE
}

# ---------------- 基础工具函数 ----------------
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

# URL 归一化：忽略末尾斜杠、.git 后缀和 file:// 前缀的差异
normalize_url() {
  local u=$1
  u=${u%/}
  u=${u%.git}
  printf '%s' "${u#file://}"
}

# 出错时报告失败位置（配合 set -e 自动终止）
on_error() {
  local rc=$?
  printf 'ERROR: 第 %s 行命令失败（退出码 %s），脚本终止\n' "$LINENO" "$rc" >&2
}
trap on_error ERR

# clone 失败时清理脚本新建的目录；已存在的目录绝不会被删除
cleanup_partial_clone() {
  if [[ "${CLONE_CREATED_DIR:-false}" == true && -n "${CLEANUP_DIR:-}" && -d "${CLEANUP_DIR:-}" ]]; then
    local p=$CLEANUP_DIR
    if [[ "$p" != "/" && ${#p} -gt 1 ]]; then
      log "清理克隆失败留下的目录：$p"
      rm -rf -- "$p"
    fi
  fi
}
trap cleanup_partial_clone EXIT

# ---------------- Git 基础检查 ----------------
# 目标目录必须是一个 Git 工作树的根目录
is_git_worktree_root() {
  local dir=$1 root
  git -C "$dir" rev-parse --is-inside-work-tree >/dev/null 2>&1 || return 1
  root=$(git -C "$dir" rev-parse --show-toplevel 2>/dev/null) || return 1
  [[ "$(realpath -e -- "$root")" == "$(realpath -e -- "$dir")" ]]
}

is_shallow_repo() {
  local out
  out=$(git -C "$1" rev-parse --is-shallow-repository 2>/dev/null) || return 1
  [[ "$out" == true ]]
}

# 仓库中有未完成的 merge/cherry-pick/rebase 时拒绝操作
ensure_git_state_valid() {
  local dir=$1 git_dir marker
  git_dir=$(git -C "$dir" rev-parse --absolute-git-dir)
  for marker in MERGE_HEAD CHERRY_PICK_HEAD REVERT_HEAD; do
    if [[ -e "$git_dir/$marker" ]]; then
      die "仓库存在未完成的操作：$marker，请先处理后再运行"
    fi
  done
  if [[ -d "$git_dir/rebase-merge" || -d "$git_dir/rebase-apply" ]]; then
    die "仓库存在未完成的 rebase，请先处理后再运行"
  fi
}

# 只关注“已跟踪文件”的修改；未跟踪文件不影响切换且会被完整保留
require_clean_worktree() {
  local dir=$1 action=$2
  if ! git -C "$dir" diff --quiet HEAD -- >/dev/null 2>&1 || \
     ! git -C "$dir" diff --cached --quiet >/dev/null 2>&1; then
    if [[ "$OPT_FORCE" != true ]]; then
      die "$action 需要干净的工作区：检测到已跟踪文件被修改。
如确认丢弃这些修改，请加 --force 重新运行（未跟踪文件不会被删除）。"
    fi
    log "--force：丢弃已跟踪文件的本地修改（未跟踪文件保留）"
  fi
}

# 确定操作使用的远程名，并校验与 --repo-url 是否一致
prepare_repo() {
  local dir=$1 url
  if ! git -C "$dir" remote get-url "$DEFAULT_REMOTE" >/dev/null 2>&1; then
    local remotes=()
    read -r -a remotes <<<"$(git -C "$dir" remote)" || true
    if [[ ${#remotes[@]} -eq 1 ]]; then
      log "仓库没有远程 $DEFAULT_REMOTE，改用唯一远程：${remotes[0]}"
      DEFAULT_REMOTE=${remotes[0]}
    else
      die "仓库中没有名为 $DEFAULT_REMOTE 的远程（可用 git remote -v 查看）"
    fi
  fi
  url=$(git -C "$dir" remote get-url "$DEFAULT_REMOTE")
  if [[ -n "$OPT_REPO_URL" ]] && [[ "$(normalize_url "$url")" != "$(normalize_url "$OPT_REPO_URL")" ]]; then
    die "仓库远程地址（$url）与 --repo-url（$OPT_REPO_URL）不一致"
  fi
  if [[ "$(normalize_url "$url")" != "$(normalize_url "$DEFAULT_REPO_URL")" ]]; then
    log "提示：仓库远程（$url）与默认 Linux 仓库（$DEFAULT_REPO_URL）不同，按仓库自身远程继续"
  fi
}

# 通过 ls-remote --symhead 探测远程默认分支（torvalds/linux 为 master）
detect_default_branch() {
  local out ref
  out=$(git ls-remote --symref "$1" HEAD 2>/dev/null) || return 1
  ref=$(printf '%s\n' "$out" | awk -F'\t' '$1 ~ /^ref: / {sub(/^ref: /, "", $1); print $1; exit}')
  if [[ -z "$ref" ]]; then
    return 1
  fi
  printf '%s' "${ref#refs/heads/}"
}

effective_branch() {
  local url=$1 b
  if [[ -n "$OPT_BRANCH" ]]; then
    printf '%s' "$OPT_BRANCH"
    return 0
  fi
  if b=$(detect_default_branch "$url"); then
    printf '%s' "$b"
    return 0
  fi
  log "无法探测远程默认分支，回退使用 master"
  printf '%s' master
}

# ---------------- 磁盘空间检查 ----------------
get_avail_gb() {
  local dir=$1 out
  if out=$(df -BG --output=avail "$dir" 2>/dev/null); then
    awk 'NR==2 {gsub(/[^0-9]/, ""); print}' <<<"$out"
    return 0
  fi
  df -kP "$dir" 2>/dev/null | awk 'NR==2 {printf "%d\n", int($4 / 1024 / 1024)}'
}

check_free_space() {
  local dir=$1 need=$2 what=$3 avail
  avail=$(get_avail_gb "$dir") || { log "无法检测磁盘剩余空间，跳过检查"; return 0; }
  if [[ ! "$avail" =~ ^[0-9]+$ ]]; then
    log "无法解析磁盘剩余空间（$avail），跳过检查"
    return 0
  fi
  if (( avail < need )); then
    die "磁盘空间不足：$what 约需 ${need}GB，${dir} 所在文件系统仅剩 ${avail}GB"
  fi
}

# ---------------- 版本解析 ----------------
# 解析版本字符串，结果放入全局变量：
#   PARSE_KIND     describe | sha | tag | ref | branch
#   PARSE_BASE_TAG describe/tag 形式的基础标签
#   PARSE_COUNT    describe 形式中基础标签之后的提交数
#   PARSE_SHA      describe/sha 形式中的提交哈希
parse_version() {
  local v=$1
  PARSE_KIND='' PARSE_BASE_TAG='' PARSE_SHA='' PARSE_COUNT=0
  if [[ "$v" =~ ^(.*)-([0-9]+)-g([0-9a-f]{7,40})$ ]]; then
    PARSE_KIND=describe
    PARSE_BASE_TAG=${BASH_REMATCH[1]}
    PARSE_COUNT=${BASH_REMATCH[2]}
    PARSE_SHA=${BASH_REMATCH[3]}
    return 0
  fi
  if [[ "$v" =~ ^[0-9a-f]{7,40}$ ]]; then
    PARSE_KIND=sha
    PARSE_SHA=$v
    return 0
  fi
  if [[ "$v" =~ ^v[0-9]+([.][0-9]+)*(-rc[0-9]+)?$ ]]; then
    PARSE_KIND=tag
    PARSE_BASE_TAG=$v
    return 0
  fi
  if [[ "$v" == refs/* ]]; then
    PARSE_KIND=ref
    return 0
  fi
  PARSE_KIND=branch
}

validate_version() {
  local v=$1
  if [[ ${#v} -lt 2 ]]; then
    die "版本名太短：$v"
  fi
  if [[ "$v" == *" "* || "$v" == *$'\t'* || "$v" == *$'\n'* ]]; then
    die "版本名包含空白字符：$v"
  fi
  if [[ "$v" == -* ]]; then
    die "版本名不能以 '-' 开头（会被当成选项）：$v"
  fi
  if [[ "$v" == *..* ]] || [[ "$v" == *[!0-9a-zA-Z._+/@-]* ]]; then
    die "版本名包含非法字符：$v"
  fi
}

# 本地可解析则输出完整 40 位 SHA
resolve_local() {
  local dir=$1 ver=$2
  parse_version "$ver"
  case "$PARSE_KIND" in
    describe|sha)
      git -C "$dir" rev-parse --verify --quiet "$PARSE_SHA^{commit}" 2>/dev/null || return 1
      ;;
    *)
      git -C "$dir" rev-parse --verify --quiet "$ver^{commit}" 2>/dev/null || return 1
      ;;
  esac
}

version_resolvable() {
  resolve_local "$1" "$2" >/dev/null 2>&1
}

# 按策略链把 <ver> 拉取到本地；成功返回 0（此时本地已能解析该版本）
fetch_version() {
  local dir=$1 ver=$2 remote=$DEFAULT_REMOTE refs match refspec d

  parse_version "$ver"

  # a. describe 形式：优先按提交精确拉取（GitHub/kernel.org 支持按 SHA 拉取可达提交）
  if [[ "$PARSE_KIND" == describe ]]; then
    log "按提交精确拉取：$PARSE_SHA"
    if git -C "$dir" fetch -q "$remote" "$PARSE_SHA" 2>/dev/null && version_resolvable "$dir" "$ver"; then
      return 0
    fi
  fi

  # b. 纯 SHA：若正好是远程某个引用的尖端，先通过 ls-remote 定位再按引用拉取
  if [[ "$PARSE_KIND" == sha ]]; then
    refs=$(git -C "$dir" ls-remote "$remote" 2>/dev/null || true)
    match=$(printf '%s\n' "$refs" | awk -v s="$PARSE_SHA" 'tolower($1) ~ s {print $2; exit}')
    if [[ -n "$match" ]]; then
      log "SHA 匹配到远程引用：$match"
      if git -C "$dir" fetch -q "$remote" "$match" 2>/dev/null && version_resolvable "$dir" "$ver"; then
        return 0
      fi
    fi
    if git -C "$dir" fetch -q "$remote" "$PARSE_SHA" 2>/dev/null && version_resolvable "$dir" "$ver"; then
      return 0
    fi
  fi

  # c. 标签类：只拉取需要的这一个标签，避免拉全部标签
  if [[ "$PARSE_KIND" == tag || "$PARSE_KIND" == describe ]]; then
    log "拉取标签：$PARSE_BASE_TAG"
    if git -C "$dir" fetch -q "$remote" "+refs/tags/$PARSE_BASE_TAG:refs/tags/$PARSE_BASE_TAG" 2>/dev/null && \
       version_resolvable "$dir" "$ver"; then
      return 0
    fi
    # describe 形式拉到基础标签并不保证包含目标提交，继续尝试后面的步骤
  fi

  # d. 分支 / 完整引用：按 refspec 拉取，并同步到 refs/remotes/<remote>/<name>
  if [[ "$PARSE_KIND" == branch || "$PARSE_KIND" == ref ]]; then
    if [[ "$ver" == refs/* ]]; then
      refspec="+$ver:$ver"
    else
      refspec="+refs/heads/$ver:refs/remotes/$remote/$ver"
    fi
    log "拉取引用：$ver"
    if git -C "$dir" fetch -q "$remote" "$refspec" 2>/dev/null && version_resolvable "$dir" "$ver"; then
      return 0
    fi
  fi

  # e. 浅克隆兜底
  if is_shallow_repo "$dir"; then
    # describe 形式带有明确的提交距离，逐级加深历史通常比直接补全更省流量
    if [[ "$PARSE_KIND" == describe ]]; then
      d=$(( PARSE_COUNT + 64 ))
      local _
      for _ in 1 2 3 4 5; do
        log "加深历史后重试（depth=$d）"
        if git -C "$dir" fetch -q --depth="$d" "$remote" 2>/dev/null && version_resolvable "$dir" "$ver"; then
          return 0
        fi
        d=$(( d * 2 ))
      done
    fi

    log "仍未命中，补全完整历史后重试（下载量较大，请耐心等待）"
    check_free_space "$dir" "$UNSHALLOW_NEED_GB" "补全完整历史"
    if git -C "$dir" fetch --unshallow "$remote" 2>/dev/null; then
      git -C "$dir" fetch -q --tags "$remote" 2>/dev/null || true
      if version_resolvable "$dir" "$ver"; then
        return 0
      fi
    fi
  fi

  return 1
}

# ---------------- 输出辅助 ----------------
clone_mode_desc() {
  case "$CLONE_MODE" in
    shallow) printf '%s' '浅克隆 depth=1' ;;
    full)    printf '%s' '完整克隆（全部历史与标签）' ;;
    depth)   printf '%s' "自定义深度 depth=$CLONE_DEPTH" ;;
  esac
}

# 打印当前位置：分支/分离状态、HEAD、git describe（尽力而为）
print_position() {
  local dir=$1 branch sha describe
  sha=$(git -C "$dir" rev-parse HEAD)
  branch=$(git -C "$dir" rev-parse --abbrev-ref HEAD)
  describe=$(git -C "$dir" describe --tags --always --dirty 2>/dev/null || true)
  if [[ "$branch" == "HEAD" ]]; then
    branch='(分离 HEAD)'
  fi
  log "当前位置：$branch ${sha:0:12}"
  if [[ -n "$describe" ]]; then
    log "版本描述：$describe"
  fi
  if is_shallow_repo "$dir"; then
    log "仓库形态：浅克隆（历史按需补拉）"
  fi
}

# ---------------- 各命令的实现 ----------------
do_clone() {
  local dir ver url branch check_dir need_gb heads size
  dir=$(realpath -m -- "${CMD_ARGS[0]}")
  ver=${CMD_ARGS[1]-}
  url=$DEFAULT_REPO_URL
  if [[ -n "$OPT_REPO_URL" ]]; then
    url=$OPT_REPO_URL
  fi

  # 目标目录校验：不存在 / 空目录 / 已是本仓库，三种情况才允许继续
  if [[ -e "$dir" ]]; then
    if [[ ! -d "$dir" ]]; then
      die "目标路径已存在且不是目录：$dir"
    fi
    if [[ -e "$dir/.git" ]]; then
      die "目标目录已是 Git 仓库：$dir；如需同步请使用 update / checkout 命令"
    fi
    if [[ -n "$(ls -A -- "$dir")" ]]; then
      die "目标目录非空且不是 Git 仓库：$dir"
    fi
  else
    CLONE_CREATED_DIR=true
    CLEANUP_DIR=$dir
  fi

  case "$CLONE_MODE" in
    shallow|depth) need_gb=$SHALLOW_NEED_GB ;;
    full)          need_gb=$FULL_NEED_GB ;;
  esac
  check_dir=$dir
  if [[ ! -d "$check_dir" ]]; then
    check_dir=$(dirname -- "$dir")
  fi
  check_free_space "$check_dir" "$need_gb" "克隆源码"

  log "检查远程仓库：$url"
  if ! heads=$(git ls-remote --heads "$url" 2>/dev/null) || [[ -z "$heads" ]]; then
    die "无法访问远程仓库：$url（请检查网络、代理或仓库地址）"
  fi
  branch=$(effective_branch "$url")
  log "远程默认分支：$branch"

  mkdir -p -- "$dir"

  local -a clone_args=(--origin "$DEFAULT_REMOTE")
  case "$CLONE_MODE" in
    shallow) clone_args+=(--depth 1 --single-branch) ;;
    depth)   clone_args+=(--depth "$CLONE_DEPTH" --single-branch) ;;
    full)    : ;;
  esac
  if [[ -n "$OPT_BRANCH" ]]; then
    clone_args+=(--branch "$OPT_BRANCH")
  fi

  log "开始克隆（$(clone_mode_desc)）：$url -> $dir"
  if ! git clone "${clone_args[@]}" "$url" "$dir"; then
    die "克隆失败；目标目录中可能残留不完整数据，请清理后重试"
  fi
  CLONE_CREATED_DIR=false

  size=$(du -sh -- "$dir" 2>/dev/null | awk '{print $1}') || size=''
  if [[ -n "$size" ]]; then
    log "磁盘占用：$size"
  fi
  print_position "$dir"

  if [[ -n "$ver" ]]; then
    log "切换到指定版本：$ver"
    do_checkout "$dir" "$ver"
  fi
}

do_checkout() {
  local dir ver sha
  dir=$(realpath -m -- "$1")
  ver=$2

  is_git_worktree_root "$dir" || die "目标目录不是 Git 工作树：$dir（请先用 clone 命令克隆）"
  prepare_repo "$dir"
  ensure_git_state_valid "$dir"
  validate_version "$ver"
  parse_version "$ver"
  require_clean_worktree "$dir" "切换版本"

  if ! sha=$(resolve_local "$dir" "$ver"); then
    if ! fetch_version "$dir" "$ver"; then
      die "无法获取版本：$ver
建议：
  1) 确认版本名拼写（可用 tags 命令查看远程标签）；
  2) describe/SHA 形式建议使用完整 40 位 SHA；
  3) 浅克隆切换久远版本时会自动补拉历史，耗时与版本远近有关。"
    fi
  fi
  sha=$(resolve_local "$dir" "$ver") || die "内部错误：版本已获取但无法解析"

  local force_arg=()
  if [[ "$OPT_FORCE" == true ]]; then
    force_arg=(-f)
  fi

  if [[ "$PARSE_KIND" == branch ]]; then
    if git -C "$dir" show-ref --verify --quiet "refs/heads/$ver"; then
      log "切换到本地分支：$ver"
      if ! git -C "$dir" checkout -q ${force_arg[@]+"${force_arg[@]}"} "$ver"; then
        die "切换分支失败：$ver（本地修改或未跟踪文件可能与目标分支冲突）"
      fi
    elif git -C "$dir" show-ref --verify --quiet "refs/remotes/$DEFAULT_REMOTE/$ver"; then
      log "切换到远程分支：$DEFAULT_REMOTE/$ver"
      if ! git -C "$dir" checkout -q ${force_arg[@]+"${force_arg[@]}"} -B "$ver" --track "$DEFAULT_REMOTE/$ver"; then
        die "创建/切换分支失败：$ver"
      fi
    else
      # 能解析成提交但不是分支：按提交分离检出
      if ! git -C "$dir" checkout -q ${force_arg[@]+"${force_arg[@]}"} --detach "$sha"; then
        die "检出失败：$sha"
      fi
    fi
  else
    log "检出提交（分离 HEAD）：$ver"
    if ! git -C "$dir" checkout -q ${force_arg[@]+"${force_arg[@]}"} --detach "$sha"; then
      die "检出失败：$ver（未跟踪文件可能与目标版本冲突，可先 git status 查看）"
    fi
  fi

  print_position "$dir"
}

do_update() {
  local dir ver url branch remote_ref force_arg
  dir=$(realpath -m -- "${CMD_ARGS[0]}")
  ver=${CMD_ARGS[1]-}

  is_git_worktree_root "$dir" || die "目标目录不是 Git 工作树：$dir（请先用 clone 命令克隆）"
  prepare_repo "$dir"
  ensure_git_state_valid "$dir"
  require_clean_worktree "$dir" "更新仓库"
  check_free_space "$dir" "$UPDATE_NEED_GB" "更新源码"

  log "拉取远程更新：$DEFAULT_REMOTE"
  if ! git -C "$dir" fetch --prune "$DEFAULT_REMOTE"; then
    die "git fetch 失败，请检查网络后重试"
  fi

  if [[ -n "$ver" ]]; then
    do_checkout "$dir" "$ver"
    return 0
  fi

  url=$(git -C "$dir" remote get-url "$DEFAULT_REMOTE")
  branch=$(effective_branch "$url")
  remote_ref="refs/remotes/$DEFAULT_REMOTE/$branch"

  if ! git -C "$dir" rev-parse --verify --quiet "$remote_ref^{commit}" >/dev/null 2>&1; then
    die "远程分支不存在：$DEFAULT_REMOTE/$branch（可用 --branch 指定其他分支）"
  fi

  # 保护本地未推送的提交
  if git -C "$dir" show-ref --verify --quiet "refs/heads/$branch" && \
     ! git -C "$dir" merge-base --is-ancestor "refs/heads/$branch" "$remote_ref"; then
    if [[ "$OPT_FORCE" != true ]]; then
      die "本地分支 $branch 含有远程没有的提交；确认丢弃（可通过 git reflog 找回）请加 --force"
    fi
    log "--force：本地分支 $branch 将被重置到 $DEFAULT_REMOTE/$branch"
  fi

  force_arg=()
  if [[ "$OPT_FORCE" == true ]]; then
    force_arg=(-f)
  fi
  log "重置到 $DEFAULT_REMOTE/$branch 最新提交"
  if ! git -C "$dir" checkout -q ${force_arg[@]+"${force_arg[@]}"} -B "$branch" "$remote_ref"; then
    die "更新分支失败：$branch"
  fi
  print_position "$dir"
}

do_status() {
  local dir url branch sha describe shallow_state out modified untracked
  dir=$(realpath -m -- "${CMD_ARGS[0]}")
  is_git_worktree_root "$dir" || die "目标目录不是 Git 工作树：$dir"

  if url=$(git -C "$dir" remote get-url "$DEFAULT_REMOTE" 2>/dev/null); then
    :
  else
    url="(远程 $DEFAULT_REMOTE 未配置)"
  fi
  if branch=$(git -C "$dir" rev-parse --abbrev-ref HEAD 2>/dev/null); then
    :
  else
    branch='(无提交)'
  fi
  if sha=$(git -C "$dir" rev-parse HEAD 2>/dev/null); then
    :
  else
    sha='-'
  fi
  describe=$(git -C "$dir" describe --tags --always --dirty 2>/dev/null || true)
  if is_shallow_repo "$dir"; then
    shallow_state=是
  else
    shallow_state=否
  fi

  out=$(git -C "$dir" status --porcelain 2>/dev/null || true)
  modified=$(printf '%s\n' "$out" | grep -c -v '^??' || true)
  untracked=$(printf '%s\n' "$out" | grep -c '^??' || true)

  printf '路径        : %s\n' "$dir"
  printf '远程        : %s (%s)\n' "$DEFAULT_REMOTE" "$url"
  printf '当前分支    : %s\n' "$branch"
  printf 'HEAD        : %s\n' "$sha"
  printf '版本描述    : %s\n' "${describe:-（无标签信息）}"
  printf '浅克隆      : %s\n' "$shallow_state"
  printf '已跟踪修改  : %s 个文件\n' "${modified:-0}"
  printf '未跟踪文件  : %s 个\n' "${untracked:-0}"
}

do_unshallow() {
  local dir
  dir=$(realpath -m -- "${CMD_ARGS[0]}")
  is_git_worktree_root "$dir" || die "目标目录不是 Git 工作树：$dir"
  prepare_repo "$dir"

  if ! is_shallow_repo "$dir"; then
    log "仓库已是完整克隆，无需补全"
    return 0
  fi
  check_free_space "$dir" "$UNSHALLOW_NEED_GB" "补全完整历史"

  log "补全完整历史（下载量较大，请耐心等待）：$dir"
  if ! git -C "$dir" fetch --unshallow "$DEFAULT_REMOTE"; then
    die "补全历史失败，请检查网络后重试"
  fi
  log "拉取全部标签"
  if ! git -C "$dir" fetch --tags "$DEFAULT_REMOTE"; then
    log "警告：拉取标签失败（历史已补全，但标签不完整）"
  fi
  log "提示：补全后仍保持单分支抓取配置；如需抓取所有分支可执行：
  git -C '$dir' remote set-branches '$DEFAULT_REMOTE' '*' && git -C '$dir' fetch '$DEFAULT_REMOTE'"
  print_position "$dir"
}

do_tags() {
  local arg=${CMD_ARGS[0]-} url pattern='' dir names out total
  if [[ -n "$arg" && -d "$arg" ]]; then
    # 参数是目录：使用该仓库的远程
    dir=$(realpath -e -- "$arg")
    is_git_worktree_root "$dir" || die "目录不是 Git 工作树：$dir"
    prepare_repo "$dir"
    url=$(git -C "$dir" remote get-url "$DEFAULT_REMOTE")
  else
    pattern=$arg
    url=${OPT_REPO_URL:-$DEFAULT_REPO_URL}
  fi

  log "查询远程标签：$url"
  out=$(git ls-remote --tags "$url" 2>/dev/null) || die "无法访问远程仓库：$url"
  # 过滤掉 annotated tag 的 peeled 引用（refs/tags/v6.8^{}）
  names=$(printf '%s\n' "$out" | awk '$2 !~ /\^\{\}$/ {sub(/^refs\/tags\//, "", $2); print $2}')
  if [[ -n "$pattern" ]]; then
    names=$(grep -E -- "$pattern" <<<"$names" || true)
  fi
  if [[ -z "$names" ]]; then
    log "没有匹配的标签"
    return 0
  fi

  total=$(printf '%s\n' "$names" | wc -l)
  printf '%s\n' "$names" | sort -V | tail -n "$NUM_TAGS"
  log "共 $total 个标签（按版本排序，显示最后 $NUM_TAGS 个）"
}

# ---------------- 入口：帮助、依赖检查、参数解析与分发 ----------------
if [[ $# -eq 1 && ( "$1" == "-h" || "$1" == "--help" ) ]]; then
  usage
  exit 0
fi

for tool in git realpath awk df sort; do
  command -v "$tool" >/dev/null 2>&1 || die "未找到依赖工具：$tool"
done

COMMAND=''
declare -a CMD_ARGS=()

while [[ $# -gt 0 ]]; do
  case "$1" in
    --repo-url) require_value "$1" "${2-}"; OPT_REPO_URL=$2; shift 2 ;;
    --remote)   require_value "$1" "${2-}"; DEFAULT_REMOTE=$2; shift 2 ;;
    --branch)   require_value "$1" "${2-}"; OPT_BRANCH=$2; shift 2 ;;
    --shallow)  CLONE_MODE=shallow; shift ;;
    --full)     CLONE_MODE=full; shift ;;
    --depth)    require_value "$1" "${2-}"; CLONE_MODE=depth; CLONE_DEPTH=$2; shift 2 ;;
    --num-tags) require_value "$1" "${2-}"; NUM_TAGS=$2; shift 2 ;;
    --force)    OPT_FORCE=true; shift ;;
    -h|--help)  usage; exit 0 ;;
    --)
      shift
      while [[ $# -gt 0 ]]; do
        if [[ -z "$COMMAND" ]]; then
          COMMAND=$1
        else
          CMD_ARGS+=("$1")
        fi
        shift
      done
      ;;
    -*) die "未知选项：$1（参见 --help）" ;;
    *)
      if [[ -z "$COMMAND" ]]; then
        COMMAND=$1
      else
        CMD_ARGS+=("$1")
      fi
      shift
      ;;
  esac
done

[[ -n "$COMMAND" ]] || { usage >&2; exit 64; }
[[ "$CLONE_DEPTH" =~ ^[1-9][0-9]*$ ]] || die "--depth 需要正整数：$CLONE_DEPTH"
[[ "$NUM_TAGS" =~ ^[0-9]+$ ]] || die "--num-tags 需要非负整数：$NUM_TAGS"
git check-ref-format "refs/remotes/$DEFAULT_REMOTE/x" >/dev/null 2>&1 || die "无效远程名：$DEFAULT_REMOTE"
if [[ -n "$OPT_BRANCH" ]]; then
  git check-ref-format --branch "$OPT_BRANCH" >/dev/null 2>&1 || die "无效分支名：$OPT_BRANCH"
fi

case "$COMMAND" in
  clone)     [[ ${#CMD_ARGS[@]} -ge 1 && ${#CMD_ARGS[@]} -le 2 ]] || die "clone 需要 1-2 个参数：<目录> [版本]" ;;
  checkout)  [[ ${#CMD_ARGS[@]} -eq 2 ]] || die "checkout 需要 2 个参数：<目录> <版本>" ;;
  update)    [[ ${#CMD_ARGS[@]} -ge 1 && ${#CMD_ARGS[@]} -le 2 ]] || die "update 需要 1-2 个参数：<目录> [版本]" ;;
  status)    [[ ${#CMD_ARGS[@]} -eq 1 ]] || die "status 需要 1 个参数：<目录>" ;;
  unshallow) [[ ${#CMD_ARGS[@]} -eq 1 ]] || die "unshallow 需要 1 个参数：<目录>" ;;
  tags)      [[ ${#CMD_ARGS[@]} -le 1 ]] || die "tags 至多 1 个参数：[目录|模式]" ;;
  *)         die "未知命令：$COMMAND（参见 --help）" ;;
esac

case "$COMMAND" in
  clone)     do_clone ;;
  checkout)  do_checkout "${CMD_ARGS[0]}" "${CMD_ARGS[1]}" ;;
  update)    do_update ;;
  status)    do_status ;;
  unshallow) do_unshallow ;;
  tags)      do_tags ;;
esac

log "完成"
