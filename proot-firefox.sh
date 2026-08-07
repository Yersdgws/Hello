#!/bin/bash
set -e

# =====================================================================
#  proot-firefox.sh — BAS/无 root 环境的 Debian 容器内跑 Firefox
#
#  思路（"走 B（BAS）"方案）：
#    用 proot -R 把一个 Debian rootfs 变成"用户态容器"：
#      * 容器内你就是 root → apt-get install firefox 干净安装
#      * 不再需要 LD_LIBRARY_PATH 拼图 / xroot 解包 / GTK 缺失等 hack
#      * 容器内跑 Xvfb + x11vnc + firefox；宿主侧用已有 noVNC + cloudflared 隧道
#
#  数据流：
#    浏览器 → cloudflared 隧道域名 → 宿主 noVNC(:6080) → websockify
#            → 容器内 x11vnc(:5900) → Xvfb(:99) → 容器内 firefox
#
#  用法:
#    bash proot-firefox.sh provision     # 首次: 下载 proot + Debian rootfs + 容器内 apt 安装
#    bash proot-firefox.sh start         # 启动（自动 provision；= 默认参数）
#    bash proot-firefox.sh enter         # 进入容器交互 shell（你是 root）
#    bash proot-firefox.sh status        # 查看状态
#    bash proot-firefox.sh stop          # 停止全部
#    bash proot-firefox.sh --dry-run     # 只打印将要生成的脚本内容
#
#  隧道参数（与 gotty.sh / firefox-tunnel.sh 一致）:
#    ARGO_DOMAIN=xxx.trycloudflare.com ARGO_AUTH=Token \
#    VNC_PASSWORD=123456 ARGO_PORT=8080 bash proot-firefox.sh start
#
#  可调环境变量:
#    PROOTFS_DIR=~/prootfs       rootfs 位置（注意磁盘空间，需 >1.5G）
#    PROOT_BIN=                  proot 二进制（默认自动找/下载）
#    NOVNC_DIR=~/noVNC           noVNC 网页目录（宿主侧，默认自动下载）
#    CF_BIN=~/cloudflared        cloudflared 路径
#    XROOT=~/xroot               已有 noroot-deps 目录（proot 从这里复用）
#    FIREFOX_FONTS="fonts-liberation fonts-noto-cjk"   额外中文字体
# =====================================================================

# ---------- 颜色与日志 ----------
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BLUE='\033[0;34m'; NC='\033[0m'
log_info()  { echo -e "${GREEN}[INFO]${NC} $1"; }
log_warn()  { echo -e "${YELLOW}[WARN]${NC} $1"; }
log_error() { echo -e "${RED}[ERROR]${NC} $1" >&2; exit 1; }
log_url()   { echo -e "${BLUE}[URL]${NC} $1"; }

# ---------- 可配置参数 ----------
export ARGO_PORT=${ARGO_PORT:-'8080'}      # noVNC 网页端口（宿主本地）
export ARGO_DOMAIN=${ARGO_DOMAIN:-''}      # 固定隧道域名（空=临时隧道）
export ARGO_AUTH=${ARGO_AUTH:-''}          # 固定隧道 Token / TunnelSecret JSON
export VNC_PASSWORD=${VNC_PASSWORD:-''}    # VNC 密码（空=无密码）
export VNC_PORT=${VNC_PORT:-'5900'}        # 容器内 x11vnc 端口
export DISPLAY_NUM=${DISPLAY_NUM:-':99'}   # 虚拟显示号
export PROOTFS_DIR=${PROOTFS_DIR:-"$HOME/prootfs"}
export XROOT=${XROOT:-"$HOME/xroot"}
export PROOT_BIN=${PROOT_BIN:-''}
export PTOOLS=${PTOOLS:-"$HOME/proot-tools"}
export NOVNC_DIR=${NOVNC_DIR:-"$HOME/noVNC"}
export CF_BIN=${CF_BIN:-"$HOME/cloudflared"}
export FIREFOX_FONTS=${FIREFOX_FONTS:-"fonts-liberation"}
export DEBIAN_SUITE=${DEBIAN_SUITE:-'bookworm'}
export DISK_WARN_MB=${DISK_WARN_MB:-1500}

