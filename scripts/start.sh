#!/bin/sh
# 启动 TwinGate：按 TWIN_SERVICES 选择性启动 3proxy / ttp / tgmux。
# 项目可能位于 /sdcard/Download 这类 noexec 文件系统，不能从那里执行二进制。
# 本脚本会把 dist/ 下的程序复制到可执行目录后再启动。
set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
# 记录是否由用户显式指定各协议绑定地址（要在 sourcing ports.env 之前）。
_explicit_http_bind=${TWIN_HTTP_BIND+x}
_explicit_socks_bind=${TWIN_SOCKS_BIND+x}
_explicit_ftp_bind=${TWIN_FTP_BIND+x}
. "$ROOT/config/ports.env"
RUNDIR=${TWIN_RUN_DIR:-$ROOT/run}
# 直接调用本脚本时也读取 tgmenu.sh 保存的配置；显式环境变量优先。
. "$ROOT/scripts/load-tui-env.sh"
load_tui_env "$ROOT/config/tui.env"
# tui.env 里显式写出的绑定地址也算用户指定，不应被下面的回环保护覆盖。
if tui_loaded TWIN_HTTP_BIND;  then _explicit_http_bind=x;  fi
if tui_loaded TWIN_SOCKS_BIND; then _explicit_socks_bind=x; fi
if tui_loaded TWIN_FTP_BIND;   then _explicit_ftp_bind=x;   fi
CERTDIR=${TWIN_CERT_DIR:-$ROOT/run/certs}
mkdir -p "$RUNDIR" "$TWIN_LOG_DIR"

if [ "${TWIN_AUTH:-0}" = 1 ] &&
   [ "${TWIN_AUTH_USER:-}" = twingate ] && [ "${TWIN_AUTH_PASS:-}" = twingate123 ]; then
    echo "[auth] 警告：正在使用默认凭据 twingate / twingate123。"
    echo "[auth] 请用 tgmenu.sh 的「配置 -> 认证设置」修改，或设 TWIN_AUTH=0 关闭。"
fi

# ---------------- 确定要开放哪些服务 ----------------
DEFAULT_SERVICES="http-tls http-plain socks-tls socks-plain ftp-tls ftp-plain"
if [ "$TWIN_MIXED" = 1 ]; then
    DEFAULT_SERVICES="mixed-tls mixed-plain"
fi
if [ -n "$TWIN_SERVICES" ]; then
    SERVICES=$(printf '%s\n' "$TWIN_SERVICES" | tr ',' ' ' | tr -s ' ' | sed 's/^ //; s/ $//')
else
    SERVICES=$DEFAULT_SERVICES
fi

has_service() {
    case " $SERVICES " in
        *" $1 "*) return 0 ;;
        *) return 1 ;;
    esac
}

for s in $SERVICES; do
    case "$s" in
        http-tls|http-plain|socks-tls|socks-plain|ftp-tls|ftp-plain|mixed-tls|mixed-plain) ;;
        *)
            echo "[start] 未知服务：$s" >&2
            echo "[start] 可用：http-tls http-plain socks-tls socks-plain ftp-tls ftp-plain mixed-tls mixed-plain" >&2
            exit 1
            ;;
    esac
done

need_http=0; need_socks=0; need_ftp=0; need_mux=0
if has_service http-plain || has_service http-tls || \
   has_service mixed-plain || has_service mixed-tls; then
    need_http=1
fi
if has_service socks-plain || has_service socks-tls || \
   has_service mixed-plain || has_service mixed-tls; then
    need_socks=1
fi
if has_service ftp-plain || has_service ftp-tls || \
   has_service mixed-plain || has_service mixed-tls; then
    need_ftp=1
fi
if has_service mixed-plain || has_service mixed-tls; then
    need_mux=1
fi
export TWIN_NEED_HTTP="$need_http" TWIN_NEED_SOCKS="$need_socks" TWIN_NEED_FTP="$need_ftp"

