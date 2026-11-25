#!/bin/sh
# TwinGate 运行逻辑（函数库）。
#
# 源码树模式：由 tgmenu.sh source 本文件。
# 安装模式：scripts/install.sh 把本文件内容直接内嵌到 <prefix>/bin/twingate，
#           因此安装后只有这一个脚本 + lib 目录下的几个二进制，不再复制脚本树。
#
# 所有函数都依赖 scripts/paths.sh 已先行执行 twin_init_paths。

# 上游 SOCKS5（parent）逻辑：源码树下从 scripts/parent.sh 加载；
# 安装模式下 install.sh 已把该文件内嵌进 twingate，函数直接可用。
if ! command -v twin_parent_resolve >/dev/null 2>&1; then
    if [ -n "${TWIN_ROOT:-}" ] && [ -f "$TWIN_ROOT/scripts/parent.sh" ]; then
        . "$TWIN_ROOT/scripts/parent.sh"
    fi
fi

# 进程生命周期辅助（重复启动拦截、遗留进程回收）：同样是源码树加载 + 安装模式内嵌。
if ! command -v twin_start_guard >/dev/null 2>&1; then
    if [ -n "${TWIN_ROOT:-}" ] && [ -f "$TWIN_ROOT/scripts/lifecycle.sh" ]; then
        . "$TWIN_ROOT/scripts/lifecycle.sh"
    fi
fi

# TUN 虚拟网卡接力（出站绑定）：同样是源码树加载 + 安装模式内嵌。
if ! command -v twin_tun_resolve >/dev/null 2>&1; then
    if [ -n "${TWIN_ROOT:-}" ] && [ -f "$TWIN_ROOT/scripts/tun.sh" ]; then
        . "$TWIN_ROOT/scripts/tun.sh"
    fi
fi

# ---------------------------------------------------------------- 配置加载

# 注意：本文件在安装模式下会被内嵌进单文件 twingate，所以这里的加载器
# 与 scripts/load-tui-env.sh 是同一套逻辑的两份实现，改一处必须改另一处。
TUI_LOADED_KEYS=""
TUI_EXPLICIT_KEYS=""

twin_snapshot_explicit() {
    TUI_EXPLICIT_KEYS=""
    for _k in $(set | sed -n 's/^\(TWIN_[A-Za-z0-9_]*\)=.*/\1/p'); do
        TUI_EXPLICIT_KEYS="$TUI_EXPLICIT_KEYS $_k"
    done
}

twin_explicit_key() {
    case " ${TUI_EXPLICIT_KEYS:-} " in
        *" $1 "*) return 0 ;;
        *) return 1 ;;
    esac
}

# 顺序：记录显式环境变量 -> 加载 tui.env -> 套用内嵌/文件端口默认值。
twin_ports_init() {
    [ "${TWIN_PORTS_INITIALIZED:-0}" = 1 ] && return 0
    twin_snapshot_explicit
    twin_load_tui_env "$TWIN_TUI_ENV"
    if command -v twin_embedded_ports >/dev/null 2>&1; then
        eval "$(twin_embedded_ports)"
    elif [ -f "$TWIN_CONFIG_DIR/ports.env" ]; then
        . "$TWIN_CONFIG_DIR/ports.env"
    elif [ -f "$TWIN_ROOT/config/ports.env" ]; then
        # 配置目录被 --config-dir 指到别处且没带 ports.env 时，退回源码树默认值。
        . "$TWIN_ROOT/config/ports.env"
    fi
    TWIN_PORTS_INITIALIZED=1
    export TWIN_PORTS_INITIALIZED
}

twin_load_tui_env() {
    TUI_LOADED_KEYS=""
    _cfg=${1:-}
    [ -f "$_cfg" ] || return 0
    _src=""
    _nl='
'
    while IFS= read -r _line || [ -n "$_line" ]; do
        case "$_line" in
            ''|\#*) continue ;;
            *=*) ;;
            *) continue ;;
        esac
        _k=${_line%%=*}
        case "$_k" in
            [A-Za-z_]*[A-Za-z0-9_]*) ;;
            *) continue ;;
        esac
        twin_explicit_key "$_k" && continue
        _src="$_src$_line$_nl"
        TUI_LOADED_KEYS="$TUI_LOADED_KEYS $_k"
    done < "$_cfg"
    [ -n "$_src" ] && eval "$_src"
    return 0
}

twin_tui_loaded() {
    case " $TUI_LOADED_KEYS " in
        *" $1 "*) return 0 ;;
        *) return 1 ;;
    esac
}

# 兼容旧名字，供直接调用 scripts/start.sh 等使用。
load_tui_env() { twin_load_tui_env "$@"; }
tui_loaded()   { twin_tui_loaded "$@"; }

