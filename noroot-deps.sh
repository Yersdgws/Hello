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
#
#  装完导出的变量（或写入 ~/.bashrc）:
#     export XROOT="$HOME/xroot"
#     export LD_LIBRARY_PATH="$XROOT/usr/lib/x86_64-linux-gnu:$XROOT/usr/lib:$LD_LIBRARY_PATH"
#     export PATH="$XROOT/usr/bin:$PATH"
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

# X server + x11vnc + 浏览器需要的库（Debian/Ubuntu 包名）
PACKAGES="xvfb x11vnc xauth x11-xkb-utils x11-utils fontconfig \
          libx11-6 libxext6 libxtst6 libxi6 libxrender1 libxft2 libxdamage1 \
          libasound2 libdbus-glib-1-2 libgtk-3-0 libgdk-pixbuf-2.0-0 libglib2.0-0 \
          libpango-1.0-0 libcairo2 libnspr4 libnss3 libpci3 libdrm2 libxfixes3"

# ---------- 阶段1: 用系统已有的 apt 包列表下载（无 root 也可以读列表） ----------
MISSING_DEBS=""
down_system() {
    for p in $PACKAGES; do
        if apt-get download "$p" >/dev/null 2>&1; then
            echo "  ok  $p"
        else
            echo "  miss $p"; MISSING_DEBS="$MISSING_DEBS $p"
        fi
    done
}

# ---------- 阶段2：非 root 兜底 ----------
#   把 apt 的 lists/cache 目录指到临时目录（不碰 /var，无需 root），
#   临时写一个 Debian bookworm 源（[trusted=yes] 跳过 GPG 校验）。
#   适用：容器里系统源可能没更新过包列表 / 或源本身访问不了。
fallback_bookworm() {
    local A="$TMP/apt"
    mkdir -p "$A/lists/partial" "$A/cache/archives/partial"
    echo "deb [trusted=yes] http://deb.debian.org/debian bookworm main" > "$A/sources.list"
    local OPTS=(
        -o "Dir::State::lists=$A/lists"
        -o "Dir::Cache=$A/cache"
        -o "Dir::Etc::sourcelist=$A/sources.list"
        -o "Dir::Etc::sourceparts=-"
        -o "APT::Get::List-Cleanup=0"
    )
    echo "  非 root 更新 Debian bookworm 源..."
    apt-get "${OPTS[@]}" update >/dev/null 2>&1 || { echo "  apt update 失败"; return 1; }
    # 只补缺的包
    for p in $MISSING_DEBS; do
        if apt-get "${OPTS[@]}" download "$p" >/dev/null 2>&1; then
            echo "  ok  $p (bookworm)"
        else
            echo "  miss $p"
        fi
    done
}

cd "$TMP"
log_info "阶段1：用系统 apt 源下载..."
down_system
if [[ -n "$MISSING_DEBS" ]]; then
    log_warn "阶段1 缺:${MISSING_DEBS}，进入阶段2（非 root bookworm 源）..."
    if ! fallback_bookworm; then
        cat >&2 <<'EOD'
[ERROR] apt update 也失败（多半 deb.debian.org 访问不了/被墙）。
请在你的目标机器上手动诊断：
    cat /etc/os-release
    printf 'deb [trusted=yes] http://deb.debian.org/debian bookworm main\n' > /tmp/s.list
    apt-get -o Dir::State::lists=/tmp/l -o Dir::Etc::sourcelist=/tmp/s.list update
    curl -sI http://deb.debian.org/debian/dists/bookworm/Release | head -1
    # 若有代理: export http_proxy=http://host:port https_proxy=... 再重跑
EOD
        exit 1
    fi
fi

# ---------- 解包 ----------
FOUND=0
for f in *.deb; do
    [[ -f "$f" ]] || continue
    dpkg-deb -x "$f" "$PREFIX" 2>/dev/null && FOUND=1
done
[[ "$FOUND" = "0" ]] && log_error "仍然没有下到任何 .deb，请检查网络/代理"

# ---------- 整理库目录并给提示 ----------
LIBDIR=$(find "$PREFIX/usr/lib" -maxdepth 1 -type d -name '*linux-gnu' | head -1)
[[ -z "$LIBDIR" ]] && LIBDIR="$PREFIX/usr/lib"
echo
echo -e "${GREEN}=========== 安装完成 ===========${NC}"
echo "前缀目录 : $PREFIX"
echo "二进制   : $PREFIX/usr/bin/{Xvfb,x11vnc,...}"
echo "库目录   : $LIBDIR"
echo
echo "# 加入 ~/.bashrc 后 source:"
echo "export LD_LIBRARY_PATH=\"$LIBDIR:$PREFIX/usr/lib:\$LD_LIBRARY_PATH\""
echo "export PATH=\"$PREFIX/usr/bin:\$PATH\""
echo
echo "# 然后这样启动 firefox-tunnel.sh:"
echo "XVFB_BIN=\"$PREFIX/usr/bin/Xvfb\" \\"
echo "X11VNC_BIN=\"$PREFIX/usr/bin/x11vnc\" \\"
echo "PYTHON3_BIN=\"\$(command -v python3)\" \\"
echo "bash firefox-tunnel.sh"
echo
echo "若 ldd 报缺 .so，把对应包名加进本脚本 PACKAGES 重跑即可。"
