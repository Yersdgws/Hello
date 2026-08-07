#!/bin/bash
set -e

# =====================================================================
#  Firefox + Xvfb + noVNC + Cloudflared 隧道（参考 gotty.sh 的 ARGO 架构）
#
#  效果: 在无显示器环境(云开发空间/VPS)跑 Firefox，
#        通过 noVNC(网页 VNC) + cloudflared 隧道域名，用浏览器直接操作 Firefox。
#
#  用法:
#    bash firefox-tunnel.sh                     # 临时隧道(trycloudflare 随机域名)
#    ARGO_DOMAIN=xxx.trycloudflare.com \
#    ARGO_AUTH=固定隧道Token \
#    bash firefox-tunnel.sh                     # 固定隧道
#    ARGO_PORT=8080 VNC_PASSWORD=123456 \
#    bash firefox-tunnel.sh                     # 改端口 + VNC 密码
#    bash firefox-tunnel.sh --dry-run           # 只打印将要执行的命令
#
#  无 root 环境（BAS / 云开发空间）:
#    bash noroot-deps.sh                        # 装 Xvfb/x11vnc/xkbcomp/GTK 到 ~/xroot
#    bash firefox-tunnel.sh                     # 自动用 ~/xroot 里的二进制
#
# =====================================================================

# ---------- 颜色与日志 ----------
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

log_info()  { echo -e "${GREEN}[INFO]${NC} $1"; }
log_warn()  { echo -e "${YELLOW}[WARN]${NC} $1"; }
log_error() { echo -e "${RED}[ERROR]${NC} $1" >&2; exit 1; }
log_url()   { echo -e "${BLUE}[URL]${NC} $1"; }

# ---------- 可配置参数（和 gotty.sh 一致的三件套 + VNC） ----------
export ARGO_PORT=${ARGO_PORT:-'8080'}     # noVNC 网页端口（本地）
export ARGO_DOMAIN=${ARGO_DOMAIN:-''}     # 固定隧道域名（空 = 临时隧道）
export ARGO_AUTH=${ARGO_AUTH:-''}         # 固定隧道 Token / TunnelSecret JSON
export VNC_PASSWORD=${VNC_PASSWORD:-''}   # VNC 连接密码（空 = 无密码，不推荐）
export VNC_PORT=${VNC_PORT:-'5900'}       # x11vnc 端口
export DISPLAY_NUM=${DISPLAY_NUM:-':99'}  # 虚拟显示号
export FIREFOX_BIN=${FIREFOX_BIN:-"$HOME/firefox/firefox"}
export FIREFOX_LANG=${FIREFOX_LANG:-'en-US'}
export NOVNC_DIR=${NOVNC_DIR:-"$HOME/noVNC"}
export CF_BIN=${CF_BIN:-"$HOME/cloudflared"}

# 二进制路径覆盖（无 root 环境用 noroot-deps.sh 装到 ~/xroot 后指到这里）
export XVFB_BIN=${XVFB_BIN:-''}
export X11VNC_BIN=${X11VNC_BIN:-''}
export PYTHON3_BIN=${PYTHON3_BIN:-''}
export XROOT=${XROOT:-"$HOME/xroot"}
export PROOT_BIN=${PROOT_BIN:-""}

DRY_RUN=0
[[ "$1" == "--dry-run" ]] && DRY_RUN=1

# ---------- 系统检测 ----------
detect_arch() {
    case $(uname -m) in
        x86_64|amd64)  echo "amd64" ;;
        aarch64|arm64) echo "arm64" ;;
        armv7l|armv8l) echo "armv7" ;;
        *) log_error "不支持的架构: $(uname -m)" ;;
    esac
}
detect_os() {
    local os=$(uname -s | tr '[:upper:]' '[:lower:]')
    case "$os" in
        linux|darwin) echo "$os" ;;
        *) log_error "不支持的操作系统: $(uname -s)" ;;
    esac
}

