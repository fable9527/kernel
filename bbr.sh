#!/usr/bin/env bash
# bbr.sh — 精简版：安装 Cloud BBR 内核 / 清理旧内核 / 开启 BBR+FQ
# 内核来源: https://github.com/fable9527/kernel (fork of ylx2016/kernel)
# 支持: Debian 10+ / Ubuntu 20.04+  x86_64
#   上游 Debian_Kernel_Cloud_* 的 deb 同时适用于 Debian 和 Ubuntu（上游已不再单独出 Ubuntu 包）
# 用法:
#   bash bbr.sh                       交互菜单
#   bash bbr.sh install               直接安装最新内核，装完询问是否重启（回车=重启）
#   REBOOT=no  bash bbr.sh install    装完不询问、不重启（批量用）
#   REBOOT=yes bash bbr.sh install    装完不询问、直接重启
#   BBR_TAG=Debian_Kernel_Cloud_7.2_bbr_2026.08.25-0436 bash bbr.sh install   指定版本
#   KEEP_META=1 bash bbr.sh install   保留发行版内核元包（默认卸掉，防止 apt 把官方内核装回来）
#   FORCE=1 bash bbr.sh install       Secure Boot 开启时也强制安装
#   GITHUB_TOKEN=ghp_xxx bash bbr.sh  可选，避免 API 限速
set -o pipefail

REPO="${REPO:-fable9527/kernel}"
FALLBACK_REPO="ylx2016/kernel"
TAG_PATTERN="${TAG_PATTERN:-Debian_Kernel_Cloud_}"
KEEP_META="${KEEP_META:-0}"
REBOOT="${REBOOT:-ask}"
FORCE="${FORCE:-0}"

G="\033[32m"; R="\033[31m"; Y="\033[33m"; N="\033[0m"
info()  { echo -e "${G}[信息]${N} $*"; }
warn()  { echo -e "${Y}[警告]${N} $*"; }
err()   { echo -e "${R}[错误]${N} $*" >&2; }
die()   { err "$*"; exit 1; }

[ "$EUID" -eq 0 ] || die "请用 root 运行"
. /etc/os-release
case "$ID" in
  debian|ubuntu) ;;
  *) case "$ID_LIKE" in *debian*|*ubuntu*) ;; *) die "只支持 Debian/Ubuntu，当前: $ID" ;; esac ;;
esac
[ "$(uname -m)" = "x86_64" ] || die "只支持 x86_64"
OS_NAME="$PRETTY_NAME"

