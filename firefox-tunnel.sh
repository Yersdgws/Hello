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
#  需要先装好 Firefox: bash install-firefox.sh（本脚本会自动检测/引导）
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
export NOVNC_DIR=${NOVNC_DIR:-"$HOME/noVNC"}
export CF_BIN=${CF_BIN:-"$HOME/cloudflared"}

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
ensure_firefox() {
    if [[ -x "$FIREFOX_BIN" ]]; then
        log_info "Firefox: $FIREFOX_BIN"
    elif command -v firefox >/dev/null 2>&1; then
        FIREFOX_BIN=$(command -v firefox)
        log_info "Firefox(系统): $FIREFOX_BIN"
    else
        log_warn "未找到 Firefox，调用 install-firefox.sh 安装..."
        if [[ -f ./install-firefox.sh ]]; then
            bash ./install-firefox.sh
        else
            curl -fsSL -o /tmp/install-firefox.sh \
                https://raw.githubusercontent.com/your/repo/install-firefox.sh 2>/dev/null \
                && bash /tmp/install-firefox.sh || log_error "请先运行 install-firefox.sh"
        fi
        [[ -x "$FIREFOX_BIN" ]] || log_error "Firefox 安装失败: $FIREFOX_BIN"
    fi
}

# ---------- 2. 组件检测/安装 (xvfb, x11vnc, python3) ----------
ensure_tools() {
    local missing=()
    command -v Xvfb   >/dev/null 2>&1 || missing+=(xvfb)
    command -v x11vnc >/dev/null 2>&1 || missing+=(x11vnc)
    command -v python3 >/dev/null 2>&1 || missing+=(python3)

    if [[ ${#missing[@]} -gt 0 ]]; then
        log_warn "缺少组件: ${missing[*]}，尝试 apt 安装..."
        if command -v apt-get >/dev/null 2>&1; then
            if [[ $EUID -eq 0 ]]; then
                apt-get update -qq && apt-get install -y "${missing[@]}"
            elif command -v sudo >/dev/null 2>&1; then
                sudo apt-get update -qq && sudo apt-get install -y "${missing[@]}"
            else
                log_error "无 root/sudo，无法安装 ${missing[*]}，请手动安装"
            fi
        else
            log_error "无 apt，请手动安装: ${missing[*]}"
        fi
    fi
}

# ---------- 3. noVNC（网页版 VNC 客户端） ----------
ensure_novnc() {
    if [[ -f "$NOVNC_DIR/vnc.html" ]]; then
        log_info "noVNC: $NOVNC_DIR"
        return 0
    fi
    local tmp; tmp=$(mktemp -d)
    local url="https://github.com/novnc/noVNC/archive/refs/tags/v1.5.0.tar.gz"
    log_info "下载 noVNC ..."
    download_file "$url" "$tmp/novnc.tar.gz"
    mkdir -p "$NOVNC_DIR"
    tar -xzf "$tmp/novnc.tar.gz" -C "$tmp"
    cp -r "$tmp"/noVNC-1.5.0/* "$NOVNC_DIR/"
    chmod +x "$NOVNC_DIR/utils/launch.sh" 2>/dev/null || true
    rm -rf "$tmp"
    log_info "noVNC 就绪: $NOVNC_DIR"
}

# ---------- 4. cloudflared ----------
ensure_cloudflared() {
    [[ -x "$CF_BIN" ]] && { log_info "cloudflared: $CF_BIN"; return 0; }
    local arch="$1" os="$2"
    local url="https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-${os}-${arch}"
    [[ "$os" == "linux" && "$arch" == "armv7" ]] && url="https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-arm"
    download_file "$url" "$CF_BIN"
    chmod +x "$CF_BIN"
}

# ---------- 5. 构建 cloudflared 隧道参数（同 gotty.sh 逻辑） ----------
build_tunnel_args() {
    local gotty_port="$1"

    if [[ -n "$ARGO_AUTH" && -n "$ARGO_DOMAIN" ]]; then
        if [[ "$ARGO_AUTH" =~ TunnelSecret ]]; then
            local config_file="$(pwd)/tunnel.yml"
            printf '%s\n' "$ARGO_AUTH" > "$config_file"
            chmod 600 "$config_file"
            log_info "识别为 JSON 配置固定隧道模式，已生成 $config_file"
            echo "tunnel --edge-ip-version auto --no-autoupdate --protocol http2 --config $config_file run"
        else
            if [[ "$ARGO_AUTH" =~ ^[A-Z0-9a-z=]{120,250}$ ]]; then
                log_info "识别为固定隧道 Token 模式"
            else
                log_warn "ARGO_AUTH 格式无法识别，将尝试作为 Token 使用"
            fi
            echo "tunnel --edge-ip-version auto --no-autoupdate --protocol http2 run --token ${ARGO_AUTH}"
        fi
    else
        log_info "临时隧道模式（随机 trycloudflare 域名，仅供测试）"
        echo "tunnel --edge-ip-version auto --no-autoupdate --protocol http2 --url http://localhost:$gotty_port"
    fi
}

# ---------- 6. 生成自守护启动脚本（任一进程退出自动重启） ----------
create_wrapper() {
    local dir="$(pwd)"
    local tunnel_args=$(build_tunnel_args "$ARGO_PORT")
    local wrapper="$dir/.firefox-tunnel-wrapper.sh"

    local x11vnc_cmd="x11vnc -display $DISPLAY_NUM -forever -shared -rfbport $VNC_PORT -nopw"
    [[ -n "$VNC_PASSWORD" ]] && x11vnc_cmd="x11vnc -display $DISPLAY_NUM -forever -shared -rfbport $VNC_PORT -passwd '$VNC_PASSWORD'"

    cat > "$wrapper" <<EOF
#!/bin/bash
cd "$dir"

start_xvfb() {
    Xvfb $DISPLAY_NUM -screen 0 1280x800x24 &
    XVFB_PID=\$!
    sleep 2
}

start_x11vnc() {
    $x11vnc_cmd &
    X11VNC_PID=\$!
}

start_novnc() {
    if [[ -x "$NOVNC_DIR/utils/launch.sh" ]]; then
        "$NOVNC_DIR/utils/launch.sh" --vnc localhost:$VNC_PORT --listen $ARGO_PORT &
    else
        python3 "$NOVNC_DIR/utils/websockify.py" --web="$NOVNC_DIR" $ARGO_PORT localhost:$VNC_PORT &
    fi
    NOVNC_PID=\$!
}

start_firefox() {
    DISPLAY=$DISPLAY_NUM "$FIREFOX_BIN" --no-remote --new-instance about:blank &
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