# ---------- 下载工具 ----------
download_file() {
    local url="$1" output="$2"
    [[ -f "$output" ]] && { log_info "$(basename "$output") 已存在，跳过下载"; return; }
    log_info "下载: $url"
    curl -fsSL --retry 3 --retry-delay 2 -o "$output" "$url" || log_error "下载失败: $url"
}

# ---------- 1. 确保 Firefox ----------
install_firefox_from_cdn() {
    local arch
    case $(uname -m) in
        x86_64|amd64)  arch="linux64" ;;
        aarch64|arm64) arch="linux-aarch64" ;;
        *) log_error "不支持的架构: $(uname -m)" ;;
    esac
    local url="https://download.mozilla.org/?product=firefox-latest&os=${arch}&lang=${FIREFOX_LANG}"
    local tmp; tmp=$(mktemp -d)

    log_info "从 Mozilla CDN 下载 Firefox ($arch / $FIREFOX_LANG) ..."
    download_file "$url" "$tmp/firefox.tar.xz"
    mkdir -p "$(dirname "$FIREFOX_BIN")"
    tar -xJf "$tmp/firefox.tar.xz" -C "$(dirname "$FIREFOX_BIN")" --strip-components=1
    chmod +x "$FIREFOX_BIN"
    rm -rf "$tmp"
    log_info "Firefox 已自动安装: $FIREFOX_BIN"
}

ensure_firefox() {
    if [[ -x "$FIREFOX_BIN" ]]; then
        log_info "Firefox: $FIREFOX_BIN"
    elif command -v firefox >/dev/null 2>&1; then
        FIREFOX_BIN=$(command -v firefox)
        log_info "Firefox(系统): $FIREFOX_BIN"
    else
        log_warn "未找到 Firefox，开始自动安装..."
        if [[ -f ./install-firefox.sh ]]; then
            # 同目录有独立安装脚本 → 优先用它
            bash ./install-firefox.sh
        fi
        [[ -x "$FIREFOX_BIN" ]] || install_firefox_from_cdn
        [[ -x "$FIREFOX_BIN" ]] || log_error "Firefox 自动安装失败: $FIREFOX_BIN"
    fi
}

# ---------- 2. 组件检测/安装 (xvfb, x11vnc, python3) ----------
# 解析顺序: 环境变量 > PATH > ~/xroot(无root解包目录) > apt(root)
resolve_bin() {
    local var_name="$1" default_name="$2" xroot_path="$3"
    local val="${!var_name}"
    if [[ -n "$val" && -x "$val" ]]; then
        eval "$var_name='$val'"; return 0
    fi
    if command -v "$default_name" >/dev/null 2>&1; then
        eval "$var_name='$(command -v "$default_name")'"; return 0
    fi
    if [[ -x "$xroot_path" ]]; then
        eval "$var_name='$xroot_path'"; return 0
    fi
    eval "$var_name=''"
    return 1
}