# 未对外开放的明文服务，其内部后端强制只绑回环：ttp/tgmux 都从本机连接。
# 用户显式设置 TWIN_HTTP_BIND/TWIN_SOCKS_BIND/TWIN_FTP_BIND 时尊重其选择。
if [ "$_explicit_http_bind" != x ] && ! has_service http-plain; then
    TWIN_HTTP_BIND=127.0.0.1
fi
if [ "$_explicit_socks_bind" != x ] && ! has_service socks-plain; then
    TWIN_SOCKS_BIND=127.0.0.1
fi
if [ "$_explicit_ftp_bind" != x ] && ! has_service ftp-plain; then
    TWIN_FTP_BIND=127.0.0.1
fi
export TWIN_HTTP_BIND TWIN_SOCKS_BIND TWIN_FTP_BIND

[ -f "$ROOT/dist/3proxy" ] || { echo "请先执行 scripts/build.sh" >&2; exit 1; }
[ -f "$ROOT/dist/ttp" ] || { echo "请先执行 scripts/build.sh" >&2; exit 1; }
if [ "$need_mux" = 1 ]; then
    [ -f "$ROOT/dist/tgmux" ] || { echo "缺少 dist/tgmux，请先执行 scripts/build.sh" >&2; exit 1; }
fi
[ -f "$CERTDIR/ttp.env" ] || { echo "缺少证书，请先执行 scripts/gen-certs.sh" >&2; exit 1; }
. "$CERTDIR/ttp.env"

check_exec_dir() {
    d=$1
    mkdir -p "$d" 2>/dev/null || return 1
    [ -w "$d" ] || return 1
    probe="$d/.tg-exec-test.$$"
    printf '#!/bin/sh\nexit 0\n' > "$probe" 2>/dev/null || return 1
    chmod 755 "$probe" 2>/dev/null || { rm -f "$probe"; return 1; }
    if "$probe" >/dev/null 2>&1; then
        rm -f "$probe"
        return 0
    fi
    rm -f "$probe"
    return 1
}

find_runtime_dir() {
    if [ -n "${TWIN_RUNTIME_DIR:-}" ]; then
        check_exec_dir "$TWIN_RUNTIME_DIR" && { printf '%s\n' "$TWIN_RUNTIME_DIR"; return 0; }
        return 1
    fi
    for cand in \
        "${HOME:-}/.twingate/bin" \
        "${TMPDIR:-}/twingate-bin" \
        /data/local/tmp/twingate-bin \
        /data/data/com.termux/files/usr/tmp/twingate-bin \
        /tmp/twingate-bin
    do
        [ -n "$cand" ] || continue
        check_exec_dir "$cand" && { printf '%s\n' "$cand"; return 0; }
    done
    return 1
}

RUNTIME_DIR=$(find_runtime_dir) || {
    echo "[start] 找不到可执行且可写的目录。" >&2
    echo "[start] 请设置 TWIN_RUNTIME_DIR=<可执行目录> 后重试。" >&2
    exit 1
}
mkdir -p "$RUNTIME_DIR"
printf '%s\n' "$RUNTIME_DIR" > "$RUNDIR/runtime-dir"
printf '%s\n' "$SERVICES" > "$RUNDIR/services"

# 记录本次真正对外监听的端口，供 status.sh 显示（可包含命令行临时覆盖值）。
LISTEN_PORTS=""
if has_service http-tls;  then LISTEN_PORTS="$LISTEN_PORTS $TWIN_HTTP_TLS"; fi
if has_service http-plain; then LISTEN_PORTS="$LISTEN_PORTS $TWIN_HTTP_PLAIN"; fi
if has_service socks-tls; then LISTEN_PORTS="$LISTEN_PORTS $TWIN_SOCKS_TLS"; fi
if has_service socks-plain; then LISTEN_PORTS="$LISTEN_PORTS $TWIN_SOCKS_PLAIN"; fi
if has_service ftp-tls;   then LISTEN_PORTS="$LISTEN_PORTS $TWIN_FTP_TLS"; fi
if has_service ftp-plain; then LISTEN_PORTS="$LISTEN_PORTS $TWIN_FTP_PLAIN"; fi
if has_service mixed-tls; then LISTEN_PORTS="$LISTEN_PORTS $TWIN_MIXED_TLS"; fi
if has_service mixed-plain; then LISTEN_PORTS="$LISTEN_PORTS $TWIN_MUX_PLAIN"; fi
printf '%s\n' "$LISTEN_PORTS" | sed 's/^ *//; s/ *$//' > "$RUNDIR/listen-ports"

