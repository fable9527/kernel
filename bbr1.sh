#!/usr/bin/env bash
# bbr.sh — 精简版：安装 Cloud BBR 内核 / 清理旧内核 / 开启 BBR+FQ
# 内核来源: https://github.com/fable9527/kernel (fork of ylx2016/kernel)
# 用法:
#   bash bbr.sh                       交互菜单
#   bash bbr.sh install               直接安装最新内核
#   BBR_TAG=Debian_Kernel_Cloud_6.16.4_bbr_2026.08.25-0530 bash bbr.sh install   指定版本
#   KEEP_META=1 bash bbr.sh install   保留 linux-image-amd64 元包(默认卸掉，和原脚本一致)
#   GITHUB_TOKEN=ghp_xxx bash bbr.sh  可选，避免 API 限速
set -o pipefail

REPO="${REPO:-fable9527/kernel}"
FALLBACK_REPO="ylx2016/kernel"
TAG_PATTERN="${TAG_PATTERN:-Debian_Kernel_Cloud_}"
KEEP_META="${KEEP_META:-0}"

G="\033[32m"; R="\033[31m"; N="\033[0m"
info()  { echo -e "${G}[信息]${N} $*"; }
err()   { echo -e "${R}[错误]${N} $*" >&2; }
die()   { err "$*"; exit 1; }

[ "$EUID" -eq 0 ] || die "请用 root 运行"
. /etc/os-release
case "$ID" in debian|ubuntu) ;; *) die "只支持 Debian/Ubuntu，当前: $ID" ;; esac
[ "$(uname -m)" = "x86_64" ] || die "只支持 x86_64"

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
  KVER=$(echo "$TAG" | sed -E 's/^Debian_Kernel_Cloud_([0-9.]+)_.*/\1/')
  IMG=$(echo "$json" | grep browser_download_url | grep "/$TAG/" | grep 'linux-image-' | grep -v dbg | head -n1 | awk -F'"' '{print $4}')
  HDR=$(echo "$json" | grep browser_download_url | grep "/$TAG/" | grep 'linux-headers-' | head -n1 | awk -F'"' '{print $4}')
  [ -n "$IMG" ] && [ -n "$HDR" ]
}

purge_old() {
  # $1 = image|headers ; 卸掉所有不含 $KVER 的包
  local pat="linux-$1" pkgs
  pkgs=$(dpkg -l | awk '/^ii/{print $2}' | grep "^$pat" | grep -v "$KVER")
  if [ "$KEEP_META" = "1" ]; then
    pkgs=$(echo "$pkgs" | grep -vE "^linux-(image|headers)-(amd64|cloud-amd64)$")
  fi
  [ -n "$pkgs" ] || { info "没有多余的 $pat 包"; return; }
  info "卸载: $(echo $pkgs | tr '\n' ' ')"
  DEBIAN_FRONTEND=noninteractive apt-get purge -y $pkgs
  apt-get autoremove -y
}

install_kernel() {
  apt-get --fix-broken install -y >/dev/null
  info "查询 $REPO ..."
  if ! resolve_release "$REPO"; then
    err "$REPO 没有匹配 $TAG_PATTERN 的 Release，回退到 $FALLBACK_REPO"
    resolve_release "$FALLBACK_REPO" || die "两个仓库都没找到可用 Release"
  fi
  info "版本: ${G}$KVER${N}  tag: $TAG"
  echo "  image  : $IMG"
  echo "  headers: $HDR"

  local d; d=$(mktemp -d); cd "$d" || exit 1
  wget -q --show-progress -O image.deb   "$IMG" || die "下载 image 失败"
  wget -q --show-progress -O headers.deb "$HDR" || die "下载 headers 失败"

  purge_old headers
  dpkg -i image.deb headers.deb || apt-get -f install -y
  purge_old image
  cd / && rm -rf "$d"

  update-grub
  echo
  info "已安装内核列表（rescue 不算）:"
  ls /boot/vmlinuz-* | sed 's|/boot/vmlinuz-|  |'
  echo -e "${R}请确认上面有 $KVER，没有千万别重启${N}"
  info "重启后运行: bash bbr.sh bbr"
}

enable_bbr() {
  cat > /etc/sysctl.d/99-bbr.conf <<EOF
net.core.default_qdisc=fq
net.ipv4.tcp_congestion_control=bbr
EOF
  sysctl --system >/dev/null
  info "当前: $(sysctl -n net.ipv4.tcp_congestion_control) + $(sysctl -n net.core.default_qdisc)"
}

status() {
  echo -e " 内核: $(uname -r)"
  echo -e " 拥塞控制: $(sysctl -n net.ipv4.tcp_congestion_control)   队列: $(sysctl -n net.core.default_qdisc)"
  echo -e " 已装内核: $(dpkg -l | awk '/^ii  linux-image-[0-9]/{print $2}' | sed 's/linux-image-//' | tr '\n' ' ')"
}

menu() {
  echo "————————————————————————————————"
  echo " 1. 安装最新 Cloud BBR 内核 (自动清理旧内核)"
  echo " 2. 开启 BBR + FQ"
  echo " 3. 只清理旧内核 (保留当前运行的)"
  echo " 0. 退出"
  echo "————————————————————————————————"
  status
  read -rp " 请输入数字: " n
  case "$n" in
    1) install_kernel ;;
    2) enable_bbr ;;
    3) KVER=$(uname -r); purge_old image; purge_old headers; update-grub ;;
    0) exit 0 ;;
    *) die "无效输入" ;;
  esac
}

case "$1" in
  install) install_kernel ;;
  bbr)     enable_bbr ;;
  clean)   KVER=$(uname -r); purge_old image; purge_old headers; update-grub ;;
  *)       menu ;;
esac
