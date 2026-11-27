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

# 证书生成/缺失补齐（scripts/cert.sh）：同样是源码树加载 + 安装模式内嵌。
if ! command -v twin_gen_certs >/dev/null 2>&1; then
    if [ -n "${TWIN_ROOT:-}" ] && [ -f "$TWIN_ROOT/scripts/cert.sh" ]; then
        . "$TWIN_ROOT/scripts/cert.sh"
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
    # TWIN_MIXED_FTP=0：混合端口不带 FTP，ftppr 不监听、tgmux 只分 HTTP/SOCKS。
    case "${TWIN_MIXED_FTP:-1}" in
        0|off|no|false) mixed_ftp=0 ;;
        *)              mixed_ftp=1 ;;
    esac
    if twin_has_svc ftp-tls || twin_has_svc ftp-plain; then need_ftp=1; fi
    if [ "$mixed_ftp" = 1 ] && { twin_has_svc mixed-tls || twin_has_svc mixed-plain; }; then
        need_ftp=1
    fi
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
    # 没生成证书也允许启动：就地补一张自签证书并提示客户端需跳过校验。
    if ! command -v twin_cert_ensure >/dev/null 2>&1; then
        echo "[start] 找不到证书逻辑（scripts/cert.sh），无法启动。" >&2
        return 1
    fi
    twin_cert_ensure || return 1
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
    if [ "$need_mux" = 1 ] && [ "$mixed_ftp" = 0 ]; then
        printf '%s\n' "mixed-ftp: off (TWIN_MIXED_FTP=0)" >> "$RUNDIR/services"
    fi

    # 上游 SOCKS5（parent 链式出口）：配置非法时直接拒绝启动。
    twin_parent_resolve || return 1
    twin_parent_write_state "$RUNDIR"
    if [ "${PARENT_ON:-0}" = 1 ]; then
        echo "[start] 上游 SOCKS5：$PARENT_DESC"
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
    # tgtun 也复制：安装目录可能落在 noexec 文件系统上（--prefix 到外置存储），
    # 那时它存在但没有执行位。缺了不影响其它服务，所以只在存在时加进列表。
    [ -f "$BINDIR/tgtun" ] && BINS="$BINS tgtun"
    for bin in $BINS; do
        tmpbin="$RUNTIME_DIR/$bin.new.$$"
        cp "$BINDIR/$bin" "$tmpbin" || return 1
        # noexec 下 chmod 会失败，但文件已经复制好了；能否执行由下面的 TUN 探测判断，
        # 不能因为设不了权限位就中断启动（与 scripts/start.sh 保持一致）。
        chmod 755 "$tmpbin" 2>/dev/null || :
        mv -f "$tmpbin" "$RUNTIME_DIR/$bin" || return 1
    done
    # 让 tun.sh 优先用可执行目录里的那份，而不是可能在 noexec 上的安装目录。
    if [ -f "$RUNTIME_DIR/tgtun" ] && [ -x "$RUNTIME_DIR/tgtun" ]; then
        TWIN_TUN_BIN_RUN="$RUNTIME_DIR/tgtun"
        export TWIN_TUN_BIN_RUN
    fi

    # TUN 虚拟网卡接力：必须放在"二进制已复制到可执行目录"之后，
    # 否则 noexec 安装目录里那份 tgtun 会被判成不可执行。
    twin_tun_resolve || return 1
    twin_tun_write_state "$RUNDIR"
    if [ "${TUN_ON:-0}" = 1 ]; then
        echo "[start] TUN 接力：$(twin_tun_desc)"
    fi

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
            TTP_SESSION_CACHE_KB="${TTP_SESSION_CACHE_KB:-256}" \
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
        if [ "$need_ftp" = 1 ]; then _mux_ftp=$TWIN_FTP_PLAIN; else _mux_ftp=0; fi
        twin_start_one tgmux "$RUNTIME_DIR/tgmux" \
            "$TWIN_MUX_PLAIN" "$TWIN_HTTP_PLAIN" "$TWIN_SOCKS_PLAIN" \
            "$_mux_ftp" "$TWIN_MUX_BIND"
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

# 状态报告统一由 scripts/status.sh 提供（唯一实现），这里只做转发。
#
# 以前两处各写一份：源码树的 status.sh 与安装模式的 twin_status 输出并不一致
# （DNS 段只在后者里有），改一处漏一处。现在安装时把 status.sh 内嵌进启动器，
# 两边跑的是同一份代码。
twin_status() {
    # 端口默认值来自 tui.env / 内嵌 ports.env，report 里要用。
    twin_ports_init
    if ! command -v twin_status_report >/dev/null 2>&1; then
        # 单独 source tg-runtime.sh（不经 tgmenu / 启动器）时的兜底。
        for _st in "$TWIN_ROOT/status.sh" "$TWIN_ROOT/scripts/status.sh"; do
            if [ -f "$_st" ]; then
                . "$_st"
                break
            fi
        done
    fi
    if ! command -v twin_status_report >/dev/null 2>&1; then
        echo "找不到 scripts/status.sh，无法显示状态。" >&2
        return 1
    fi
    twin_status_report
}

