#!/usr/bin/env bash
set -Eeuo pipefail

# ============================================================
# setup_ssh_key.sh — 生成本地 SSH 密钥并完成 GitHub 授权引导
#
# 功能概述：
#   1. 在本地生成一对 SSH 密钥（默认 ed25519，可选 rsa/4096），
#      默认写入 ~/.ssh/id_ed25519，可用 -f 指定其他路径；
#   2. 设置安全的文件权限（~/.ssh 为 700，私钥 600，公钥 644）；
#   3. 生成后打印公钥与“添加到 GitHub”的操作指引；
#      若检测到已登录的 gh 命令行工具，会尝试自动上传公钥
#      （--no-gh 可跳过自动上传）；
#   4. 密钥使用非默认路径时，自动在 ~/.ssh/config 中为 github.com
#      追加 IdentityFile 配置（幂等，不会重复添加、不改动其他配置）；
#   5. 已有 ssh-agent 时尝试把私钥加入 agent（口令密钥会提示输入口令）；
#   6. --test  可随时验证与 GitHub 的授权是否生效
#      （成功时 GitHub 返回 "Hi <用户名>! You've successfully authenticated"）；
#   7. --print 仅打印现有公钥，方便再次复制。
#
# 安全约定：
#   - 目标私钥已存在时拒绝执行，除非 --force；覆盖时旧密钥会改名为
#     <key>.bak.<时间戳> 而不是删除，随时可以找回；
#   - 默认建议为私钥设置口令（ssh-keygen 会交互式提示输入两次），
#     无人值守/自动化场景可用 --no-passphrase 生成无口令密钥；
#   - 本脚本只读写当前用户的 ~/.ssh，不触碰其他任何位置。
#
# 依赖：
#   - 必需：openssh-client（ssh-keygen、ssh）、coreutils（stat/chmod/tail）；
#   - 可选：gh（自动上传公钥）、xclip/xsel/wl-copy（复制公钥到剪贴板）。
#
# 用法：
#   setup_ssh_key.sh [选项] [邮箱]
#   详见 -h/--help。
# ============================================================

usage() {
  cat <<'USAGE'
Usage: setup_ssh_key.sh [选项] [邮箱]

生成本地 SSH 密钥并引导完成 GitHub 授权。

参数:
  [邮箱]                密钥注释（可选）；默认取 git config --global user.email，
                        再退回 USER@HOSTNAME

选项:
  -f, --key-file PATH   密钥路径，默认 ~/.ssh/id_ed25519（rsa 时为 ~/.ssh/id_rsa）；
                        相对路径基于当前终端目录
  -t, --type TYPE       密钥类型：ed25519（默认）或 rsa
  -b, --bits N          rsa 密钥位数，默认 4096（仅 rsa 类型有效）
  -e, --email EMAIL     密钥注释（与位置参数 [邮箱] 等价）
  -K, --no-passphrase   生成无口令密钥（默认交互式设置口令）
      --force           覆盖已存在的密钥（旧密钥改名为 *.bak.<时间戳>）
      --no-gh           跳过 gh 自动上传，仅打印手动添加指引
      --test            只测试与 GitHub 的授权状态，不生成密钥
      --print           只打印现有公钥，不生成密钥
  -h, --help            显示本帮助

示例:
  setup_ssh_key.sh                          # 交互式生成默认密钥
  setup_ssh_key.sh 2312863846@qq.com        # 指定注释邮箱
  setup_ssh_key.sh -f ~/.ssh/id_github -K   # 自定义路径、无口令
  setup_ssh_key.sh --print                  # 再次打印公钥
  setup_ssh_key.sh --test                   # 验证 GitHub 授权
  setup_ssh_key.sh --test -f ~/.ssh/id_github   # 验证指定密钥

gh 不可用时的手动添加步骤:
  1. 打开 https://github.com/settings/ssh/new
  2. Title 随意（如 "user@host 日期"），Key 粘贴公钥整行
  3. 保存后运行 setup_ssh_key.sh --test 验证

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

# 出错时报告失败位置（配合 set -e 自动终止）
on_error() {
  local rc=$?
  printf 'ERROR: 第 %s 行命令失败（退出码 %s），脚本终止\n' "$LINENO" "$rc" >&2
}
trap on_error ERR

# ---------------- 选项与默认值 ----------------
SCRIPT_NAME=$(basename -- "$0")

KEY_TYPE=ed25519
RSA_BITS=4096
COMMENT=''
KEY_FILE_RAW=''
NO_PASSPHRASE=false
FORCE=false
NO_GH=false
MODE=generate            # generate | print | test

set_mode() {
  if [[ "$MODE" != generate && "$MODE" != "$1" ]]; then
    die "--test 与 --print 不能同时使用"
  fi
  MODE=$1
}

handle_positional() {
  if [[ -z "$COMMENT" ]]; then
    COMMENT=$1
  else
    die "多余的参数：$1"
  fi
}

# ---------------- 解析参数 ----------------
while [[ $# -gt 0 ]]; do
  case "$1" in
    -f|--key-file)      require_value "$1" "${2-}"; KEY_FILE_RAW=$2; shift 2 ;;
    -t|--type)          require_value "$1" "${2-}"; KEY_TYPE=$2; shift 2 ;;
    -b|--bits)          require_value "$1" "${2-}"; RSA_BITS=$2; shift 2 ;;
    -e|--email|--comment) require_value "$1" "${2-}"; COMMENT=$2; shift 2 ;;
    -K|--no-passphrase) NO_PASSPHRASE=true; shift ;;
    --force)            FORCE=true; shift ;;
    --no-gh)            NO_GH=true; shift ;;
    --test)             set_mode test; shift ;;
    --print)            set_mode print; shift ;;
    -h|--help)          usage; exit 0 ;;
    --)
      shift
      while [[ $# -gt 0 ]]; do
        handle_positional "$1"
        shift
      done
      ;;
    -*) die "未知选项：$1（参见 --help）" ;;
    *)  handle_positional "$1"; shift ;;
  esac