twin_template() {
    if command -v twin_embedded_tpl >/dev/null 2>&1; then
        twin_embedded_tpl
    else
        cat "$TWIN_CONFIG_DIR/3proxy.cfg.tpl"
    fi
}

# ---------------------------------------------------------------- 配置渲染

twin_render_config() {
    # twin_ports_init 已按「显式环境变量 -> tui.env -> 默认值」的顺序把配置装好，
    # 这里不再重复加载，避免把启动阶段改过的绑定地址又覆盖回 tui.env 的旧值。
    twin_ports_init

    OUT=${1:-${TWIN_CONFIG_PATH:-$TWIN_3PROXY_CFG}}
    mkdir -p "$(dirname "$OUT")" "$TWIN_LOG_DIR" || return 1
    twin_template > "$OUT" || return 1

    for k in TWIN_HTTP_PLAIN TWIN_SOCKS_PLAIN TWIN_FTP_PLAIN TWIN_DNS_SERVER \
             TWIN_EXTERNAL TWIN_LOG_DIR TWIN_PLAIN_BIND \
             TWIN_HTTP_BIND TWIN_SOCKS_BIND TWIN_FTP_BIND TWIN_TIMEOUTS; do
        eval "val=\${$k:-}"
        esc=$(printf '%s' "$val" | sed -e 's/[\/&]/\\&/g')
        sed -i "s|\${$k}|$esc|g" "$OUT"
    done

    # 与 scripts/render-config.sh 同一套校验：11 个正整数，写错就拒绝生成。
    _tmo_count=0
    _tmo_bad=0
    for _t in ${TWIN_TIMEOUTS:-}; do
        case "$_t" in
            ''|*[!0-9]*) _tmo_bad=1 ;;
            *) [ "$_t" -gt 0 ] || _tmo_bad=1 ;;
        esac
        _tmo_count=$((_tmo_count + 1))
    done
    if [ "$_tmo_bad" = 1 ] || [ "$_tmo_count" -ne 11 ]; then
        echo "[config] timeouts 需要 11 个正整数，当前是 $_tmo_count 个：${TWIN_TIMEOUTS:-}" >&2
        echo "[config] 顺序：SINGLEBYTE_S SINGLEBYTE_L STRING_S STRING_L CONNECTION_S CONNECTION_L" >&2
        echo "[config]       DNS_TO CHAIN_TO CONNECT_TO CONNBACK_TO LINGER_TO" >&2
        return 1
    fi

    # 上游 SOCKS5 先解析：auth none 下 3proxy 不检查 ACL，parent 也需要 authorizer。
    if command -v twin_parent_resolve >/dev/null 2>&1; then
        twin_parent_resolve || return 1
    fi

    if [ "${TWIN_AUTH:-0}" = 1 ]; then
        case "${TWIN_AUTH_USER:-}" in
            ''|*[!A-Za-z0-9_.@-]*) echo "[config] TWIN_AUTH_USER 只允许字母数字和 . _ @ -" >&2; return 1 ;;
        esac
        case "${TWIN_AUTH_PASS:-}" in
            ''|*[!A-Za-z0-9_.@-]*) echo "[config] TWIN_AUTH_PASS 只允许字母数字和 . _ @ -" >&2; return 1 ;;
        esac
        sed -i "s|__TWIN_USERS_LINE__|users ${TWIN_AUTH_USER}:CL:${TWIN_AUTH_PASS}|" "$OUT"
        sed -i 's|__TWIN_AUTH_MODE__|auth strong|' "$OUT"
        sed -i "s|__TWIN_ALLOW__|${TWIN_AUTH_USER}|g" "$OUT"
        echo "[config] 认证已开启：用户 ${TWIN_AUTH_USER}"
    else
        sed -i 's|__TWIN_USERS_LINE__|# 认证已关闭（TWIN_AUTH=0）|' "$OUT"
        if [ "${PARENT_ON:-0}" = 1 ]; then
            # 保留 ACL 检查，parent 才能生效（iponly 不校验密码）
            sed -i 's|__TWIN_AUTH_MODE__|auth iponly|' "$OUT"
            echo "[config] 认证已关闭，但为让上游 parent 生效改用 auth iponly（仍不校验密码）"
        else
            sed -i 's|__TWIN_AUTH_MODE__|auth none|' "$OUT"
            echo "[config] 认证已关闭：任何客户端均可连接（TWIN_AUTH=0）"
        fi
        sed -i 's|__TWIN_ALLOW__|* * * *|g' "$OUT"
    fi

    [ "${TWIN_NEED_HTTP:-1}" = 1 ] || sed -i '/^# @service:http$/,/^# @end$/d' "$OUT"
    [ "${TWIN_NEED_SOCKS:-1}" = 1 ] || sed -i '/^# @service:socks$/,/^# @end$/d' "$OUT"
    [ "${TWIN_NEED_FTP:-1}" = 1 ] || sed -i '/^# @service:ftp$/,/^# @end$/d' "$OUT"

    # 上游 SOCKS5：必须在 allow 行落地之后注入（parent 挂在最后一条 allow 上）
    if command -v twin_parent_apply >/dev/null 2>&1; then
        twin_parent_apply "$OUT" || return 1
        if [ "${PARENT_ON:-0}" = 1 ]; then
            echo "[config] 上游 SOCKS5：$PARENT_DESC"
        fi
    fi

    # TUN 虚拟网卡接力：在服务行上追加 -De<dev> / -e<ip>，同样要等模板落盘之后。
    if command -v twin_tun_resolve >/dev/null 2>&1; then
        twin_tun_resolve || return 1
        twin_tun_apply_cfg "$OUT" || return 1
        if [ "${TUN_ON:-0}" = 1 ]; then
            echo "[config] TUN 接力：$(twin_tun_desc)"
        fi
    fi
    echo "[config] 已生成 $OUT"
}