echo "[start] 运行时目录：$RUNTIME_DIR"
echo "[start] 开放服务：$SERVICES"

# 从 noexec 的项目目录复制到可执行目录。
BINS="3proxy ttp"
[ "$need_mux" = 1 ] && BINS="$BINS tgmux"
for bin in $BINS; do
    # 先写临时文件再原子替换：若旧进程尚未完全退出，直接 cp 覆盖会报 Text file busy。
    tmpbin="$RUNTIME_DIR/$bin.new.$$"
    cp "$ROOT/dist/$bin" "$tmpbin"
    chmod 755 "$tmpbin"
    mv -f "$tmpbin" "$RUNTIME_DIR/$bin"
done

# Android 上必须确认是 bionic 二进制。
# 宿主机 gcc 编出来的二进制 interpreter 是 /lib64/ld-linux-x86-64.so.2，
# 在 Android 上执行会报 "not found"，这里提前给出明确原因。
if [ -e /system/bin/linker64 ]; then
    for bin in $BINS; do
        if grep -aq '/lib64/ld-linux' "$RUNTIME_DIR/$bin" 2>/dev/null; then
            echo "[start] $bin 是 glibc 链接的二进制，无法在 Android/bionic 上运行。" >&2
            echo "[start] 请在容器内重新执行 scripts/build.sh；不要用宿主机 dist/ 覆盖容器产物。" >&2
            exit 1
        fi
    done
fi

sh "$ROOT/scripts/render-config.sh" "$RUNDIR/3proxy.cfg"

start_one() {
    name=$1; shift
    "$@" >"$TWIN_LOG_DIR/$name.out" 2>&1 &
    echo $! > "$RUNDIR/$name.pid"
    echo "[start] $name pid=$!"
}

start_ttp() {
    name=$1 listen=$2 target=$3
    env TTP_LISTEN_PORT="$listen" \
        TTP_TARGET_HOST=127.0.0.1 \
        TTP_TARGET_PORT="$target" \
        TTP_LOG_PATH="$TWIN_LOG_DIR/$name.log" \
        TTP_SERVER_CERT_B64="$TTP_SERVER_CERT_B64" \
        TTP_SERVER_KEY_B64="$TTP_SERVER_KEY_B64" \
        "$RUNTIME_DIR/ttp" >"$TWIN_LOG_DIR/$name.out" 2>&1 &
    echo $! > "$RUNDIR/$name.pid"
    echo "[start] $name pid=$! listen=$listen -> 127.0.0.1:$target"
}

if [ "$need_http$need_socks$need_ftp" != 000 ]; then
    start_one 3proxy "$RUNTIME_DIR/3proxy" "$RUNDIR/3proxy.cfg"
fi

if [ "$need_mux" = 1 ]; then
    export TWIN_MUX_PEEK_MS
    start_one tgmux "$RUNTIME_DIR/tgmux" \
        "$TWIN_MUX_PLAIN" "$TWIN_HTTP_PLAIN" "$TWIN_SOCKS_PLAIN" \
        "$TWIN_FTP_PLAIN" "$TWIN_MUX_BIND"
fi

if has_service http-tls; then
    start_ttp ttp-http "$TWIN_HTTP_TLS" "$TWIN_HTTP_PLAIN"
fi
if has_service socks-tls; then
    start_ttp ttp-socks "$TWIN_SOCKS_TLS" "$TWIN_SOCKS_PLAIN"
fi
if has_service ftp-tls; then
    start_ttp ttp-ftp "$TWIN_FTP_TLS" "$TWIN_FTP_PLAIN"
fi
if has_service mixed-tls; then
    start_ttp ttp-mixed "$TWIN_MIXED_TLS" "$TWIN_MUX_PLAIN"
fi

echo "[start] 完成。运行 scripts/status.sh 查看状态。"
