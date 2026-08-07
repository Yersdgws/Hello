#!/bin/bash
set -e

# =====================================================================
#  无 root 环境安装 Xvfb / x11vnc / python3 依赖（解包 .deb 到用户目录）
#
#  原理: apt-get download（不需要 root，只要有网络和 apt 仓库）
#        + dpkg-deb -x 解包到 $HOME/xroot
#        + 运行时代码通过 LD_LIBRARY_PATH 指向解包出的库
#
#  适用: SAP BAS / 各类无 sudo 的云开发容器（Debian/Ubuntu 系）
#
#  用法:
#     bash noroot-deps.sh                 # 装到 ~/xroot
#     bash noroot-deps.sh --no-firefox    # 不额外下载 firefox 的 GTK 相关库
#
#  装完导出的变量（或写入 ~/.bashrc）:
#     export XROOT="$HOME/xroot"
#     export PATH="$XROOT/usr/bin:$PATH"
#     export LD_LIBRARY_PATH="$XROOT/usr/lib/x86_64-linux-gnu:$XROOT/usr/lib:$LD_LIBRARY_PATH"
#  然后在 firefox-tunnel.sh 里用:  XVFB_BIN=~/xroot/usr/bin/Xvfb ...
# =====================================================================

# ---------- 日志 ----------
GREEN='\033[0;32m'; YELLOW='\033[1;33m'; RED='\033[0;31m'; NC='\033[0m'
log_info()  { echo -e "${GREEN}[INFO]${NC} $1"; }
log_warn()  { echo -e "${YELLOW}[WARN]${NC} $1"; }
log_error() { echo -e "${RED}[ERROR]${NC} $1" >&2; exit 1; }

PREFIX="${XROOT:-$HOME/xroot}"
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
mkdir -p "$PREFIX"

# X server + x11vnc + 常见浏览器需要的库（按 Debian/Ubuntu 包名）
PACKAGES="xvfb x11vnc xauth x11-xkb-utils x11-utils fontconfig \
          libx11-6 libxext6 libxtst6 libxi6 libxrender1 libxft2 libxdamage1 \
          libasound2 libdbus-glib-1-2 libgtk-3-0 libgdk-pixbuf-2.0-0 libglib2.0-0 \
          libpango-1.0-0 libcairo2 libnspr4 libnss3 libpci3 libdrm2 libxfixes3"

# 可选：xkbcomp 有时独立为 x11-xkb-utils
command -v xkbcomp >/dev/null 2>&1 || PACKAGES="$PACKAGES x11-xkb-utils"

cd "$TMP"
log_info "下载并解包依赖到 $PREFIX ..."
for p in $PACKAGES; do
    # 有些包可能不存在于当前发行版，允许失败跳过
    apt-get download "$p" >/dev/null 2>&1 && log_info "  ok  $p" || echo "  skip $p"
done

FOUND=0
for f in *.deb; do
    [[ -f "$f" ]] || continue
    dpkg-deb -x "$f" "$PREFIX" 2>/dev/null && FOUND=1
done

[[ "$FOUND" = "0" ]] && log_error "没有下到任何 .deb，检查网络/apt 仓库"

# 整理架构 lib 目录（x86_64/aarch64）
LIBDIR=$(find "$PREFIX/usr/lib" -maxdepth 1 -type d -name '*linux-gnu' | head -1)
[[ -z "$LIBDIR" ]] && LIBDIR="$PREFIX/usr/lib"

cat <<EOF

${GREEN}================ 安装完成 ================${NC}
前缀目录 : $PREFIX
二进制   : $PREFIX/usr/bin/{Xvfb,x11vnc,...}
库目录   : $LIBDIR

# 把下面加入 ~/.bashrc，然后 source ~/.bashrc：
export LD_LIBRARY_PATH="$LIBDIR:$PREFIX/usr/lib:\$LD_LIBRARY_PATH"
export PATH="$PREFIX/usr/bin:\$PATH"

# 然后在 firefox-tunnel.sh 里这样指定（替代系统 PATH 查找）:
XVFB_BIN="$PREFIX/usr/bin/Xvfb" \\
X11VNC_BIN="$PREFIX/usr/bin/x11vnc" \\
PYTHON3_BIN="\$(command -v python3)" \\
bash firefox-tunnel.sh

若报缺少某个 .so：用 ldd 上面两个二进制看缺什么，
再把对应 Debian/Ubuntu 包名加进本脚本 PACKAGES 重跑一遍即可。
EOF