# ---------- 依赖 ----------
need_tools() {
  local miss=()
  command -v curl >/dev/null || miss+=(curl)
  command -v wget >/dev/null || miss+=(wget)
  [ ${#miss[@]} -eq 0 ] && return
  info "安装依赖: ${miss[*]}"
  apt-get update -qq
  DEBIAN_FRONTEND=noninteractive apt-get install -y -qq "${miss[@]}" || die "依赖安装失败: ${miss[*]}"
}

# ---------- Secure Boot 检查（自编译内核未签名，SB 开启会起不来） ----------
check_secureboot() {
  local f; f=$(ls /sys/firmware/efi/efivars/SecureBoot-* 2>/dev/null | head -n1)
  [ -n "$f" ] || return 0
  local sb; sb=$(od -An -tu1 -j4 -N1 "$f" 2>/dev/null | tr -d ' ')
  if [ "$sb" = "1" ]; then
    err "检测到 Secure Boot 已开启，未签名内核无法启动"
    [ "$FORCE" = "1" ] || die "请先在 BIOS/面板关闭 Secure Boot，或 FORCE=1 强制继续"
    warn "FORCE=1，继续安装"
  fi
}

# ---------- GitHub API ----------
api() {
  local h=(-s -H 'Accept: application/vnd.github+json')
  [ -n "$GITHUB_TOKEN" ] && h+=(-H "Authorization: Bearer $GITHUB_TOKEN")
  curl "${h[@]}" "https://api.github.com/repos/$1/releases?per_page=100"
}

# 取 tag / image / headers URL，写入全局变量
resolve_release() {
  local repo="$1" json
  json=$(api "$repo") || return 1
  echo "$json" | grep -q 'rate limit' && die "GitHub API 限速，设置 GITHUB_TOKEN 或稍后再试"
  if [ -n "$BBR_TAG" ]; then
    TAG="$BBR_TAG"
  else
    TAG=$(echo "$json" | grep '"tag_name"' | grep "$TAG_PATTERN" | head -n1 | awk -F'"' '{print $4}')
  fi
  [ -n "$TAG" ] || return 1
  IMG=$(echo "$json" | grep browser_download_url | grep "/$TAG/" | grep 'linux-image-' | grep -v dbg | head -n1 | awk -F'"' '{print $4}')
  HDR=$(echo "$json" | grep browser_download_url | grep "/$TAG/" | grep 'linux-headers-' | head -n1 | awk -F'"' '{print $4}')
  [ -n "$IMG" ] && [ -n "$HDR" ] || return 1
  # 用 deb 文件名里的版本号（7.2.0），不用 tag 里的（7.2），避免显示不一致
  KVER=$(basename "$IMG" | sed -E 's/^linux-image-([0-9][0-9.]*).*/\1/')
  [ -n "$KVER" ] || KVER=$(echo "$TAG" | sed -E 's/^Debian_Kernel_Cloud_([0-9.]+)_.*/\1/')
}

# ---------- 清理旧内核 ----------
# $1 = headers | image
#   headers: linux-headers-*
#   image  : linux-image-* linux-modules-* 以及 Ubuntu 的 linux-generic / linux-virtual / *-hwe-* 元包
purge_old() {
  local re pkgs
  case "$1" in
    headers) re='^linux-headers-' ;;
    image)   re='^linux-(image|modules|generic|virtual|lowlatency|kvm|cloud)' ;;
  esac
  pkgs=$(dpkg -l | awk '/^[ih]i/{print $2}' | grep -E "$re" | grep -v -- "$KVER")
  if [ "$KEEP_META" = "1" ]; then
    # Debian: linux-image-amd64 linux-image-cloud-amd64 linux-headers-amd64
    # Ubuntu: linux-generic linux-virtual linux-image-generic linux-headers-generic linux-*-hwe-*
    pkgs=$(echo "$pkgs" | grep -vE '^linux-(image|headers)-(amd64|cloud-amd64|rt-amd64)$|^linux-(generic|virtual|kvm|lowlatency)|^linux-(image|headers)-(generic|virtual|kvm|lowlatency)|hwe-')
  fi
  pkgs=$(echo "$pkgs" | sed '/^$/d')
  [ -n "$pkgs" ] || { info "没有多余的 $1 包"; return; }
  info "卸载: $(echo $pkgs | tr '\n' ' ')"
  # 允许卸掉正在运行的内核（Debian/Ubuntu 的 linux-base 默认会中止）
  echo "linux-base linux-base/removing-running-kernel boolean false" | debconf-set-selections 2>/dev/null
  DEBIAN_FRONTEND=noninteractive apt-get purge -y $pkgs
  # 别让 autoremove 顺手把 firmware 删了
  dpkg -l linux-firmware >/dev/null 2>&1 && apt-mark manual linux-firmware >/dev/null 2>&1
  DEBIAN_FRONTEND=noninteractive apt-get autoremove --purge -y
}

# ---------- BBR ----------
enable_bbr() {
  cat > /etc/sysctl.d/99-bbr.conf <<EOF
net.core.default_qdisc=fq
net.ipv4.tcp_congestion_control=bbr
EOF
  sysctl --system >/dev/null 2>&1
  info "sysctl 已写入 /etc/sysctl.d/99-bbr.conf  当前: $(sysctl -n net.ipv4.tcp_congestion_control) + $(sysctl -n net.core.default_qdisc)"
}