# ---------------------------------------------------------------- 启动

twin_check_exec_dir() {
    d=$1
    mkdir -p "$d" 2>/dev/null || return 1
    [ -w "$d" ] || return 1
    probe="$d/.tg-exec-test.$$"
    printf '#!/bin/sh\nexit 0\n' > "$probe" 2>/dev/null || return 1
    chmod 755 "$probe" 2>/dev/null || { rm -f "$probe"; return 1; }
    if "$probe" >/dev/null 2>&1; then rm -f "$probe"; return 0; fi
    rm -f "$probe"
    return 1
}

twin_find_runtime_dir() {
    if [ -n "${TWIN_RUNTIME_DIR:-}" ]; then
        twin_check_exec_dir "$TWIN_RUNTIME_DIR" && { printf '%s\n' "$TWIN_RUNTIME_DIR"; return 0; }
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
        twin_check_exec_dir "$cand" && { printf '%s\n' "$cand"; return 0; }
    done
    return 1
}

twin_start() {
    # 显式环境变量优先；随后 tui.env 里写出的绑定键也算显式。
    # 这两个判断必须在 twin_ports_init（补默认值）之前，否则每个键都"已存在"。
    _explicit_http_bind=${TWIN_HTTP_BIND+x}
    _explicit_socks_bind=${TWIN_SOCKS_BIND+x}
    _explicit_ftp_bind=${TWIN_FTP_BIND+x}
    twin_ports_init
    if twin_tui_loaded TWIN_HTTP_BIND;  then _explicit_http_bind=x;  fi
    if twin_tui_loaded TWIN_SOCKS_BIND; then _explicit_socks_bind=x; fi
    if twin_tui_loaded TWIN_FTP_BIND;   then _explicit_ftp_bind=x;   fi

    if [ "${TWIN_AUTH:-0}" = 1 ] &&
       [ "${TWIN_AUTH_USER:-}" = twingate ] && [ "${TWIN_AUTH_PASS:-}" = twingate123 ]; then
        echo "[auth] 警告：正在使用默认凭据 twingate / twingate123。"
        if [ "${TWIN_INSTALLED:-0}" = 1 ]; then
            echo "[auth] 请用 'twingate config' 的认证设置修改，或设 TWIN_AUTH=0 关闭。"
        else
            echo "[auth] 请用 tgmenu.sh 的「配置 -> 认证设置」修改，或设 TWIN_AUTH=0 关闭。"
        fi
    fi

    DEFAULT_SERVICES="http-tls http-plain socks-tls socks-plain ftp-tls ftp-plain"
    if [ "${TWIN_MIXED:-0}" = 1 ]; then DEFAULT_SERVICES="mixed-tls mixed-plain"; fi
    if [ -n "${TWIN_SERVICES:-}" ]; then
        SERVICES=$(printf '%s\n' "$TWIN_SERVICES" | tr ',' ' ' | tr -s ' ' | sed 's/^ //; s/ $//')
    else
        SERVICES=$DEFAULT_SERVICES
    fi

    for s in $SERVICES; do
        case "$s" in
            http-tls|http-plain|socks-tls|socks-plain|ftp-tls|ftp-plain|mixed-tls|mixed-plain) ;;
            *) echo "[start] 未知服务：$s" >&2
               echo "[start] 可用：http-tls http-plain socks-tls socks-plain ftp-tls ftp-plain mixed-tls mixed-plain" >&2
               return 1 ;;
        esac
    done

    twin_has_svc() { case " $SERVICES " in *" $1 "*) return 0 ;; *) return 1 ;; esac; }
    need_http=0; need_socks=0; need_ftp=0; need_mux=0
    if twin_has_svc http-tls || twin_has_svc http-plain || \
       twin_has_svc mixed-tls || twin_has_svc mixed-plain; then need_http=1; fi
    if twin_has_svc socks-tls || twin_has_svc socks-plain || \
       twin_has_svc mixed-tls || twin_has_svc mixed-plain; then need_socks=1; fi
    if twin_has_svc ftp-tls || twin_has_svc ftp-plain || \
       twin_has_svc mixed-tls || twin_has_svc mixed-plain; then need_ftp=1; fi
    if twin_has_svc mixed-tls || twin_has_svc mixed-plain; then need_mux=1; fi
    export TWIN_NEED_HTTP=$need_http TWIN_NEED_SOCKS=$need_socks TWIN_NEED_FTP=$need_ftp

    if [ "$_explicit_http_bind" != x ] && ! twin_has_svc http-plain; then TWIN_HTTP_BIND=127.0.0.1; fi
    if [ "$_explicit_socks_bind" != x ] && ! twin_has_svc socks-plain; then TWIN_SOCKS_BIND=127.0.0.1; fi
    if [ "$_explicit_ftp_bind" != x ] && ! twin_has_svc ftp-plain; then TWIN_FTP_BIND=127.0.0.1; fi
    export TWIN_HTTP_BIND TWIN_SOCKS_BIND TWIN_FTP_BIND

    # 二进制目录随模式变化：安装模式在 $TWIN_ROOT，源码树在 $TWIN_ROOT/dist。
    BINDIR=$(twin_bin_dir)
    [ -f "$BINDIR/3proxy" ] || { echo "[start] 缺少 $BINDIR/3proxy，请先构建并安装。" >&2; return 1; }
    [ -f "$BINDIR/ttp" ]    || { echo "[start] 缺少 $BINDIR/ttp，请先构建并安装。" >&2; return 1; }
    if [ "$need_mux" = 1 ]; then
        [ -f "$BINDIR/tgmux" ] || { echo "[start] 缺少 $BINDIR/tgmux，请重新构建并安装。" >&2; return 1; }
    fi
    [ -f "$TWIN_CERT_DIR/ttp.env" ] || {
        echo "[start] 缺少证书，请先执行 'twingate certs' 或 tgmenu.sh 的证书生成。" >&2
        return 1
    }
    . "$TWIN_CERT_DIR/ttp.env"

    RUNDIR=$TWIN_RUN_DIR
    mkdir -p "$RUNDIR" "$TWIN_LOG_DIR" || return 1
    # 已在运行就拒绝：否则新进程抢不到端口立刻退出，还会把 pid 文件覆盖成死 pid，
    # 老进程从此没有记录（stop 杀不到、start 起不来，只能重启容器）。
    twin_start_guard "$RUNDIR" || return 1
    RUNTIME_DIR=$(twin_find_runtime_dir) || {
        echo "[start] 找不到可执行且可写的目录；请设置 TWIN_RUNTIME_DIR。" >&2
        return 1
    }
    mkdir -p "$RUNTIME_DIR"
    printf '%s\n' "$RUNTIME_DIR" > "$RUNDIR/runtime-dir"
    printf '%s\n' "$SERVICES" > "$RUNDIR/services"

    # 上游 SOCKS5（parent 链式出口）：配置非法时直接拒绝启动。
    twin_parent_resolve || return 1
    twin_parent_write_state "$RUNDIR"
    if [ "${PARENT_ON:-0}" = 1 ]; then
        echo "[start] 上游 SOCKS5：$PARENT_DESC"
    fi

    # TUN 虚拟网卡接力：探测网卡与权限，结果写进运行状态供 status 显示。
    twin_tun_resolve || return 1
    twin_tun_write_state "$RUNDIR"
    if [ "${TUN_ON:-0}" = 1 ]; then
        echo "[start] TUN 接力：$(twin_tun_desc)"
    fi

    LISTEN_PORTS=""
    twin_has_svc http-tls    && LISTEN_PORTS="$LISTEN_PORTS $TWIN_HTTP_TLS"
    twin_has_svc http-plain  && LISTEN_PORTS="$LISTEN_PORTS $TWIN_HTTP_PLAIN"
    twin_has_svc socks-tls   && LISTEN_PORTS="$LISTEN_PORTS $TWIN_SOCKS_TLS"
    twin_has_svc socks-plain && LISTEN_PORTS="$LISTEN_PORTS $TWIN_SOCKS_PLAIN"
    twin_has_svc ftp-tls     && LISTEN_PORTS="$LISTEN_PORTS $TWIN_FTP_TLS"
    twin_has_svc ftp-plain   && LISTEN_PORTS="$LISTEN_PORTS $TWIN_FTP_PLAIN"
    twin_has_svc mixed-tls   && LISTEN_PORTS="$LISTEN_PORTS $TWIN_MIXED_TLS"
    twin_has_svc mixed-plain && LISTEN_PORTS="$LISTEN_PORTS $TWIN_MUX_PLAIN"
    printf '%s\n' "$LISTEN_PORTS" | sed 's/^ *//; s/ *$//' > "$RUNDIR/listen-ports"

    echo "[start] 运行时目录：$RUNTIME_DIR"
    echo "[start] 开放服务：$SERVICES"

    BINS="3proxy ttp"
    [ "$need_mux" = 1 ] && BINS="$BINS tgmux"
    for bin in $BINS; do
        tmpbin="$RUNTIME_DIR/$bin.new.$$"
        cp "$BINDIR/$bin" "$tmpbin" || return 1
        chmod 755 "$tmpbin"
        mv -f "$tmpbin" "$RUNTIME_DIR/$bin" || return 1
    done

    if [ -e /system/bin/linker64 ]; then
        for bin in $BINS; do
            if grep -aq '/lib64/ld-linux' "$RUNTIME_DIR/$bin" 2>/dev/null; then
                echo "[start] $bin 是 glibc 二进制，无法在 Android/bionic 上运行。" >&2
                return 1
            fi
        done
    fi

    twin_render_config "$TWIN_3PROXY_CFG" || return 1

    twin_start_one() {
        name=$1; shift
        "$@" >"$TWIN_LOG_DIR/$name.out" 2>&1 &
        echo $! > "$TWIN_RUN_DIR/$name.pid"
        echo "[start] $name pid=$!"
    }
    twin_start_ttp() {
        name=$1 listen=$2 target=$3
        env TTP_LISTEN_PORT="$listen" \
            TTP_TARGET_HOST=127.0.0.1 \
            TTP_TARGET_PORT="$target" \
            TTP_LOG_PATH="$TWIN_LOG_DIR/$name.log" \
            TTP_SERVER_CERT_B64="$TTP_SERVER_CERT_B64" \
            TTP_SERVER_KEY_B64="$TTP_SERVER_KEY_B64" \
            "$RUNTIME_DIR/ttp" >"$TWIN_LOG_DIR/$name.out" 2>&1 &
        echo $! > "$TWIN_RUN_DIR/$name.pid"
        echo "[start] $name pid=$! listen=$listen -> 127.0.0.1:$target"
    }

    if [ "$need_http$need_socks$need_ftp" != 000 ]; then
        twin_start_one 3proxy "$RUNTIME_DIR/3proxy" "$TWIN_3PROXY_CFG"
    fi
    if [ "$need_mux" = 1 ]; then
        export TWIN_MUX_PEEK_MS TWIN_MUX_FTP_GRACE_MS
        twin_start_one tgmux "$RUNTIME_DIR/tgmux" \
            "$TWIN_MUX_PLAIN" "$TWIN_HTTP_PLAIN" "$TWIN_SOCKS_PLAIN" \
            "$TWIN_FTP_PLAIN" "$TWIN_MUX_BIND"
    fi
    twin_has_svc http-tls   && twin_start_ttp ttp-http "$TWIN_HTTP_TLS" "$TWIN_HTTP_PLAIN"
    twin_has_svc socks-tls  && twin_start_ttp ttp-socks "$TWIN_SOCKS_TLS" "$TWIN_SOCKS_PLAIN"
    twin_has_svc ftp-tls    && twin_start_ttp ttp-ftp "$TWIN_FTP_TLS" "$TWIN_FTP_PLAIN"
    twin_has_svc mixed-tls  && twin_start_ttp ttp-mixed "$TWIN_MIXED_TLS" "$TWIN_MUX_PLAIN"

    sleep 2
    if ! twin_check_started "$RUNDIR" "$TWIN_LOG_DIR"; then
        twin_kill_pidfiles "$RUNDIR"
        echo "[start] 启动未完成，已回滚本次启动的进程。" >&2
        return 1
    fi
    echo "[start] 完成。运行 'twingate status' 查看状态。"
}