# ---------------------------------------------------------------- 证书


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

# ---------------------------------------------------------------- 卸载
# 安装模式下 'twingate uninstall' 自己就能把装出去的东西删掉：启动器是单个脚本，
# 知道 $TWIN_PREFIX / $TWIN_ROOT / 配置与数据目录，不需要再回源码树找 uninstall.sh。
# 默认保留配置和数据（证书在这里，误删代价大），--purge 才一起清。
twin_uninstall() {
    _un_purge=0
    while [ "$#" -gt 0 ]; do
        case "$1" in
            --purge) _un_purge=1; shift ;;
            -h|--help)
                printf '%s\n' '用法: twingate uninstall [--purge]'
                printf '%s\n' '  默认保留配置目录与数据目录（含证书）；--purge 一并删除。'
                return 0 ;;
            *) printf '[uninstall] 未知参数: %s\n' "$1" >&2; return 1 ;;
        esac
    done

    if [ "${TWIN_INSTALLED:-0}" != 1 ]; then
        printf '[uninstall] 当前不是安装模式；源码树请用 sh scripts/uninstall.sh。\n' >&2
        return 1
    fi

    # 兜底：宁可拒绝也不删错目录。TWIN_ROOT 必须正好是 <prefix>/lib/twingate。
    _un_lib=$TWIN_PREFIX/lib/twingate
    case "${TWIN_PREFIX:-}" in
        ""|/|"${HOME:-/nonexistent}"|"${HOME:-/nonexistent}/")
            printf '[uninstall] 安装前缀异常（%s），拒绝删除。\n' "${TWIN_PREFIX:-空}" >&2
            return 1 ;;
    esac
    if [ "$(cd -- "$TWIN_ROOT" 2>/dev/null && pwd)" != "$(cd -- "$_un_lib" 2>/dev/null && pwd)" ]; then
        printf '[uninstall] 程序目录不符合预期（%s），拒绝删除。\n' "$TWIN_ROOT" >&2
        return 1
    fi

    _un_bin=$TWIN_PREFIX/bin/twingate
    if [ ! -e "$_un_bin" ] && [ ! -d "$TWIN_ROOT" ]; then
        printf '[uninstall] 没有找到安装：%s\n' "$TWIN_PREFIX"
        return 0
    fi

    # 先停进程：删除二进制后旧进程仍会占着端口，用户会以为"没卸干净"。
    twin_stop >/dev/null 2>&1 || :

    for _un_f in 3proxy ttp tgmux tgtun; do
        rm -f "$TWIN_ROOT/$_un_f" 2>/dev/null || :
    done
    # 只删这四个二进制，其它文件（用户自己塞的）不动，目录非空时 rmdir 会自动留下。
    rmdir "$TWIN_ROOT" 2>/dev/null || :
    rmdir "$TWIN_PREFIX/lib" 2>/dev/null || :
    printf '[uninstall] 已移除 %s 与 %s\n' "$_un_lib" "$_un_bin"
    # 启动器放在最后删：正在执行的脚本即便被 unlink 也能继续跑完。
    rm -f "$_un_bin" 2>/dev/null || :

    if [ "$_un_purge" = 1 ]; then
        _un_old=${HOME:-/tmp}/.local/config/twingate
        for _un_d in "$TWIN_CONFIG_DIR" "$TWIN_DATA"; do
            case "$_un_d" in
                ""|/|"${HOME:-/nonexistent}"|"${HOME:-/nonexistent}/")
                    printf '[uninstall] 目录值异常（%s），拒绝删除。\n' "$_un_d" >&2
                    return 1 ;;
            esac
        done
        rm -rf "$TWIN_CONFIG_DIR" "$TWIN_DATA"
        printf '[uninstall] 已删除配置目录 %s 与数据目录 %s\n' "$TWIN_CONFIG_DIR" "$TWIN_DATA"
        if [ "$_un_old" != "$TWIN_CONFIG_DIR" ] && [ -d "$_un_old" ]; then
            rm -rf "$_un_old"
            printf '[uninstall] 已删除旧版配置目录 %s\n' "$_un_old"
        fi
    else
        printf '[uninstall] 配置目录已保留: %s\n' "$TWIN_CONFIG_DIR"
        printf '[uninstall] 数据目录已保留: %s（含证书，--purge 才会删）\n' "$TWIN_DATA"
    fi
    return 0
}
