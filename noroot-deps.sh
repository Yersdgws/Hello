#!/bin/bash
set -e

# =====================================================================
#  无 root 环境安装 Xvfb / x11vnc / Firefox 的 GTK 依赖
#  （apt-get download + dpkg-deb -x 解包到用户目录 + LD_LIBRARY_PATH）
#
#  关键改进: 自动递归解析依赖闭包——不光下 xvfb/x11vnc 本身，
#            还把 libvncserver1/libunwind8/libpangocairo/GTK 等
#            传递依赖全部下载解包，避免运行时缺 .so。
#
#  用法:
#     bash noroot-deps.sh        # 装到 ~/xroot
#  装完 source 输出的 export 即可（或写进 ~/.bashrc）
# =====================================================================

GREEN='\033[0;32m'; YELLOW='\033[1;33m'; RED='\033[0;31m'; NC='\033[0m'
log_info()  { echo -e "${GREEN}[INFO]${NC} $1"; }
log_warn()  { echo -e "${YELLOW}[WARN]${NC} $1"; }
log_error() { echo -e "${RED}[ERROR]${NC} $1" >&2; exit 1; }

PREFIX="${XROOT:-$HOME/xroot}"
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
mkdir -p "$PREFIX"

# 种子包：闭包会递归补齐全部依赖
SEEDS="xvfb x11vnc xauth x11-xkb-utils xkb-data x11-utils fontconfig fonts-dejavu-core \
       libgtk-3-0 libpangocairo-1.0-0 libasound2 libdbus-glib-1-2 libnss3 libnspr4"

# 下载/解包统一在临时目录进行（apt-get download 下到当前目录）
cd "$TMP"

# 不下载的系统核心库：直接用容器自带的，避免 glibc/编译器运行时版本冲突
SKIP="libc6 libgcc-s1 libstdc++6 libgomp1 libitm1 libatomic1 libquadmath0 \
      libtsan2 liblsan0 libubsan1 libasan8 libcc1-0 libgcc1"

APT_OPTS=()        # 阶段1=空(系统源)；阶段2=指向临时 lists
MISSING=""
DL_COUNT=0

# 一次下载（带系统源或临时源选项）
dl() {
    local p="$1"
    if apt-get "${APT_OPTS[@]}" download "$p" >/dev/null 2>&1; then
        DL_COUNT=$((DL_COUNT+1))
        return 0
    fi
    return 1
}

# ---------- 阶段1：直接用系统 apt 源 ----------
log_info "阶段1：用系统 apt 源下载种子包..."
for p in $SEEDS; do
    if dl "$p"; then
        echo "  ok  $p"
    else
        MISSING="$MISSING $p"
    fi
done

# ---------- 阶段2：非 root 临时源（bookworm, trusted=yes） ----------
if [[ -n "$MISSING" ]]; then
    log_warn "阶段1 缺:${MISSING}，改用非 root 的 Debian bookworm 源..."
    local_apt="$TMP/apt"
    mkdir -p "$local_apt/lists/partial" "$local_apt/cache/archives/partial"
    echo "deb [trusted=yes] http://deb.debian.org/debian bookworm main" > "$local_apt/sources.list"
    APT_OPTS=(
        -o "Dir::State::lists=$local_apt/lists"
        -o "Dir::Cache=$local_apt/cache"
        -o "Dir::Etc::sourcelist=$local_apt/sources.list"
        -o "Dir::Etc::sourceparts=-"
        -o "APT::Get::List-Cleanup=0"
    )
    echo "  非 root 更新 bookworm 源..."
    apt-get "${APT_OPTS[@]}" update >/dev/null 2>&1 || {
        cat >&2 <<'EOD'
[ERROR] apt update 失败（deb.debian.org 访问不了/被墙）。
诊断：curl -sI http://deb.debian.org/debian/dists/bookworm/Release | head -1
有代理就先 export http_proxy/https_proxy 再重跑。
EOD
        exit 1
    }
    for p in $MISSING; do
        if dl "$p"; then echo "  ok  $p (bookworm)"; else echo "  skip $p"; fi
    done
fi

# ---------- 依赖闭包：递归把每个包的全部 Depends 拉下来 ----------
log_info "递归解析依赖闭包..."
QUEUE="$SEEDS"
DONE=""
i=0
while [[ -n "$QUEUE" ]]; do
    i=$((i+1))
    (( i > 40 )) && { log_warn "闭包迭代超限，停止"; break; }
    NEXT=""
    for p in $QUEUE; do
        case " $DONE " in *" $p "*) continue;; esac
        DONE="$DONE $p"
        [[ " $SKIP " == *" $p "* ]] && continue
        if dl "$p"; then
            echo "  ok  $p"
        else
            echo "  -   $p (虚拟包/不存在，跳过)"
        fi
        # 收集 Depends/PreDepends（取第一个候选）
        DEPS=$(apt-cache "${APT_OPTS[@]}" depends --no-recommends --no-suggests \
               --no-conflicts --no-breaks --no-replaces --no-enhances "$p" 2>/dev/null \
               | awk -F'[ :<>|]+' '/^  (Depends|PreDepends): /{print $3}')
        NEXT="$NEXT $DEPS"
    done
    QUEUE="$NEXT"
done

# ---------- 解包 ----------
log_info "解包 ${DL_COUNT} 个 .deb 到 $PREFIX ..."
FOUND=0
for f in *.deb; do
    [[ -f "$f" ]] || continue
    dpkg-deb -x "$f" "$PREFIX" 2>/dev/null && FOUND=1
done
[[ "$FOUND" = "0" ]] && log_error "没有下到任何 .deb，请检查网络"

# ---------- 缺失库体检 ----------
LIBDIR=$(find "$PREFIX/usr/lib" -maxdepth 1 -type d -name '*linux-gnu' | head -1)
[[ -z "$LIBDIR" ]] && LIBDIR="$PREFIX/usr/lib"
log_info "依赖体检（ldd）..."
for bin in "$PREFIX/usr/bin/Xvfb" "$PREFIX/usr/bin/x11vnc"; do
    [[ -x "$bin" ]] || continue
    echo "-- $(basename "$bin")"
    MISS=$(LD_LIBRARY_PATH="$LIBDIR:$PREFIX/usr/lib" ldd "$bin" 2>/dev/null | grep "not found" || true)
    if [[ -n "$MISS" ]]; then
        echo "$MISS"
    else
        echo "   依赖完整"
    fi
done

# ---------- 输出提示 ----------
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
echo "# 然后启动:"
echo "XVFB_BIN=\"$PREFIX/usr/bin/Xvfb\" \\"
echo "X11VNC_BIN=\"$PREFIX/usr/bin/x11vnc\" \\"
echo "PYTHON3_BIN=\"\$(command -v python3)\" \\"
echo "bash firefox-tunnel.sh"