# ---------------------------------------------------------------- 停止 / 状态

twin_stop() {
    twin_kill_pidfiles "$TWIN_RUN_DIR"
    # 重复启动曾把 pid 文件覆盖成死 pid，老进程可能仍在监听；按 runtime 目录回收。
    twin_sweep_orphans "$TWIN_RUN_DIR"
}

# 从运行中的 3proxy.cfg 里取 nserver 与超时，实际测一次解析。
#
# 为什么要有这一段：`nserver` 是明文 UDP 53，不走 TUN 绑定，也未必能过上游代理。
# 配了一个容器里根本到不了的 DNS（典型是 8.8.8.8）时，症状是"第一次好几秒、
# 之后 2~3 秒"，而且 3proxy 自己不会报错——它只是等满 DNS_TO 再放弃。
# 这里主动量一下，把"配置值 vs 实测"并排显示出来，一眼能看出是不是它。
twin_status_dns() {
    _dns_dir=$1
    _cfg=""
    for _c in "$TWIN_3PROXY_CFG" "$_dns_dir/3proxy.cfg"; do
        [ -f "$_c" ] && { _cfg=$_c; break; }
    done
    [ -n "$_cfg" ] || return 0
    _ns=$(sed -n 's/^nserver[[:space:]]*\([^[:space:]]*\).*/\1/p' "$_cfg" | head -1)
    _tmo=$(sed -n 's/^timeouts[[:space:]]*//p' "$_cfg" | head -1)
    [ -n "$_ns" ] || return 0
    # 第 7 位是 DNS_TO，第 9 位是 CONNECT_TO
    _dns_to=$(printf '%s\n' "$_tmo" | cut -d' ' -f7)
    _conn_to=$(printf '%s\n' "$_tmo" | cut -d' ' -f9)

    echo "=== DNS ==="
    echo "nserver      $_ns（DNS_TO=${_dns_to:-?}s CONNECT_TO=${_conn_to:-?}s）"

    # 去掉 :port，还原成主机名/地址；IPv6 的 [addr]:port 形式也照顾到。
    _nshost=$_ns
    case "$_ns" in
        \[*\]:*) _nshost=${_ns%]:*} ;;      # [::1]:53
        \[*\])   _nshost=${_ns#\[}; _nshost=${_nshost%\]} ;;
        *:*:*)   : ;;                        # 裸 IPv6，端口是默认的 53
        *:*)     _nshost=${_ns%:*} ;;
    esac

    # 真的发一个 DNS 查询，量往返时间。用 Python 而不是 getent/nslookup：
    # 后两者走系统解析器、查缓存，量不到 3proxy 那条路径。
    _py=""
    for _cand in python3 python; do
        command -v "$_cand" >/dev/null 2>&1 && { _py=$_cand; break; }
    done
    if [ -z "$_py" ]; then
        echo "（没有 python，跳过解析实测；可用 nslookup 手工验证）"
        return 0
    fi
    "$_py" - "$_nshost" "${_dns_to:-15}" <<'PY' 2>/dev/null || echo "解析实测失败（超时或不可达）"