DRY_RUN=0
CMD="start"
for a in "$@"; do
  case "$a" in
    --dry-run) DRY_RUN=1 ;;
    provision|start|enter|stop|status) CMD="$a" ;;
  esac
done

# ---------- 架构/系统 ----------
detect_arch() {
    case $(uname -m) in
        x86_64|amd64)  echo "amd64" ;;
        aarch64|arm64) echo "arm64" ;;
        *) log_error "不支持的架构: $(uname -m)（proot 容器方案仅 x86_64/aarch64）" ;;
    esac
}

# ---------- 下载工具 ----------
download_file() {
    local url="$1" output="$2"
    [[ -f "$output" ]] && return 0
    log_info "下载: $url"
    curl -fsSL --retry 3 --retry-delay 2 -o "$output" "$url" || log_error "下载失败: $url"
}

# =====================================================================
#  1. proot + libtalloc2（无 root，用 apt-get download + 解包）
# =====================================================================
find_proot() {
    # 解析顺序: PROOT_BIN > PATH > ~/xroot/usr/bin/proot > ~/proot-tools
    if [[ -n "$PROOT_BIN" && -x "$PROOT_BIN" ]]; then return 0; fi
    if command -v proot >/dev/null 2>&1; then PROOT_BIN=$(command -v proot); return 0; fi
    if [[ -x "$XROOT/usr/bin/proot" ]]; then PROOT_BIN="$XROOT/usr/bin/proot"; return 0; fi
    if [[ -x "$PTOOLS/usr/bin/proot" ]]; then PROOT_BIN="$PTOOLS/usr/bin/proot"; return 0; fi
    return 1
}

proot_lib_path() {
    # 找 libtalloc.so.2（proot 运行时依赖）
    local d
    for d in "$PTOOLS/usr/lib/x86_64-linux-gnu" "$PTOOLS/usr/lib/aarch64-linux-gnu" \
             "$XROOT/usr/lib/x86_64-linux-gnu" "$XROOT/usr/lib/aarch64-linux-gnu" \
             /usr/lib/x86_64-linux-gnu /usr/lib/aarch64-linux-gnu; do
        if [[ -f "$d/libtalloc.so.2" ]]; then echo "$d"; return 0; fi
    done
    return 1
}