# ---------- 重启 ----------
ask_reboot() {
  case "$REBOOT" in
    yes) info "REBOOT=yes，正在重启..."; reboot ;;
    no)  info "REBOOT=no，请稍后手动 reboot" ;;
    *)
      echo
      read -rp "需要重启 VPS 后新内核和 BBR 才生效，是否现在重启? [Y/n]: " ans
      case "$ans" in
        n|N|no|NO) info "已跳过，请稍后手动 reboot" ;;
        *) info "正在重启..."; sleep 1; reboot ;;
      esac ;;
  esac
}

# ---------- 安装 ----------
install_kernel() {
  info "系统: $OS_NAME"
  check_secureboot
  need_tools
  DEBIAN_FRONTEND=noninteractive apt-get --fix-broken install -y >/dev/null 2>&1

  info "查询 $REPO ..."
  if ! resolve_release "$REPO"; then
    err "$REPO 没有匹配 $TAG_PATTERN 的 Release，回退到 $FALLBACK_REPO"
    resolve_release "$FALLBACK_REPO" || die "两个仓库都没找到可用 Release"
  fi
  info "版本: ${G}$KVER${N}  tag: $TAG"
  echo "  image  : $IMG"
  echo "  headers: $HDR"

  if [ "$(uname -r)" = "$KVER" ]; then
    warn "当前已在运行 $KVER，只做清理 + 开启 BBR"
    purge_old headers; purge_old image; update-grub
    enable_bbr
    return
  fi

  local d; d=$(mktemp -d); cd "$d" || exit 1
  wget -q --show-progress -O image.deb   "$IMG" || die "下载 image 失败"
  wget -q --show-progress -O headers.deb "$HDR" || die "下载 headers 失败"

  purge_old headers
  DEBIAN_FRONTEND=noninteractive dpkg -i image.deb headers.deb || DEBIAN_FRONTEND=noninteractive apt-get -f install -y
  dpkg -l "linux-image-$KVER" 2>/dev/null | grep -q '^ii' || die "新内核 $KVER 没装上，旧内核未动，不要重启"
  purge_old image
  cd / && rm -rf "$d"

  update-grub
  enable_bbr
  echo
  info "已安装内核列表（rescue 不算）:"
  ls /boot/vmlinuz-* | sed 's|/boot/vmlinuz-|  |'
  if ls /boot/vmlinuz-"$KVER"* >/dev/null 2>&1; then
    info "发现内核文件 /boot/vmlinuz-$KVER，看起来可以重启"
    ask_reboot
  else
    die "/boot 里没有 $KVER，千万别重启，先排查上面的报错"
  fi
}

# ---------- 状态 / 菜单 ----------
status() {
  echo -e " 系统: $OS_NAME"
  echo -e " 内核: $(uname -r)"
  echo -e " 拥塞控制: $(sysctl -n net.ipv4.tcp_congestion_control)   队列: $(sysctl -n net.core.default_qdisc)"
  echo -e " 已装内核: $(dpkg -l | awk '/^ii  linux-image-[0-9]/{print $2}' | sed 's/linux-image-//' | tr '\n' ' ')"
}

clean_only() {
  KVER=$(uname -r)
  purge_old headers; purge_old image; update-grub
}

menu() {
  echo "————————————————————————————————"
  echo " 1. 安装最新 Cloud BBR 内核 (自动清理旧内核 + 开启 BBR，完成后重启)"
  echo " 2. 只开启 BBR + FQ"
  echo " 3. 只清理旧内核 (保留当前运行的)"
  echo " 0. 退出"
  echo "————————————————————————————————"
  status
  read -rp " 请输入数字: " n
  case "$n" in
    1) install_kernel ;;
    2) enable_bbr ;;
    3) clean_only ;;
    0) exit 0 ;;
    *) die "无效输入" ;;
  esac
}

case "$1" in
  install) install_kernel ;;
  bbr)     enable_bbr ;;
  clean)   clean_only ;;
  status)  status ;;
  *)       menu ;;
esac