import socket, struct, sys, time

host = sys.argv[1]
dns_to = sys.argv[2]
port = 53
if host.startswith("[") and "]:" in host:
    host, port = host[1:].split("]:")
port = int(port)
# 一个最小的 A 查询：example.com
q = struct.pack(">HHHHHH", 0x1234, 0x0100, 1, 0, 0, 0)
for label in b"example.com".split(b"."):
    q += bytes([len(label)]) + label
q += b"\x00" + struct.pack(">HH", 1, 1)

s = socket.socket(socket.AF_INET6 if ":" in host else socket.AF_INET,
                  socket.SOCK_DGRAM)
s.settimeout(6)
t0 = time.perf_counter()
try:
    s.sendto(q, (host, port))
    s.recvfrom(2048)
    ms = (time.perf_counter() - t0) * 1000
    print("实测解析     %.1f ms（example.com，明文 UDP）" % ms)
except socket.timeout:
    print("实测解析     超时 >6s —— 这个 DNS 从容器里到不了，")
    print("             每次新域名都会等满 DNS_TO=" + dns_to + "s 才继续。")
except OSError as e:
    print("实测解析     失败：%s" % e)
PY
    case "$_dns_to" in
        ''|*[!0-9]*) ;;
        *)
            if [ "$_dns_to" -ge 10 ]; then
                echo "提示：DNS_TO 是 ${_dns_to}s，一旦解析不到就要干等这么久；"
                echo "     把它收紧到 5（TWIN_DNS_TO=5），或换成本机可达的 DNS。"
            fi
            ;;
    esac
}