install_proot() {
    log_info "安装 proot + libtalloc2 到 $PTOOLS ..."
    mkdir -p "$PTOOLS"
    local tmp; tmp=$(mktemp -d)
    local got=0

    # 方式1: 系统 apt 源（BAS/Ubuntu 常见问题: 缺 universe 或列表过期 → 自动方式2）
    log_info "尝试 apt-get download ..."
    if ( cd "$tmp" && apt-get download proot libtalloc2 >"$tmp/apt.log" 2>&1 ); then
        got=1
    else
        log_warn "apt-get download 失败，改用 Debian pool 直连下载（无需 apt 源配置）"
        log_warn "原因: $(tail -1 "$tmp/apt.log" 2>/dev/null)"
        # 先试一次 apt-get update 再重试（列表过期场景）
        if ( cd "$tmp" && apt-get update -qq >/dev/null 2>&1 && apt-get download proot libtalloc2 >"$tmp/apt.log" 2>&1 ); then
            got=1
        fi
    fi

    # 方式2: 直连 deb.debian.org pool（绕过 apt 仓库配置，任何 Debian 系都能用）
    if [[ "$got" = "0" ]]; then
        local arch; arch=$(detect_arch)
        local base="http://deb.debian.org/debian/pool/main"
        local urls=(
            "$base/p/proot/proot_5.1.0-1.3_${arch}.deb"
            "$base/t/talloc/libtalloc2_2.4.0-f2_${arch}.deb"
        )
        for u in "${urls[@]}"; do
            log_info "直连下载: $u"
            curl -fsSL --retry 3 --retry-delay 2 -o "$tmp/$(basename "$u")" "$u" || log_error "下载失败: $u"
        done
        got=1
    fi

    [[ "$got" = "1" ]] || log_error "proot/libtalloc2 下载失败，请检查网络后重跑"
    for deb in "$tmp"/*.deb; do
        dpkg-deb -x "$deb" "$PTOOLS" 2>/dev/null || log_error "解包失败: $deb"
    done
    rm -rf "$tmp"
    find_proot || log_error "proot 安装后仍找不到二进制"
    log_info "proot: $PROOT_BIN  (库: $(proot_lib_path || echo 系统已有))"
}

# =====================================================================
#  2. Debian rootfs（LXC 官方镜像, 动态找最新版本目录）
# =====================================================================
lxc_base_url() {
    local arch="$1"
    echo "https://images.linuxcontainers.org/images/debian/$DEBIAN_SUITE/$arch/default"
}

lxc_latest_version() {
    local arch="$1" base; base=$(lxc_base_url "$arch")
    # latest/ 目录有时 404，改为解析版本化目录取最新
    curl -fsSL --retry 3 "$base/" 2>/dev/null \
      | grep -oE 'href="[0-9]{8}_[0-9]{2}%3A[0-9]{2}/"' \
      | tr -d 'href="/' | sort | tail -1 || true
}

ensure_rootfs() {
    local arch="$1"
    local marker="$PROOTFS_DIR/.proot-rootfs-ok"
    if [[ -f "$marker" ]]; then
        log_info "rootfs 已就绪: $PROOTFS_DIR"
        return 0
    fi
    log_info "准备 Debian $DEBIAN_SUITE ($arch) rootfs 到 $PROOTFS_DIR ..."
    local disk_mb; disk_mb=$(df -m "$PROOTFS_DIR" 2>/dev/null | awk 'NR==2{print $4}')
    if [[ -n "$disk_mb" && "$disk_mb" -lt "$DISK_WARN_MB" ]]; then
        log_warn "磁盘剩余仅 ${disk_mb}MB，rootfs+Firefox 约需 1.5GB。可用 PROOTFS_DIR=其它大分区 覆盖"
    fi
    mkdir -p "$PROOTFS_DIR"
    local ver; ver=$(lxc_latest_version "$arch")
    [[ -n "$ver" ]] || log_error "无法获取 LXC 镜像最新版本号（网络问题?）"
    local url="$(lxc_base_url "$arch")/$ver/rootfs.tar.xz"
    local tmp; tmp=$(mktemp -d)
    log_info "下载 rootfs (~100MB) ..."
    download_file "$url" "$tmp/rootfs.tar.xz"
    log_info "解包中 ..."
    tar -xJf "$tmp/rootfs.tar.xz" -C "$PROOTFS_DIR"
    rm -rf "$tmp"

    # 修复 resolv.conf（LXC 里是悬空符号链接）→ 写入宿主 DNS
    rm -f "$PROOTFS_DIR/etc/resolv.conf"
    cp "$(readlink -f /etc/resolv.conf)" "$PROOTFS_DIR/etc/resolv.conf" 2>/dev/null || \
        echo "nameserver 1.1.1.1" > "$PROOTFS_DIR/etc/resolv.conf"

    # machine-id（firefox/dbus 需要)。
    # LXC rootfs 里 /etc/machine-id 是 0444(root:root) 只读文件，非 root 写入
    # 会 Permission denied → 先删除再重建（删文件只需目录写权限）。
    local mid; mid=$(head -c8 /dev/urandom | od -An -tx1 | tr -d ' \n')
    rm -f "$PROOTFS_DIR/etc/machine-id" "$PROOTFS_DIR/var/lib/dbus/machine-id"
    echo "$mid" > "$PROOTFS_DIR/etc/machine-id"
    mkdir -p "$PROOTFS_DIR/var/lib/dbus"
    echo "$mid" > "$PROOTFS_DIR/var/lib/dbus/machine-id"

    # 可写运行时目录（rootfs 归用户所有，容器内 root 写它 = 真实 uid 写）
    mkdir -p "$PROOTFS_DIR/run" "$PROOTFS_DIR/tmp" "$PROOTFS_DIR/root"

    touch "$marker"
    log_info "rootfs 就绪: $PROOTFS_DIR"
}

# =====================================================================
#  3. 容器入口脚本（带关键绑定）
# =====================================================================
CONTAINER_SH="$HOME/.proot-container.sh"

write_container_sh() {
    cat > "$CONTAINER_SH" <<EOF
#!/bin/sh
# proot 容器入口（由 proot-firefox.sh 生成）
# 关键:
#   * -R rootfs → 容器内是 root, apt 随意装
#   * 覆盖 proot 默认绑定的宿主 /etc 文件(/etc/passwd /etc/group ...),
#     否则容器里看到的是宿主(只读)的, apt 加用户会失败
#   * -b rootfs/run:/run 同样覆盖宿主的 /run
ROOTFS="$PROOTFS_DIR"
PROOT="$PROOT_BIN"
LIBDIR="$(proot_lib_path || true)"
[ -n "\$LIBDIR" ] && export LD_LIBRARY_PATH="\$LIBDIR:\$LD_LIBRARY_PATH"

BINDS="-b \$ROOTFS/run:/run -b \$ROOTFS/tmp:/tmp -b \$ROOTFS/root:/root -b /proc:/proc"
for f in passwd group shadow gshadow hosts hostname resolv.conf host.conf hosts.equiv netgroup networks mtab localtime machine-id; do
  if [ -f "\$ROOTFS/etc/\$f" ] && [ ! -L "\$ROOTFS/etc/\$f" ]; then
    BINDS="\$BINDS -b \$ROOTFS/etc/\$f:/etc/\$f"
  fi
done
# PROOT_NOFAKE=1 → 不加 -0（运行 Firefox 图形栈时用: firefox 拒绝"euid=0 但 HOME 属主不是 root"）
FAKE="-0"
[ -n "\$PROOT_NOFAKE" ] && FAKE=""
exec "\$PROOT" \$FAKE -w / -R "\$ROOTFS" \$BINDS "\$@"
EOF
    chmod +x "$CONTAINER_SH"
    log_info "容器入口: $CONTAINER_SH"
}

# =====================================================================
#  4. 容器内 apt 安装（provision）
# =====================================================================
container_provision() {
    log_info "容器内 apt-get 安装 Firefox 图形栈 ...（首次较久）"
    "$CONTAINER_SH" /bin/sh -c '
        export DEBIAN_FRONTEND=noninteractive
        apt-get update -qq 2>&1 | tail -1
        apt-get install -y --no-install-recommends xvfb x11vnc firefox-esr xauth '"$FIREFOX_FONTS"' 2>&1 | tail -3
        apt-get clean 2>/dev/null || true
        mkdir -p /tmp /run /root/.mozilla
        echo PROVISION_OK
    ' | tail -6
    log_info "容器内安装完成"
}

# =====================================================================
#  5. 容器内运行栈（Xvfb + x11vnc + firefox + 自守护）
# =====================================================================
STACK_SH="$PROOTFS_DIR/root/run-stack.sh"

write_stack_sh() {
    local vnc_extra=""
    [[ -n "$VNC_PASSWORD" ]] && vnc_extra="-passwd '$VNC_PASSWORD'"
    cat > "$STACK_SH" <<EOF
#!/bin/sh
# 容器内图形栈（由 proot-firefox.sh 生成）
export DISPLAY="$DISPLAY_NUM"
export HOME=/root
export XDG_RUNTIME_DIR=/tmp/xdg
mkdir -p /tmp/xdg /root/.mozilla
rm -f /tmp/.pid.xvfb /tmp/.pid.x11vnc /tmp/.pid.ff
# 固定 profile, 每次全新 → 避免锁/损坏
PROF=/root/.mozilla/proot-profile
rm -rf "\$PROF"; mkdir -p "\$PROF"

start_xvfb()   { Xvfb "$DISPLAY_NUM" -screen 0 1280x800x24 -nolisten tcp >/tmp/xvfb.log 2>&1 & echo \$! > /tmp/.pid.xvfb; }
start_x11vnc() { x11vnc -display "$DISPLAY_NUM" -forever -shared -rfbport "$VNC_PORT" -noshm $vnc_extra >/tmp/x11vnc.log 2>&1 & echo \$! > /tmp/.pid.x11vnc; }
start_ff()     { firefox-esr --no-remote --new-instance -profile "\$PROF" about:blank >/tmp/firefox.log 2>&1 & echo \$! > /tmp/.pid.ff; }

start_xvfb
sleep 2
start_x11vnc
sleep 2
start_ff
echo "stack started: Xvfb=\$(cat /tmp/.pid.xvfb) x11vnc=\$(cat /tmp/.pid.x11vnc) ff=\$(cat /tmp/.pid.ff)" > /tmp/stack.log

while true; do
    for name in xvfb x11vnc ff; do
        pid=\$(cat /tmp/.pid.\$name 2>/dev/null)
        if ! kill -0 \$pid 2>/dev/null; then
            echo "\$(date '+%F %T') restart \$name" >> /tmp/stack.log
            sleep 3
            case \$name in
                xvfb)   start_xvfb ;;
                x11vnc) start_x11vnc ;;
                ff)     start_ff ;;
            esac
        fi
    done
    sleep 10
done
EOF
    chmod +x "$STACK_SH"
    log_info "容器内运行栈: $STACK_SH"
}

# =====================================================================
#  6. 宿主侧 noVNC / websockify / cloudflared（同 firefox-tunnel.sh）
# =====================================================================
ensure_websockify() {
    if [[ -x "$NOVNC_DIR/utils/websockify/run" ]]; then return 0; fi
    local tmp; tmp=$(mktemp -d)
    log_info "下载 websockify ..."
    if curl -fsSL --retry 3 -o "$tmp/ws.tar.gz" "https://github.com/novnc/websockify/archive/refs/tags/v0.12.0.tar.gz"; then
        tar -xzf "$tmp/ws.tar.gz" -C "$tmp"
        mkdir -p "$NOVNC_DIR/utils"
        rm -rf "$NOVNC_DIR/utils/websockify"
        cp -r "$tmp"/websockify-0.12.0 "$NOVNC_DIR/utils/websockify"
    fi
    rm -rf "$tmp"
    [[ -x "$NOVNC_DIR/utils/websockify/run" ]] || log_error "websockify 下载失败"
}

ensure_novnc() {
    if [[ -f "$NOVNC_DIR/vnc.html" ]]; then return 0; fi
    local tmp; tmp=$(mktemp -d)
    log_info "下载 noVNC ..."
    if download_file "https://github.com/novnc/noVNC/archive/refs/tags/v1.5.0.tar.gz" "$tmp/novnc.tar.gz"; then
        mkdir -p "$NOVNC_DIR"
        tar -xzf "$tmp/novnc.tar.gz" -C "$tmp" && cp -r "$tmp"/noVNC-1.5.0/* "$NOVNC_DIR/"
    fi
    [[ -f "$NOVNC_DIR/vnc.html" ]] || log_error "noVNC 下载失败"
    rm -rf "$tmp"
    ensure_websockify
}

ensure_cloudflared() {
    [[ -x "$CF_BIN" ]] && return 0
    local arch="$1" os
    os=$(uname -s | tr '[:upper:]' '[:lower:]')
    local url="https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-${os}-${arch}"
    [[ "$arch" == "amd64" ]] && url="https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-amd64"
    [[ "$arch" == "arm64" ]] && url="https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-arm64"
    download_file "$url" "$CF_BIN"
    chmod +x "$CF_BIN"
}

build_tunnel_args() {
    local port="$1"
    if [[ -n "$ARGO_AUTH" && -n "$ARGO_DOMAIN" ]]; then
        if [[ "$ARGO_AUTH" =~ TunnelSecret ]]; then
            printf '%s\n' "$ARGO_AUTH" > "$(pwd)/tunnel.yml"
            chmod 600 "$(pwd)/tunnel.yml"
            log_info "JSON 配置固定隧道模式，已生成 $(pwd)/tunnel.yml" >&2
            echo "tunnel --edge-ip-version auto --no-autoupdate --protocol http2 --config $(pwd)/tunnel.yml run"
        else
            echo "tunnel --edge-ip-version auto --no-autoupdate --protocol http2 run --token ${ARGO_AUTH}"
        fi
    else
        log_info "临时隧道模式（随机 trycloudflare 域名）" >&2
        echo "tunnel --edge-ip-version auto --no-autoupdate --protocol http2 --url http://localhost:$port"
    fi
}

# =====================================================================
#  7. 宿主侧守护 wrapper
# =====================================================================
WRAPPER_SH="$HOME/.proot-firefox-wrapper.sh"

write_wrapper() {
    local tunnel_args; tunnel_args=$(build_tunnel_args "$ARGO_PORT")
    local py; py=$(command -v python3 || true)
    [[ -z "$py" && -x "$XROOT/usr/bin/python3" ]] && py="$XROOT/usr/bin/python3"
    [[ -n "$py" && -x "$py" ]] || log_error "宿主需要 python3（跑 websockify）。可设 PYTHON3_BIN 或先 bash noroot-deps.sh"
    cat > "$WRAPPER_SH" <<EOF
#!/bin/bash
cd "$(pwd)"
export LD_LIBRARY_PATH="\$(cat "$HOME/.proot-ldpath" 2>/dev/null):\$LD_LIBRARY_PATH"

CONTAINER_SH="$CONTAINER_SH"
STACK_SH="$STACK_SH"
LOG="$HOME/proot-firefox.log"

start_container() {
    # PROOT_NOFAKE=1: 不加 -0 → 容器内 firefox 看到 euid=真实 uid, 不触发 root 检查
    nohup env PROOT_NOFAKE=1 "\$CONTAINER_SH" /bin/sh "\$STACK_SH" >> "\$LOG" 2>&1 &
    CONTAINER_PID=\$!
}

start_novnc() {
    ( cd "$NOVNC_DIR/utils/websockify" && exec "$py" -m websockify --web="$NOVNC_DIR" "$ARGO_PORT" localhost:"$VNC_PORT" ) >> "\$LOG" 2>&1 &
    NOVNC_PID=\$!
}

start_cf() {
    "$CF_BIN" $tunnel_args >> "\$LOG" 2>&1 &
    CF_PID=\$!
}

start_container
sleep 12
start_novnc
start_cf
echo "\$(date '+%F %T') 全部已启动: container=\$CONTAINER_PID novnc=\$NOVNC_PID cloudflared=\$CF_PID" >> "\$LOG"

while true; do
    for name in CONTAINER NOVNC CF; do
        pid_var=\${name}_PID
        pid=\${!pid_var}
        if ! kill -0 \$pid 2>/dev/null; then
            echo "\$(date '+%F %T') \$name 已退出，重启..." >> "\$LOG"
            sleep 5
            case \$name in
                CONTAINER) start_container ;;
                NOVNC)     start_novnc ;;
                CF)        start_cf ;;
            esac
        fi
    done
    sleep 8
done
EOF
    chmod +x "$WRAPPER_SH"
}

# =====================================================================
#  主流程
# =====================================================================
ARCH=$(detect_arch)
log_info "系统架构: $ARCH  |  命令: $CMD"

if [[ "$CMD" == "provision" || "$CMD" == "start" ]]; then
    find_proot || install_proot
    proot_lib_path > "$HOME/.proot-ldpath" 2>/dev/null || true
    ensure_rootfs "$ARCH"
    write_container_sh
    if [[ ! -x "$PROOTFS_DIR/usr/bin/firefox-esr" ]]; then
        container_provision
    else
        log_info "容器内 Firefox 已安装，跳过 apt"
    fi
    write_stack_sh
    ensure_novnc
    ensure_cloudflared "$ARCH"
fi

if [[ "$CMD" == "enter" ]]; then
    write_container_sh
    log_info "进入容器（你是 root）—— 可用 apt-get 装任意软件，exit 退出"
    if "$CONTAINER_SH" /bin/bash -l 2>/dev/null; then :; else "$CONTAINER_SH" /bin/sh; fi
    exit 0
fi

if [[ "$CMD" == "status" ]]; then
    echo "--- 宿主进程 ---"
    ps aux 2>/dev/null | grep -E "proot-container|websockify|cloudflared" | grep -v grep | awk '{print $2, $11, $12, $13}' | head
    echo "--- 端口 ---"
    for p in "$ARGO_PORT" "$VNC_PORT"; do
        if (exec 3<>/dev/tcp/127.0.0.1/$p) 2>/dev/null; then echo "port $p: OPEN"; exec 3>&-; else echo "port $p: closed"; fi
    done
    exit 0
fi

if [[ "$CMD" == "stop" ]]; then
    pkill -f "proot-container.sh" 2>/dev/null || true
    pkill -f "proot-firefox-wrapper" 2>/dev/null || true
    pkill -f "websockify" 2>/dev/null || true
    pkill -f "cloudflared tunnel" 2>/dev/null || true
    log_info "已停止（如仍有残留: ps aux | grep -E 'Xvfb|x11vnc|firefox|websock|cloudflared'）"
    exit 0
fi

# start
if [[ -f "$HOME/proot-firefox.pid" ]] && kill -0 "$(cat "$HOME/proot-firefox.pid")" 2>/dev/null; then
    log_error "已在运行 (pid=$(cat "$HOME/proot-firefox.pid"))。先: bash proot-firefox.sh stop"
fi
write_wrapper
if [[ "$DRY_RUN" = "1" ]]; then
    echo "---- dry-run：container.sh ----"; cat "$CONTAINER_SH"
    echo "---- dry-run：run-stack.sh ----"; cat "$STACK_SH"
    echo "---- dry-run：wrapper.sh ----"; cat "$WRAPPER_SH"
    exit 0
fi

log_info "启动容器 + noVNC + cloudflared 隧道 ..."
nohup bash "$WRAPPER_SH" > "$HOME/proot-firefox.log" 2>&1 &
echo $! > "$HOME/proot-firefox.pid"
sleep 14
log_info "已后台启动 (wrapper pid=$(cat "$HOME/proot-firefox.pid"))，日志: $HOME/proot-firefox.log"

cat <<EOF

${GREEN}================ 访问方式 ================${NC}
本地 noVNC:  http://localhost:$ARGO_PORT/vnc.html
隧道地址:    ${BLUE}[URL]${NC} https://\$ARGO_DOMAIN/vnc.html   （临时隧道看日志里 trycloudflare 域名）
${BLUE}[URL]${NC} tail -f $HOME/proot-firefox.log

操作:
  进入容器(root):   bash proot-firefox.sh enter
  停止:             bash proot-firefox.sh stop
  状态:             bash proot-firefox.sh status
EOF