ensure_tools() {
    # 尝试找二进制
    resolve_bin XVFB_BIN   Xvfb   "$XROOT/usr/bin/Xvfb"   || true
    resolve_bin X11VNC_BIN x11vnc "$XROOT/usr/bin/x11vnc" || true
    resolve_bin PYTHON3_BIN python3 "$XROOT/usr/bin/python3" || true

    local missing=()
    [[ -n "$XVFB_BIN" ]]   || missing+=(xvfb)
    [[ -n "$X11VNC_BIN" ]] || missing+=(x11vnc)
    [[ -n "$PYTHON3_BIN" ]] || missing+=(python3)

    if [[ ${#missing[@]} -gt 0 ]]; then
        log_warn "缺少组件: ${missing[*]}，尝试安装..."
        # 有 root/sudo → apt
        if command -v apt-get >/dev/null 2>&1 && { [[ $EUID -eq 0 ]] || command -v sudo >/dev/null 2>&1; }; then
            if [[ $EUID -eq 0 ]]; then
                apt-get update -qq && apt-get install -y "${missing[@]}"
            else
                sudo apt-get update -qq && sudo apt-get install -y "${missing[@]}"
            fi
        fi
        # 再查一次
        [[ -x "$XVFB_BIN" ]]   || [[ -n "$XVFB_BIN" && -x "$(command -v Xvfb 2>/dev/null)" ]] || resolve_bin XVFB_BIN Xvfb "$XROOT/usr/bin/Xvfb" || true
        [[ -n "$XVFB_BIN" ]]   || missing_xvfb=1
        [[ -n "$X11VNC_BIN" ]] || missing_x11vnc=1
        [[ -n "$PYTHON3_BIN" ]] || missing_python3=1
        if [[ "$missing_xvfb" = "1" || "$missing_x11vnc" = "1" || "$missing_python3" = "1" ]]; then
            cat >&2 <<'EOF'
${RED}[ERROR]${NC} 仍缺少 Xvfb/x11vnc/python3，且无 root/sudo 无法 apt 安装。

无 root 环境请用同目录的 noroot-deps.sh（apt-get download + 解包 .deb 到 ~/xroot）：
    bash noroot-deps.sh
    export LD_LIBRARY_PATH="$HOME/xroot/usr/lib/x86_64-linux-gnu:$HOME/xroot/usr/lib:$LD_LIBRARY_PATH"
    export PATH="$HOME/xroot/usr/bin:$PATH"

然后指定二进制路径重跑：
    XVFB_BIN=~/xroot/usr/bin/Xvfb X11VNC_BIN=~/xroot/usr/bin/x11vnc \\
    PYTHON3_BIN=$(command -v python3) bash firefox-tunnel.sh

如果你其实有 root（VPS/本机），直接 sudo 装: apt-get install -y xvfb x11vnc python3
EOF
            log_error "缺少 ${missing[*]}（详见上方说明）"
        fi
    else
        log_info "Xvfb=$XVFB_BIN x11vnc=$X11VNC_BIN python3=$PYTHON3_BIN"
    fi
}

# ---------- 3. proot（让 Xvfb 找到 /usr/bin/xkbcomp） ----------
# Xvfb 源码里写死调用 /usr/bin/xkbcomp（无 PATH 回退、无环境变量覆盖）。
# 无 root 时用 proot 把 ~/xroot/usr/bin/xkbcomp 绑定到 /usr/bin/xkbcomp。
# proot 由 noroot-deps.sh 通过 apt-get download 装到 ~/xroot/usr/bin/proot。
ensure_proot() {
    # 系统本身有 /usr/bin/xkbcomp（root/VPS 环境）→ 不需要 proot
    if [[ -x /usr/bin/xkbcomp ]]; then
        log_info "系统已有 /usr/bin/xkbcomp，无需 proot"
        PROOT_BIN=""
        return 0
    fi
    [[ -x "$PROOT_BIN" ]] && PROOT_BIN_RESOLVED="$PROOT_BIN"
    [[ -z "$PROOT_BIN_RESOLVED" ]] && command -v proot >/dev/null 2>&1 && PROOT_BIN_RESOLVED=$(command -v proot)
    [[ -z "$PROOT_BIN_RESOLVED" && -x "$XROOT/usr/bin/proot" ]] && PROOT_BIN_RESOLVED="$XROOT/usr/bin/proot"
    if [[ -z "$PROOT_BIN_RESOLVED" ]]; then
        log_warn "未找到 proot，且系统没有 /usr/bin/xkbcomp —— Xvfb 会报键盘错。"
        log_warn "请先重跑: bash noroot-deps.sh  （会自动装 proot + libtalloc2）"
        PROOT_BIN=""
        return 0
    fi
    # 自测 proot 能跑（避免坏包/架构不匹配静默失败）
    if ! "$PROOT_BIN_RESOLVED" --version >/dev/null 2>&1; then
        log_warn "proot 无法运行: $PROOT_BIN_RESOLVED —— Xvfb 键盘可能失败"
        PROOT_BIN=""
        return 0
    fi
    PROOT_BIN="$PROOT_BIN_RESOLVED"
    log_info "proot: $PROOT_BIN"
}

# ---------- 4. noVNC（网页版 VNC 客户端）+ websockify ----------
# 注意：noVNC 官方发布 tarball 里【不含】websockify（git 子模块），
# 必须单独下载 websockify 放到 $NOVNC_DIR/utils/websockify/。
ensure_websockify() {
    if [[ -x "$NOVNC_DIR/utils/websockify/run" ]]; then
        log_info "websockify: $NOVNC_DIR/utils/websockify"
        return 0
    fi
    local tmp; tmp=$(mktemp -d)
    local url="https://github.com/novnc/websockify/archive/refs/tags/v0.12.0.tar.gz"
    log_info "下载 websockify（noVNC 发布包不含它，需单独拉）..."
    if curl -fsSL --retry 3 -o "$tmp/ws.tar.gz" "$url"; then
        tar -xzf "$tmp/ws.tar.gz" -C "$tmp"
        mkdir -p "$NOVNC_DIR/utils"
        rm -rf "$NOVNC_DIR/utils/websockify"
        cp -r "$tmp"/websockify-0.12.0 "$NOVNC_DIR/utils/websockify"
    fi
    rm -rf "$tmp"
    [[ -x "$NOVNC_DIR/utils/websockify/run" ]] || log_error "websockify 下载失败: $url"
    log_info "websockify 就绪: $NOVNC_DIR/utils/websockify"
}

ensure_novnc() {
    # 校验：vnc.html（noVNC 本体）+ utils/websockify/run（websockify）
    if [[ -f "$NOVNC_DIR/vnc.html" && -x "$NOVNC_DIR/utils/websockify/run" ]]; then
        log_info "noVNC: $NOVNC_DIR"
        return 0
    fi
    local tmp; tmp=$(mktemp -d)
    local url="https://github.com/novnc/noVNC/archive/refs/tags/v1.5.0.tar.gz"
    log_info "下载 noVNC ..."
    if download_file "$url" "$tmp/novnc.tar.gz"; then
        mkdir -p "$NOVNC_DIR"
        tar -xzf "$tmp/novnc.tar.gz" -C "$tmp" && cp -r "$tmp"/noVNC-1.5.0/* "$NOVNC_DIR/"
    fi
    # tar 解压失败 / GitHub 下载失败 → git 兜底
    if [[ ! -f "$NOVNC_DIR/vnc.html" ]]; then
        log_warn "tar 下载/解压失败，改用 git clone 兜底 ..."
        rm -rf "$NOVNC_DIR"
        git clone --depth 1 --branch v1.5.0 https://github.com/novnc/noVNC.git "$NOVNC_DIR" \
            || log_error "noVNC 下载失败: $url（请检查网络后重跑）"
    fi
    chmod +x "$NOVNC_DIR/utils/launch.sh" 2>/dev/null || true
    [[ -f "$NOVNC_DIR/vnc.html" ]] || log_error "noVNC 目录不完整: $NOVNC_DIR"
    rm -rf "$tmp"
    ensure_websockify
    log_info "noVNC 就绪: $NOVNC_DIR"
}

# ---------- 5. cloudflared ----------
ensure_cloudflared() {
    [[ -x "$CF_BIN" ]] && { log_info "cloudflared: $CF_BIN"; return 0; }
    local arch="$1" os="$2"
    local url="https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-${os}-${arch}"
    [[ "$os" == "linux" && "$arch" == "armv7" ]] && url="https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-arm"
    download_file "$url" "$CF_BIN"
    chmod +x "$CF_BIN"
}

# ---------- 6. 构建 cloudflared 隧道参数（同 gotty.sh 逻辑） ----------
build_tunnel_args() {
    local gotty_port="$1"

    # 注意：本函数 stdout 必须只输出"隧道参数"，日志一律走 stderr，
    # 否则 $(build_tunnel_args) 会把日志混进参数，导致 wrapper 命令被拆烂。
    if [[ -n "$ARGO_AUTH" && -n "$ARGO_DOMAIN" ]]; then
        if [[ "$ARGO_AUTH" =~ TunnelSecret ]]; then
            local config_file="$(pwd)/tunnel.yml"
            printf '%s\n' "$ARGO_AUTH" > "$config_file"
            chmod 600 "$config_file"
            log_info "识别为 JSON 配置固定隧道模式，已生成 $config_file" >&2
            echo "tunnel --edge-ip-version auto --no-autoupdate --protocol http2 --config $config_file run"
        else
            if [[ "$ARGO_AUTH" =~ ^[A-Z0-9a-z=]{120,250}$ ]]; then
                log_info "识别为固定隧道 Token 模式" >&2
            else
                log_warn "ARGO_AUTH 格式无法识别，将尝试作为 Token 使用" >&2
            fi
            echo "tunnel --edge-ip-version auto --no-autoupdate --protocol http2 run --token ${ARGO_AUTH}"
        fi
    else
        log_info "临时隧道模式（随机 trycloudflare 域名，仅供测试）" >&2
        echo "tunnel --edge-ip-version auto --no-autoupdate --protocol http2 --url http://localhost:$gotty_port"
    fi
}

# ---------- 7. 生成自守护启动脚本（任一进程退出自动重启） ----------
create_wrapper() {
    local dir="$(pwd)"
    local tunnel_args=$(build_tunnel_args "$ARGO_PORT")
    local wrapper="$dir/.firefox-tunnel-wrapper.sh"

    local x11vnc_cmd="$X11VNC_BIN -display $DISPLAY_NUM -forever -shared -rfbport $VNC_PORT -nopw"
    [[ -n "$VNC_PASSWORD" ]] && x11vnc_cmd="$X11VNC_BIN -display $DISPLAY_NUM -forever -shared -rfbport $VNC_PORT -passwd '$VNC_PASSWORD'"

    # 无 root 解包目录(xroot)的库路径。
    # 关键：系统库目录放前面，xroot 放后面——系统已有的库用系统的（避免
    # bookworm 旧版 libssl 等遮蔽系统新版导致 curl/动态库崩溃），
    # xroot 只补系统没有的（libvncserver、libunwind、GTK 等）。
    local xroot_lib=""
    for d in "$XROOT/usr/lib/"*linux-gnu "$XROOT/usr/lib"; do
        [[ -d "$d" ]] && xroot_lib="$xroot_lib:${d}"
    done
    xroot_lib="${xroot_lib#:}"
    local sys_lib=""
    for d in /usr/lib/x86_64-linux-gnu /lib/x86_64-linux-gnu /usr/lib; do
        [[ -d "$d" ]] && sys_lib="$sys_lib:$d"
    done
    sys_lib="${sys_lib#:}"
    local xroot_export=""
    [[ -n "$xroot_lib" ]] && xroot_export="export LD_LIBRARY_PATH=\"$sys_lib:$xroot_lib:\$LD_LIBRARY_PATH\""
    # 把 xroot 的 bin 加进 PATH（xkbcomp/noVNC/FF 也可能要用）
    local xroot_path_export=""
    [[ -d "$XROOT/usr/bin" ]] && xroot_path_export="export PATH=\"$XROOT/usr/bin:\$PATH\""

    # XKB 数据在编译期路径(/usr/share/X11/xkb)之外时，必须显式 -xkbdir 指向 xroot
    local xkbdir_flag=""
    [[ -d "$XROOT/usr/share/X11/xkb" ]] && xkbdir_flag="-xkbdir $XROOT/usr/share/X11/xkb"

    # Xvfb 写死找 /usr/bin/xkbcomp → 用 proot -b 把 xroot 的 xkbcomp 绑定到该路径
    local xvfb_cmd="$XVFB_BIN $DISPLAY_NUM -screen 0 1280x800x24 $xkbdir_flag"
    if [[ -n "$PROOT_BIN" && -x "$XROOT/usr/bin/xkbcomp" && ! -x /usr/bin/xkbcomp ]]; then
        xvfb_cmd="$PROOT_BIN -b $XROOT/usr/bin/xkbcomp:/usr/bin/xkbcomp -- $XVFB_BIN $DISPLAY_NUM -screen 0 1280x800x24 $xkbdir_flag"
    fi

    cat > "$wrapper" <<EOF
#!/bin/bash
cd "$dir"
$xroot_export
$xroot_path_export

start_xvfb() {
    $xvfb_cmd &
    XVFB_PID=\$!
    sleep 4
}

start_x11vnc() {
    $x11vnc_cmd &
    X11VNC_PID=\$!
}

start_novnc() {
    # websockify 在 noVNC 发布包里不存在，已由 ensure_websockify 装到 utils/websockify/
    ( cd "$NOVNC_DIR/utils/websockify" && exec "$PYTHON3_BIN" -m websockify --web="$NOVNC_DIR" "$ARGO_PORT" localhost:"$VNC_PORT" ) &
    NOVNC_PID=\$!
}

check_firefox_libs() {
    # 体检 Firefox 的依赖是否齐全（缺 GTK 等会直接起不来）
    local out
    out=\$(LD_LIBRARY_PATH="\$LD_LIBRARY_PATH" ldd "\$FIREFOX_BIN" 2>/dev/null | grep -E "not found" || true)
    if [[ -n "\$out" ]]; then
        echo "\$(date '+%F %T') [WARN] Firefox 依赖缺失:"
        echo "\$out" | sed 's/^/      /'
        echo "      → 在会话里重跑: bash noroot-deps.sh ，然后重启本脚本"
    fi
    if echo "\$out" | grep -q -i "gtk"; then
        echo "\$(date '+%F %T') [ERROR] 缺 GTK 库，Firefox 无法启动。请先: bash noroot-deps.sh"
    fi
}

start_firefox() {
    check_firefox_libs
    DISPLAY=$DISPLAY_NUM "\$FIREFOX_BIN" --no-remote --new-instance about:blank &
    FIREFOX_PID=\$!
}

start_cloudflared() {
    "$CF_BIN" $tunnel_args &
    CF_PID=\$!
}

start_xvfb
sleep 1
start_x11vnc
start_novnc
start_firefox
start_cloudflared

while true; do
    for name in XVFB X11VNC NOVNC FIREFOX CF; do
        pid_var=\${name}_PID
        pid=\${!pid_var}
        if ! kill -0 \$pid 2>/dev/null; then
            echo "\$(date '+%F %T') \$name 已退出，重启..."
            sleep 3
            case \$name in
                XVFB)     start_xvfb ;;
                X11VNC)   start_x11vnc ;;
                NOVNC)    start_novnc ;;
                FIREFOX)  start_firefox ;;
                CF)       start_cloudflared ;;
            esac
        fi
    done
    sleep 5
done
EOF
    chmod +x "$wrapper"
    echo "$wrapper"
}

# =====================================================================
#  主流程
# =====================================================================
ARCH=$(detect_arch)
OS=$(detect_os)
log_info "系统: $OS / $ARCH"

ensure_firefox
ensure_tools
ensure_proot
ensure_novnc
ensure_cloudflared "$ARCH" "$OS"

WRAPPER=$(create_wrapper)

if [[ "$DRY_RUN" = "1" ]]; then
    echo "---- dry-run：wrapper 内容 ----"
    cat "$WRAPPER"
    exit 0
fi

log_info "启动 Firefox + noVNC + cloudflared 隧道..."
nohup bash "$WRAPPER" > firefox-tunnel.log 2>&1 &
echo $! > firefox-tunnel.pid
log_info "已后台启动 (pid=$(cat firefox-tunnel.pid))，日志: firefox-tunnel.log"

cat <<EOF

${GREEN}================ 访问方式 ================${NC}
本地 noVNC 页面: http://localhost:$ARGO_PORT/vnc.html
（云开发空间里可用它的端口预览功能访问）

隧道地址（看日志里 trycloudflare 给的域名，或你的固定域名）:
${BLUE}[URL]${NC} https://\$ARGO_DOMAIN/vnc.html
${BLUE}[URL]${NC} 日志: tail -f firefox-tunnel.log

操作:   stop  → pkill -f firefox-tunnel-wrapper.sh
查看:   ps aux | grep -E 'Xvfb|x11vnc|websock|firefox|cloudflared'
EOF