twin_status() {
    twin_ports_init
    RUNDIR=$TWIN_RUN_DIR
    if [ -f "$RUNDIR/listen-ports" ]; then
        PORTS=$(cat "$RUNDIR/listen-ports")
    else
        PORTS="$TWIN_HTTP_TLS $TWIN_HTTP_PLAIN $TWIN_SOCKS_TLS $TWIN_SOCKS_PLAIN \
$TWIN_FTP_TLS $TWIN_FTP_PLAIN $TWIN_MUX_PLAIN $TWIN_MIXED_TLS"
    fi
    PORT_RE=$(printf '%s\n' "$PORTS" | sed 's/^ *//; s/ *$//' | tr -s ' ' '|')

    [ -f "$RUNDIR/runtime-dir" ] && { echo "=== RUNTIME ==="; cat "$RUNDIR/runtime-dir"; }
    [ -f "$RUNDIR/services" ] && { echo "=== SERVICES ==="; cat "$RUNDIR/services"; }
    [ -f "$RUNDIR/parent" ] && { echo "=== PARENT ==="; cat "$RUNDIR/parent"; }
    [ -f "$RUNDIR/tun" ] && { echo "=== TUN ==="; cat "$RUNDIR/tun"; }
    twin_status_dns "$RUNDIR"

    echo "=== PID ==="
    for pidfile in "$RUNDIR"/*.pid; do
        [ -f "$pidfile" ] || continue
        pid=$(cat "$pidfile" 2>/dev/null || true)
        name=$(basename "$pidfile" .pid)
        if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then
            echo "OK   $name $pid"
        else
            echo "DEAD $name $pid"
        fi
    done

    echo "=== LISTEN ==="
    if [ -z "$PORT_RE" ]; then
        echo "（未开放任何端口）"
    elif command -v ss >/dev/null 2>&1; then
        ss -ltnp 2>/dev/null | grep -E ":($PORT_RE)" || true
    elif command -v netstat >/dev/null 2>&1; then
        netstat -ltnp 2>/dev/null | grep -E ":($PORT_RE)" || true
    else
        echo "无 ss/netstat，可用: cat /proc/net/tcp"
    fi

    echo "=== LOG TAIL ==="
    for f in "$TWIN_LOG_DIR"/*.out; do
        [ -f "$f" ] || continue
        echo "--- $(basename "$f")"
        tail -n 10 "$f" 2>/dev/null || true
    done
}

# ---------------------------------------------------------------- 证书

twin_gen_certs() {
    command -v openssl >/dev/null 2>&1 || { echo "需要 openssl" >&2; return 1; }
    CERTDIR=$TWIN_CERT_DIR
    DAYS=${TWIN_CERT_DAYS:-365}
    CA_DAYS=${TWIN_CERT_CA_DAYS:-3650}
    CN=${TWIN_CERT_CN:-TwinGate}
    CA_CN=${TWIN_CERT_CA_CN:-TwinGate Local CA}
    mkdir -p "$CERTDIR" || return 1

    twin_detect_ips() {
        if command -v ip >/dev/null 2>&1; then
            ip -4 -o addr show 2>/dev/null | sed -n 's/.*inet \([0-9][0-9.]*\)\/.*/\1/p'
        elif command -v hostname >/dev/null 2>&1; then
            hostname -I 2>/dev/null | tr ' ' '\n'
        fi
    }
    SAN="DNS:localhost,IP:127.0.0.1"
    for ip in $(twin_detect_ips | sed 's/^ *//; s/ *$//' | sort -u); do
        [ -z "$ip" ] && continue
        [ "$ip" = 127.0.0.1 ] && continue
        case "$ip" in 169.254.*) continue ;; esac
        case ",$SAN," in *",IP:$ip,"*) ;; *) SAN="$SAN,IP:$ip" ;; esac
    done
    oifs=$IFS; IFS=,
    for x in ${TWIN_CERT_IPS:-}; do
        [ -z "$x" ] && continue
        case ",$SAN," in *",IP:$x,"*) ;; *) SAN="$SAN,IP:$x" ;; esac
    done
    for x in ${TWIN_CERT_DNS:-}; do
        [ -z "$x" ] && continue
        case ",$SAN," in *",DNS:$x,"*) ;; *) SAN="$SAN,DNS:$x" ;; esac
    done
    IFS=$oifs
    echo "[cert] SAN: $SAN"

    if [ ! -f "$CERTDIR/ca.key" ] || [ ! -f "$CERTDIR/ca.crt" ]; then
        openssl ecparam -name prime256v1 -genkey -noout -out "$CERTDIR/ca.key" || return 1
        cat > "$CERTDIR/ca.cnf" <<EOF