done

# ---------------- 校验与路径解析 ----------------
[[ "$KEY_TYPE" == ed25519 || "$KEY_TYPE" == rsa ]] || die "--type 仅支持 ed25519 或 rsa：$KEY_TYPE"
[[ "$RSA_BITS" =~ ^[1-9][0-9]*$ ]] || die "--bits 需要正整数：$RSA_BITS"

command -v ssh-keygen >/dev/null 2>&1 || die "未找到 ssh-keygen，请先安装：sudo apt install openssh-client"
if [[ "$MODE" == test ]]; then
  command -v ssh >/dev/null 2>&1 || die "未找到 ssh，请先安装：sudo apt install openssh-client"
fi

SSH_DIR="${HOME:?环境变量 HOME 未设置}/.ssh"
if [[ -z "$KEY_FILE_RAW" ]]; then
  if [[ "$KEY_TYPE" == rsa ]]; then
    KEY_FILE=$SSH_DIR/id_rsa
  else
    KEY_FILE=$SSH_DIR/id_ed25519
  fi
else
  KEY_FILE=$KEY_FILE_RAW
  if [[ "$KEY_FILE" != /* ]]; then
    KEY_FILE=$PWD/$KEY_FILE
  fi
fi
KEY_PUB="$KEY_FILE.pub"

# 注释（邮箱）缺省值：git 全局配置 -> USER@HOSTNAME
if [[ -z "$COMMENT" ]]; then
  COMMENT=$(git config --global user.email 2>/dev/null || true)
  if [[ -z "$COMMENT" ]]; then
    COMMENT="${USER:-$(id -un)}@$(hostname 2>/dev/null || echo localhost)"
  fi
fi

suggest_title() {
  printf '%s@%s %s' "${USER:-$(id -un)}" "$(hostname 2>/dev/null || echo localhost)" "$(date +%F)"
}

# ---------------- 各步骤实现 ----------------
# 确保 ~/.ssh 存在且权限安全（不可被组/其他用户读写执行）
ensure_ssh_dir() {
  if [[ -e "$SSH_DIR" && ! -d "$SSH_DIR" ]]; then
    die "~/.ssh 已存在且不是目录：$SSH_DIR"
  fi
  if [[ ! -d "$SSH_DIR" ]]; then
    mkdir -p -- "$SSH_DIR"
  fi
  local perm
  perm=$(stat -c '%a' "$SSH_DIR")
  if (( (8#$perm & 63) != 0 )); then
    log "修正 ~/.ssh 权限：$perm -> 700"
    chmod 700 "$SSH_DIR"
  fi
}

# --force 覆盖前备份旧密钥（改名而不是删除）
backup_existing_key() {
  local stamp name
  stamp=$(date +%Y%m%d%H%M%S)
  for name in "$KEY_FILE" "$KEY_PUB"; do
    if [[ -e "$name" ]]; then
      mv -- "$name" "${name}.bak.${stamp}"
      log "已备份：$name -> ${name}.bak.${stamp}"
    fi
  done
}

# 非默认路径的密钥：为 github.com 幂等追加 IdentityFile 配置
append_ssh_config() {
  local cfg="$SSH_DIR/config" default_key
  if [[ "$KEY_TYPE" == rsa ]]; then
    default_key=$SSH_DIR/id_rsa
  else
    default_key=$SSH_DIR/id_ed25519
  fi
  # 默认路径的密钥 ssh 会自动尝试，无需写配置
  if [[ "$(realpath -m -- "$KEY_FILE")" == "$(realpath -m -- "$default_key")" ]]; then
    return 0
  fi
  if [[ ! -e "$cfg" ]]; then
    touch -- "$cfg"
    chmod 600 "$cfg"
  fi
  if grep -qF -- "IdentityFile $KEY_FILE" "$cfg" 2>/dev/null; then
    log "~/.ssh/config 已包含该密钥配置，跳过"
    return 0
  fi
  # 文件末尾缺换行时补一个，避免新配置拼到上一行
  if [[ -s "$cfg" && -n "$(tail -c 1 "$cfg")" ]]; then
    printf '\n' >> "$cfg"
  fi
  {
    printf 'Host github.com\n'
    printf '    IdentityFile %s\n' "$KEY_FILE"
  } >> "$cfg"
  log "已在 ~/.ssh/config 为 github.com 添加 IdentityFile 配置：$KEY_FILE"
}

# 已有 ssh-agent 时尝试加入私钥（口令密钥会提示输入口令）
try_ssh_add() {
  if [[ -z "${SSH_AUTH_SOCK:-}" ]]; then
    return 0
  fi
  if ssh-add "$KEY_FILE" >/dev/null 2>&1; then
    log "已把私钥加入当前 ssh-agent"
  else
    log "提示：未能加入 ssh-agent（可能跳过了口令输入），需要时可手动执行 ssh-add '$KEY_FILE'"
  fi
}

# 尽力把公钥复制到剪贴板（X11/Wayland 常见工具依次尝试）
copy_to_clipboard() {
  local pub=$1
  if command -v xclip >/dev/null 2>&1; then
    if xclip -selection clipboard < "$pub" 2>/dev/null; then
      log "公钥已复制到剪贴板（xclip）"
      return 0
    fi
  fi
  if command -v xsel >/dev/null 2>&1; then
    if xsel --clipboard --input < "$pub" 2>/dev/null; then
      log "公钥已复制到剪贴板（xsel）"
      return 0
    fi
  fi
  if command -v wl-copy >/dev/null 2>&1; then
    if wl-copy < "$pub" 2>/dev/null; then
      log "公钥已复制到剪贴板（wl-copy）"
      return 0
    fi
  fi
  return 1
}

# 打印公钥与手动添加指引
print_add_instructions() {
  local pub=$1
  printf '\n==================== SSH 公钥（复制下面整行） ====================\n'
  cat -- "$pub"
  printf '==================================================================\n'
  copy_to_clipboard "$pub" || true
  printf '手动添加步骤：\n'
  printf '  1. 打开 https://github.com/settings/ssh/new\n'
  printf '  2. Title 填写：%s\n' "$(suggest_title)"
  printf '  3. Key 粘贴上面公钥整行，点击 Add SSH key 保存\n'
  printf '  4. 运行 %s --test 验证授权\n' "$SCRIPT_NAME"
}

# 检测已登录的 gh 时自动上传公钥；不可用返回非 0（转手动指引）
try_gh_upload() {
  local pub=$1 title out
  if [[ "$NO_GH" == true ]]; then
    log "按 --no-gh 跳过 gh 自动上传"
    return 1
  fi
  if ! command -v gh >/dev/null 2>&1; then
    log "未检测到 gh 命令行工具，请手动添加公钥"
    return 1
  fi
  if ! gh auth status >/dev/null 2>&1; then
    log "gh 未登录（可先 gh auth login），请手动添加公钥"
    return 1
  fi
  title=$(suggest_title)
  log "检测到已登录的 gh，尝试自动上传公钥（Title: $title）"
  if out=$(gh ssh-key add "$pub" -t "$title" 2>&1); then
    log "公钥已通过 gh 自动上传到 GitHub"
    return 0
  fi
  log "gh 自动上传失败：$out"
  return 1
}

# ---------------- 三种模式的入口 ----------------
do_generate() {
  ensure_ssh_dir

  if [[ -e "$KEY_FILE" || -e "$KEY_PUB" ]]; then
    if [[ "$FORCE" != true ]]; then
      die "密钥已存在：$KEY_FILE
如需验证已有密钥请用 --test；确认覆盖请加 --force（旧密钥会自动备份）。"
    fi
    backup_existing_key
  fi

  local -a args=(-t "$KEY_TYPE" -C "$COMMENT" -f "$KEY_FILE")
  if [[ "$KEY_TYPE" == rsa ]]; then
    args+=(-b "$RSA_BITS")
  fi
  if [[ "$NO_PASSPHRASE" == true ]]; then
    args+=(-N '')
  fi

  log "生成密钥：类型=$KEY_TYPE 注释=$COMMENT 路径=$KEY_FILE"
  if ! ssh-keygen "${args[@]}"; then
    die "ssh-keygen 生成失败"
  fi
  [[ -f "$KEY_FILE" && -f "$KEY_PUB" ]] || die "内部错误：密钥文件生成不完整"

  chmod 600 "$KEY_FILE"
  chmod 644 "$KEY_PUB"
  log "密钥指纹：$(ssh-keygen -lf "$KEY_PUB")"

  append_ssh_config
  try_ssh_add
  if ! try_gh_upload "$KEY_PUB"; then
    print_add_instructions "$KEY_PUB"
  fi

  printf '\n后续提示：\n'
  printf '  - 验证授权：%s --test\n' "$SCRIPT_NAME"
  printf '  - Git 使用 SSH 远程形式：git@github.com:<user>/<repo>.git\n'
}

do_print() {
  [[ -f "$KEY_PUB" ]] || die "未找到公钥：$KEY_PUB（请先生成，或用 -f 指定密钥路径）"
  print_add_instructions "$KEY_PUB"
}

do_test() {
  [[ -f "$KEY_FILE" ]] || die "未找到私钥：$KEY_FILE（请先生成，或用 -f 指定密钥路径）"

  local out rc=0
  log "测试 GitHub SSH 授权（git@github.com，使用密钥：$KEY_FILE）……"
  # GitHub 对成功认证也返回退出码 1，因此以输出内容判断结果；
  # -F none 不读用户 ssh 配置，确保只验证指定密钥本身，
  # 避免用户配置中其他 github.com 密钥“代为认证”造成误判
  out=$(ssh -F none -i "$KEY_FILE" -o IdentitiesOnly=yes \
             -o StrictHostKeyChecking=accept-new -o ConnectTimeout=15 \
             -T git@github.com 2>&1) || rc=$?
  if grep -q 'successfully authenticated' <<<"$out"; then
    local who='(未知用户)'
    if [[ "$out" =~ Hi\ ([^!]+)! ]]; then
      who=${BASH_REMATCH[1]}
    fi
    log "授权成功：$who"
    log "$out"
    return 0
  fi
  die "GitHub SSH 授权失败（ssh 退出码 $rc）：
$out
排查建议：
  1) 确认公钥已添加到 GitHub（https://github.com/settings/keys）；
  2) 私钥若有口令，确认已通过 ssh-add 加入 agent 或正确输入；
  3) 确认测试的是正确的密钥（-f 指定路径）。"
}

case "$MODE" in
  generate) do_generate ;;
  print)    do_print ;;
  test)     do_test ;;
esac

log "完成"