[req]
distinguished_name = dn
x509_extensions = v3_ca
prompt = no
[dn]
CN = $CA_CN
[v3_ca]
basicConstraints = critical,CA:TRUE
keyUsage = critical,keyCertSign,cRLSign
subjectKeyIdentifier = hash
EOF
        openssl req -new -x509 -key "$CERTDIR/ca.key" -out "$CERTDIR/ca.crt" \
            -days "$CA_DAYS" -config "$CERTDIR/ca.cnf" 2>/dev/null || return 1
        echo "[cert] 已生成本地 CA：$CERTDIR/ca.crt"
    fi

    openssl ecparam -name prime256v1 -genkey -noout -out "$CERTDIR/server.key" || return 1
    openssl req -new -key "$CERTDIR/server.key" -out "$CERTDIR/server.csr" \
        -subj "/CN=$CN" 2>/dev/null || return 1
    cat > "$CERTDIR/server.cnf" <<EOF
[v3_server]
basicConstraints = CA:FALSE
keyUsage = digitalSignature,keyEncipherment
extendedKeyUsage = serverAuth
subjectAltName = $SAN
subjectKeyIdentifier = hash
authorityKeyIdentifier = keyid,issuer
EOF
    rm -f "$CERTDIR/server.srl"
    openssl x509 -req -in "$CERTDIR/server.csr" \
        -CA "$CERTDIR/ca.crt" -CAkey "$CERTDIR/ca.key" -CAcreateserial \
        -out "$CERTDIR/server.crt" -days "$DAYS" \
        -extfile "$CERTDIR/server.cnf" -extensions v3_server 2>/dev/null || return 1

    cat "$CERTDIR/server.crt" "$CERTDIR/ca.crt" > "$CERTDIR/server-chain.crt"
    b64() { base64 "$1" | tr -d '\n'; }
    printf 'TTP_SERVER_CERT_B64=%s\n' "$(b64 "$CERTDIR/server-chain.crt")" > "$CERTDIR/ttp.env"
    printf 'TTP_SERVER_KEY_B64=%s\n' "$(b64 "$CERTDIR/server.key")" >> "$CERTDIR/ttp.env"
    # ttp.env 里有服务器私钥的 base64，和 *.key 一样只给属主读。
    chmod 600 "$CERTDIR/ca.key" "$CERTDIR/server.key" "$CERTDIR/ttp.env" 2>/dev/null || :
    echo "[cert] 完成：$CERTDIR"
    echo "[cert] 客户端信任文件：$CERTDIR/ca.crt"
}

twin_install_ca() {
    CA=${1:-$TWIN_CERT_DIR/ca.crt}
    NAME=twingate-local-ca
    if [ ! -f "$CA" ]; then
        echo "[install-ca] 找不到 $CA" >&2
        echo "[install-ca] 请先执行 'twingate certs'" >&2
        return 1
    fi
    os=$(uname -s 2>/dev/null || printf 'unknown')
    case "$os" in
        Darwin)
            KEYCHAIN="$HOME/Library/Keychains/login.keychain-db"
            [ -f "$KEYCHAIN" ] || KEYCHAIN="$HOME/Library/Keychains/login.keychain"
            security add-trusted-cert -d -r trustRoot -k "$KEYCHAIN" "$CA"
            echo "[install-ca] 已安装到 macOS 用户钥匙串：$KEYCHAIN"
            ;;
        MINGW*|MSYS*|CYGWIN*)
            WCA=$(cygpath -w "$CA" 2>/dev/null || printf '%s' "$CA")
            certutil -addstore -f ROOT "$WCA"
            echo "[install-ca] 已安装到 Windows 受信任的根证书颁发机构"
            ;;
        Linux)
            if [ -n "${PREFIX:-}" ] && [ -d "$PREFIX/etc/ca-certificates" ]; then
                DEST="$PREFIX/etc/ca-certificates/certs/$NAME.crt"
                cp "$CA" "$DEST"
                command -v update-ca-certificates >/dev/null 2>&1 && update-ca-certificates >/dev/null 2>&1 || :
                echo "[install-ca] 已安装到 Termux：$DEST"
            elif [ -e /system/bin/linker64 ] || [ -d /system/app ]; then
                # Android/ReDroid：系统 CA 不能只靠复制文件，必须走设置里的手工导入
                adb push "$CA" /sdcard/twingate-ca.crt 2>/dev/null || \
                    cp "$CA" /sdcard/twingate-ca.crt 2>/dev/null || :
                echo "[install-ca] Android/ReDroid 需要手工导入：设置 -> 安全 -> 从存储设备安装 -> CA 证书"
                echo "[install-ca] 已尝试把证书复制到 /sdcard/twingate-ca.crt"
            elif [ -d /etc/pki/ca-trust/source/anchors ]; then
                cp "$CA" "/etc/pki/ca-trust/source/anchors/$NAME.crt"
                command -v update-ca-trust >/dev/null 2>&1 && update-ca-trust extract || :
                echo "[install-ca] 已安装到 RHEL 信任库"
            elif [ -d /usr/local/share/ca-certificates ]; then
                cp "$CA" "/usr/local/share/ca-certificates/$NAME.crt"
                command -v update-ca-certificates >/dev/null 2>&1 && update-ca-certificates >/dev/null 2>&1 || :
                echo "[install-ca] 已安装到 Debian/Ubuntu 信任库"
            else
                echo "[install-ca] 未识别的 Linux 发行版，请手工导入：$CA"
            fi
            ;;
        *)
            echo "[install-ca] 平台 $os，请手工把 $CA 导入系统/浏览器信任库。"
            ;;
    esac
}
